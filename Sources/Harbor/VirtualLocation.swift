import AppKit
import HarborCore

/// 不对应真实目录的位置：主页、分类、标签、智能分类。
/// 编码成 harbor:// 地址，复用浏览区的导航、前进后退、新标签页
enum VirtualLocation: Equatable {
    case home
    case category(SmartQuery.Kind)
    case tag(String)
    case smart(UUID)

    static let scheme = "harbor"

    init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host() else { return nil }
        let value = url.lastPathComponent
        switch host {
        case "home": self = .home
        case "category":
            guard let kind = SmartQuery.Kind(rawValue: value) else { return nil }
            self = .category(kind)
        case "tag" where !value.isEmpty && value != "/": self = .tag(value)
        case "smart":
            guard let id = UUID(uuidString: value) else { return nil }
            self = .smart(id)
        default: return nil
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .home: components.host = "home"
        case .category(let kind): components.host = "category"; components.path = "/" + kind.rawValue
        case .tag(let name): components.host = "tag"; components.path = "/" + name
        case .smart(let id): components.host = "smart"; components.path = "/" + id.uuidString
        }
        return components.url!
    }

    @MainActor var title: String {
        switch self {
        case .home: "主页"
        case .category(let kind): kind.title
        case .tag(let name): name
        case .smart(let id): SmartCategoryStore.shared.category(id)?.name ?? "智能分类"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.circle"
        case .category(let kind): kind.symbol
        case .tag: "tag"
        case .smart: "sparkle.magnifyingglass"
        }
    }

    /// 结果列表用的查询；主页不是单个查询
    @MainActor var query: (SmartQuery, live: Bool)? {
        switch self {
        case .home: nil
        case .category(let kind): (.category(kind), true)
        case .tag(let name): (SmartQuery(tag: name), true)
        case .smart(let id):
            SmartCategoryStore.shared.category(id).map { ($0.query, $0.autoUpdate) }
        }
    }
}

extension URL {
    var isVirtualLocation: Bool { scheme == VirtualLocation.scheme }

    /// 边栏、高亮比较用的键：真实目录用规范路径，虚拟位置用完整地址
    var locationKey: String { isVirtualLocation ? absoluteString : pathKey }
}

extension SmartQuery.Kind {
    var symbol: String {
        switch self {
        case .document: "doc.text.fill"
        case .image: "photo.fill"
        case .video: "film.fill"
        case .audio: "music.note"
        case .archive: "archivebox.fill"
        }
    }

    /// 卡片的主题色（借鉴鸿蒙文件管理的彩色分类卡片）
    var tint: NSColor {
        switch self {
        case .document: .systemBlue
        case .image: .systemGreen
        case .video: .systemOrange
        case .audio: .systemPink
        case .archive: .systemBrown
        }
    }
}

/// 自建的智能分类，存在 ~/Library/Application Support/Harbor/smart-categories.json
@MainActor
final class SmartCategoryStore {
    static let shared = SmartCategoryStore()
    static let didChange = Notification.Name("HarborSmartCategoriesDidChange")

    private(set) var categories: [SmartCategory] = []
    private let fileURL: URL

    private init() {
        let support = URL.applicationSupportDirectory.appending(path: "Harbor", directoryHint: .isDirectory)
        fileURL = support.appending(path: "smart-categories.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([SmartCategory].self, from: data) {
            categories = decoded
        }
    }

    func category(_ id: UUID) -> SmartCategory? {
        categories.first { $0.id == id }
    }

    func save(_ category: SmartCategory) {
        if let index = categories.firstIndex(where: { $0.id == category.id }) {
            categories[index] = category
        } else {
            categories.append(category)
        }
        persist()
    }

    func remove(_ id: UUID) {
        categories.removeAll { $0.id == id }
        QuickAccessStore.shared.remove(VirtualLocation.smart(id).url)
        persist()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(categories) { try? data.write(to: fileURL, options: .atomic) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// 边栏「快速访问」：文件夹和固定的智能分类，顺序即添加顺序
@MainActor
final class QuickAccessStore {
    static let shared = QuickAccessStore()
    static let didChange = Notification.Name("HarborQuickAccessDidChange")
    private static let key = "quickAccess"

    private(set) var urls: [URL]

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.key) {
            urls = saved.compactMap { $0.hasPrefix("/") ? URL(filePath: $0, directoryHint: .isDirectory) : URL(string: $0) }
        } else {
            let fm = FileManager.default
            urls = [fm.homeDirectoryForCurrentUser, .desktopDirectory, .documentsDirectory, .downloadsDirectory, .applicationDirectory]
        }
    }

    func contains(_ url: URL) -> Bool {
        urls.contains { $0.locationKey == url.locationKey }
    }

    func add(_ url: URL) {
        guard !contains(url) else { return }
        urls.append(url)
        persist()
    }

    func remove(_ url: URL) {
        let count = urls.count
        urls.removeAll { $0.locationKey == url.locationKey }
        if urls.count != count { persist() }
    }

    private func persist() {
        UserDefaults.standard.set(urls.map { $0.isFileURL ? $0.path(percentEncoded: false) : $0.absoluteString }, forKey: Self.key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
