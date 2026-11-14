import CoreServices
import Foundation

public struct FileSortOrder: Sendable, Hashable {
    public enum Key: String, Sendable, CaseIterable {
        case name, modified, size, kind
    }

    public var key: Key
    public var ascending: Bool
    public var foldersFirst: Bool

    public init(key: Key = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.key = key
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }
}

public enum FileSorter {
    /// 过滤隐藏文件并排序
    public static func arrange(_ items: [FileItem], showHidden: Bool, order: FileSortOrder) -> [FileItem] {
        let visible = showHidden ? items : items.filter { !$0.isHidden }
        return sorted(visible, by: order)
    }

    /// 名称按 Finder 的规则比较：跟随当前区域（中文按拼音）、数字按数值、不分大小写。
    public static func sorted(_ items: [FileItem], by order: FileSortOrder) -> [FileItem] {
        let names = NameKeys(items.map(\.name))
        let kindRanks: [Int]? = order.key == .kind ? kindRanks(items) : nil

        var indices = Array(items.indices)
        indices.sort { a, b in
            let lhs = items[a], rhs = items[b]
            if order.foldersFirst, lhs.isFolder != rhs.isFolder {
                return lhs.isFolder
            }
            let primary: ComparisonResult = switch order.key {
            case .name: .orderedSame
            case .modified: compare(lhs.modified, rhs.modified)
            case .size: compare(lhs.size ?? -1, rhs.size ?? -1)
            case .kind: compare(kindRanks![a], kindRanks![b])
            }
            if primary != .orderedSame {
                return order.ascending ? primary == .orderedAscending : primary == .orderedDescending
            }
            let byName = names.compare(a, b)
            // 按名称排序时方向跟随设置；其他列相同时名称始终升序
            if order.key == .name, !order.ascending { return byName == .orderedDescending }
            return byName == .orderedAscending
        }
        return indices.map { items[$0] }
    }

    /// 种类描述只有几十种，先排好序，比较时只比名次
    private static func kindRanks(_ items: [FileItem]) -> [Int] {
        let descriptions = items.map(FileTypes.kindDescription(for:))
        let ordered = Set(descriptions).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let rank = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
        return descriptions.map { rank[$0]! }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}

/// 预先算好的文件名排序键。
/// localizedStandardCompare 每次比较都要走一遍区域规则，10 万个名字排序约 670ms；
/// 改成每个名字算一次 UCCollationKey、比较时只比键，约 100ms（数据来自 HarborBench）。
/// 键相等时（比如 e 和 é）回退到 localizedStandardCompare，保证结果和它完全一致。
struct NameKeys {
    private let names: [String]
    private let keys: [[UCCollationValue]]?

    init(_ names: [String]) {
        self.names = names
        self.keys = Self.makeKeys(names)
    }

    func compare(_ a: Int, _ b: Int) -> ComparisonResult {
        if let keys {
            var equivalent: DarwinBoolean = false
            var order: Int32 = 0
            let status = UCCompareCollationKeys(keys[a], keys[a].count, keys[b], keys[b].count, &equivalent, &order)
            // 等价（只差大小写、重音）时 order 仍会给出非零的先后，不能用，要看 equivalent
            if status == noErr, !equivalent.boolValue, order != 0 {
                return order < 0 ? .orderedAscending : .orderedDescending
            }
        }
        return names[a].localizedStandardCompare(names[b])
    }

    /// 分块并行计算，每块用自己的 collator。任何一个名字失败就整体退回 localizedStandardCompare。
    private static func makeKeys(_ names: [String]) -> [[UCCollationValue]]? {
        let chunkSize = 4096
        let chunkCount = (names.count + chunkSize - 1) / chunkSize
        // 每块只写自己那段下标，互不重叠，所以可以并发写同一个缓冲区
        let keys = SharedBuffer<[UCCollationValue]>(count: names.count, initial: [])
        let failed = SharedBuffer<Bool>(count: chunkCount, initial: false)
        defer { keys.free(); failed.free() }
        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            var collator: CollatorRef?
            guard UCCreateCollator(nil, 0, collateOptions, &collator) == noErr, let collator else {
                failed[chunk] = true
                return
            }
            defer {
                var disposable: CollatorRef? = collator
                UCDisposeCollator(&disposable)
            }
            for i in chunk * chunkSize..<min((chunk + 1) * chunkSize, names.count) {
                guard let key = key(for: names[i], collator: collator) else {
                    failed[chunk] = true
                    return
                }
                keys[i] = key
            }
        }
        return failed.array.contains(true) ? nil : keys.array
    }

    /// 键只负责「主要差异」（字母、数字按数值、区域顺序），大小写和重音一律忽略；
    /// 键相等时交给 localizedStandardCompare，两者对重音的先后规则不一样，不能让键来判。
    /// locale 传 nil 表示用当前区域。
    private static let collateOptions = UCCollateOptions(
        kUCCollateComposeInsensitiveMask | kUCCollateWidthInsensitiveMask | kUCCollateCaseInsensitiveMask
            | kUCCollateDiacritInsensitiveMask
            | kUCCollateDigitsOverrideMask | kUCCollateDigitsAsNumberMask | kUCCollatePunctuationSignificantMask
    )

    private static func key(for name: String, collator: CollatorRef) -> [UCCollationValue]? {
        let utf16 = Array(name.utf16)
        var capacity = utf16.count * 8 + 16
        while capacity <= 1 << 20 {
            var buffer = [UCCollationValue](repeating: 0, count: capacity)
            var actual = 0
            let status = UCGetCollationKey(collator, utf16, utf16.count, capacity, &actual, &buffer)
            if status == noErr { return Array(buffer.prefix(actual)) }
            guard status == OSStatus(kUCOutputBufferTooSmall) else { return nil }
            capacity *= 4
        }
        return nil
    }
}

/// 给 concurrentPerform 用的定长缓冲区，调用方保证各线程写的下标不重叠
private final class SharedBuffer<Element>: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Element>

    init(count: Int, initial: Element) {
        storage = .allocate(capacity: count)
        storage.initialize(repeating: initial)
    }

    subscript(index: Int) -> Element {
        get { storage[index] }
        set { storage[index] = newValue }
    }

    var array: [Element] { Array(storage) }

    func free() {
        storage.deinitialize()
        storage.deallocate()
    }
}
