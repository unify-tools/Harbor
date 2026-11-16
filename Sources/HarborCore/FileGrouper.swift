import CoreServices
import Foundation

/// 分组方式，和 Finder 的「分组方式」一致
public enum FileGrouping: String, CaseIterable, Sendable {
    case none, name, kind, application, lastOpened, added, modified, created, size, tags

    public var title: String {
        switch self {
        case .none: "无"
        case .name: "名称"
        case .kind: "种类"
        case .application: "应用程序"
        case .lastOpened: "上次打开日期"
        case .added: "添加日期"
        case .modified: "修改日期"
        case .created: "创建日期"
        case .size: "大小"
        case .tags: "标签"
        }
    }
}

/// 一组：标题 + 在重排后的 items 里的范围（组内连续）
public struct FileGroup: Sendable, Equatable {
    public let title: String
    public let range: Range<Int>

    public init(title: String, range: Range<Int>) {
        self.title = title
        self.range = range
    }
}

/// 按分组方式把已经排好序的条目分组：组按固定顺序排（日期新的在前、大的在前、名称按字母），
/// 组内保持原来的排序。上次打开、添加日期、标签要额外读文件属性，只在选了对应分组时读（在后台调用）
public enum FileGrouper {
    /// 文件夹在「应用程序」「大小」分组里的组名
    public static let folderTitle = "文件夹"

    public static func group(_ items: [FileItem], by grouping: FileGrouping, in directory: URL,
                             now: Date = .now, calendar: Calendar = .current,
                             appName: (FileItem) -> String = { _ in "" }) -> (items: [FileItem], groups: [FileGroup]) {
        guard grouping != .none, !items.isEmpty else { return (items, []) }
        // 每个条目算出（组的排序键, 组名），再按组稳定排序
        let keys: [(order: GroupOrder, title: String)] = items.map { item in
            switch grouping {
            case .none: (.text(""), "")
            case .name: nameKey(item.name)
            case .kind: textKey(FileTypes.kindDescription(for: item))
            case .application: item.isFolder ? (.last(0), folderTitle) : textKey(appName(item))
            case .modified: dateKey(item.modified, now: now, calendar: calendar)
            case .created: dateKey(item.created, now: now, calendar: calendar)
            case .added: dateKey(addedDate(item.url(in: directory)), now: now, calendar: calendar)
            case .lastOpened: dateKey(lastOpenedDate(item.url(in: directory)), now: now, calendar: calendar)
            case .size: sizeKey(item)
            case .tags: tagKey(item.url(in: directory))
            }
        }
        let order = items.indices.sorted { a, b in
            if keys[a].order != keys[b].order { return keys[a].order < keys[b].order }
            return a < b
        }
        var arranged: [FileItem] = []
        arranged.reserveCapacity(items.count)
        var groups: [FileGroup] = []
        var start = 0
        for (position, index) in order.enumerated() {
            arranged.append(items[index])
            let isLast = position == order.count - 1
            if isLast || keys[order[position + 1]].order != keys[index].order {
                groups.append(FileGroup(title: keys[index].title, range: start..<position + 1))
                start = position + 1
            }
        }
        return (arranged, groups)
    }

    /// 组的先后：先按 rank（日期桶、大小桶），同 rank 再按文字；last 永远排在最后
    enum GroupOrder: Comparable {
        case rank(Int)
        case text(String)
        case last(Int)

        static func < (lhs: GroupOrder, rhs: GroupOrder) -> Bool {
            switch (lhs, rhs) {
            case let (.rank(a), .rank(b)): a < b
            case let (.text(a), .text(b)): a.localizedStandardCompare(b) == .orderedAscending
            case let (.last(a), .last(b)): a < b
            case (.rank, _): true
            case (.text, .rank): false
            case (.text, .last): true
            case (.last, _): false
            }
        }

        static func == (lhs: GroupOrder, rhs: GroupOrder) -> Bool {
            switch (lhs, rhs) {
            case let (.rank(a), .rank(b)): a == b
            // 同一个组名就是同一组（不区分大小写的排序不该把它们拆开）
            case let (.text(a), .text(b)): a == b
            case let (.last(a), .last(b)): a == b
            default: false
            }
        }
    }

    private static func textKey(_ text: String) -> (GroupOrder, String) {
        text.isEmpty ? (.last(1), "其他") : (.text(text), text)
    }

    /// 首字母：英文字母大写；汉字按拼音首字母；数字归「0–9」；其余归「#」
    static func nameKey(_ name: String) -> (GroupOrder, String) {
        guard let first = name.first else { return (.last(0), "#") }
        var letter = String(first).uppercased()
        if first.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }),
           let latin = String(first).applyingTransform(.mandarinToLatin, reverse: false)?
               .applyingTransform(.stripDiacritics, reverse: false)?.first {
            letter = String(latin).uppercased()
        }
        if let scalar = letter.unicodeScalars.first, letter.count == 1, ("A"..."Z").contains(scalar) {
            return (.text(letter), letter)
        }
        if first.isNumber { return (.last(0), "0–9") }
        return (.last(1), "#")
    }

    /// 今天、昨天、过去 7 天、过去 30 天，再往前按月（今年）、按年
    static func dateKey(_ date: Date?, now: Date, calendar: Calendar) -> (GroupOrder, String) {
        guard let date else { return (.last(0), "未知") }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case ..<1: return (.rank(0), "今天")
        case 1: return (.rank(1), "昨天")
        case 2..<7: return (.rank(2), "过去 7 天")
        case 7..<30: return (.rank(3), "过去 30 天")
        default: break
        }
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        if year == calendar.component(.year, from: now) {
            return (.rank(100 - month), "\(month) 月")
        }
        return (.rank(10_000 - year), "\(year) 年")
    }

    /// 大的在前；文件夹单独一组放最后
    static func sizeKey(_ item: FileItem) -> (GroupOrder, String) {
        guard !item.isFolder, let size = item.size else { return (.last(0), folderTitle) }
        let kb: Int64 = 1000, mb = kb * 1000, gb = mb * 1000
        switch size {
        case gb...: return (.rank(0), "大于 1 GB")
        case (100 * mb)...: return (.rank(1), "100 MB – 1 GB")
        case mb...: return (.rank(2), "1 MB – 100 MB")
        case (100 * kb)...: return (.rank(3), "100 KB – 1 MB")
        case 1...: return (.rank(4), "小于 100 KB")
        default: return (.rank(5), "零字节")
        }
    }

    /// 第一个标签；没有标签的放最后
    private static func tagKey(_ url: URL) -> (GroupOrder, String) {
        guard let tag = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames?.first else { return (.last(0), "无标签") }
        return (.text(tag), tag)
    }

    private static func addedDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
    }

    /// 上次打开日期只有 Spotlight 记着（kMDItemLastUsedDate）
    private static func lastOpenedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
