import AppKit
import HarborCore

/// 用 NSMetadataQuery 执行 SmartQuery。收集、过滤结果都在后台队列上做，
/// 结果几万条时主线程也不卡；live 时文件变化会再次回调
@MainActor
final class SpotlightSearch {
    struct Result: Hashable, Sendable, Codable {
        let url: URL
        let name: String
        let modified: Date?
        let lastUsed: Date?
        let size: Int64?
    }

    enum SortKey: Sendable, Hashable { case modified, lastUsed }

    /// 结果更新（object 是这个 SpotlightSearch）。共享的查询会被主页卡片、结果列表同时用到，所以用通知而不是单个回调
    static let didUpdate = Notification.Name("HarborSpotlightSearchDidUpdate")

    /// 第二个参数：首次收集是否已经完成（完成前结果可能不全）
    var onUpdate: (([Result], Bool) -> Void)?
    private(set) var results: [Result] = []
    /// 过滤后的结果数（只计数时 results 为空，只有这个）
    private(set) var count = 0
    private(set) var isFinished = false
    private let worker: Worker

    /// countOnly：只要数量（主页卡片），每条结果只读路径用来过滤，不读其他属性、不排序
    init(_ query: SmartQuery, live: Bool, sortBy: SortKey = .modified, limit: Int? = nil, countOnly: Bool = false) {
        worker = Worker(queryString: query.metadataQueryString, scopes: nil, live: live, sortBy: sortBy, limit: limit, countOnly: countOnly)
    }

    /// 直接给查询字符串和搜索范围（快速搜索用）；scopes 为空时搜主目录下的文件夹
    init(queryString: String, scopes: [URL]?, live: Bool) {
        worker = Worker(queryString: queryString, scopes: scopes, live: live, sortBy: .modified, limit: nil, countOnly: false)
    }

    private var started = false

    /// 先放上次存下的快照：查询还没交回结果时先显示它（isFinished 仍为 false，状态栏显示「正在查找…」）
    func seed(_ snapshot: [Result]) {
        guard results.isEmpty, !isFinished else { return }
        results = snapshot
        count = snapshot.count
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
    }

    /// 可以重复调用，只启动一次
    func start() {
        guard !started else { return }
        started = true
        worker.start { [weak self] results, count, finished in
            Task { @MainActor in
                guard let self else { return }
                self.results = results
                self.count = count
                self.isFinished = self.isFinished || finished
                self.onUpdate?(results, self.isFinished)
                NotificationCenter.default.post(name: Self.didUpdate, object: self)
            }
        }
    }

    func stop() {
        worker.stop()
    }

    deinit {
        worker.stop()
    }

    /// 桌面、文稿、下载受隐私保护：第一次查询时系统会请求授权，授权前 start() 一直等着。
    /// 调试脚本没人点授权，运行时跳过这三个目录（只给调试脚本用）
    nonisolated(unsafe) static var excludesProtectedFolders = false
    nonisolated static let protectedFolders: Set<String> = ["Desktop", "Documents", "Downloads"]

    /// 只搜用户主目录下可见的一级文件夹（不含 ~/Library），系统和缓存目录里的文件不要
    nonisolated static func userScopes() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let children = (try? FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
        return children.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true && url.lastPathComponent != "Library"
                && !(excludesProtectedFolders && protectedFolders.contains(url.lastPathComponent))
        }
    }

    /// NSMetadataQuery 只在自己的队列上碰，用锁不如用串行队列简单
    private final class Worker: NSObject, @unchecked Sendable {
        private let query = NSMetadataQuery()
        private let queue = OperationQueue()
        private let live: Bool
        private let sortBy: SortKey
        private let limit: Int?
        private let countOnly: Bool
        private var deliver: (@Sendable ([Result], Int, Bool) -> Void)?

        init(queryString: String, scopes: [URL]?, live: Bool, sortBy: SortKey, limit: Int?, countOnly: Bool) {
            self.countOnly = countOnly
            self.live = live
            self.sortBy = sortBy
            self.limit = limit
            super.init()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            query.operationQueue = queue
            query.predicate = NSPredicate(fromMetadataQueryString: queryString)
            query.searchScopes = scopes ?? SpotlightSearch.userScopes()
            // 文件频繁变化（编译、下载）时，更新合并成每秒最多一次
            if live { query.notificationBatchingInterval = 1 }
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: query)
            center.addObserver(self, selector: #selector(updated), name: .NSMetadataQueryDidUpdate, object: query)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func start(_ deliver: @escaping @Sendable ([Result], Int, Bool) -> Void) {
            queue.addOperation { [self] in
                self.deliver = deliver
                if query.predicate == nil || !query.start() { deliver([], 0, true) }
            }
        }

        func stop() {
            queue.addOperation { [self] in
                deliver = nil
                query.stop()
            }
        }

        @objc private func gathered() {
            publish(finished: true)
            if !live { query.stop() }
        }

        @objc private func updated() {
            publish(finished: false)
        }

        private func publish(finished: Bool) {
            guard let deliver else { return }
            query.disableUpdates()
            var results: [Result] = []
            var count = 0
            if !countOnly { results.reserveCapacity(query.resultCount) }
            for index in 0..<query.resultCount {
                guard let item = query.result(at: index) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                      SpotlightFilter.isBrowsable(path) else { continue }
                count += 1
                if countOnly { continue }
                results.append(Result(
                    url: URL(filePath: path),
                    name: item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? (path as NSString).lastPathComponent,
                    modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                    lastUsed: item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date,
                    size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value))
            }
            query.enableUpdates()
            switch sortBy {
            case .modified: results.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            case .lastUsed: results.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
            }
            if let limit, results.count > limit { results.removeSubrange(limit...) }
            deliver(results, count, finished)
        }
    }
}

/// 常驻的共享查询：默认分类、最近、标签、开着「智能更新」的智能分类，第一次用到时启动，之后一直保留。
/// 再进主页、分类页直接用现成结果，文件变化由 Spotlight 增量推送，不用每次重新搜。
/// 结果另存一份快照到 ~/Library/Caches：重启 app 后先显示快照，查询完成再换成最新的
@MainActor
final class SpotlightCache {
    static let shared = SpotlightCache()

    private struct Key: Hashable {
        let query: SmartQuery
        let sortBy: SpotlightSearch.SortKey
        let limit: Int?
    }

    private var searches: [Key: SpotlightSearch] = [:]
    private var pendingSaves: Set<Key> = []
    /// 调试脚本会改到测试目录里，不碰真实的缓存
    var snapshotDirectory = URL.cachesDirectory.appending(path: "dev.lakes.harbor/spotlight", directoryHint: .isDirectory)

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(categoriesChanged),
                                               name: SmartCategoryStore.didChange, object: nil)
    }

    func search(_ query: SmartQuery, sortBy: SpotlightSearch.SortKey = .modified, limit: Int? = nil) -> SpotlightSearch {
        let key = Key(query: query, sortBy: sortBy, limit: limit)
        if let existing = searches[key] { return existing }
        let search = SpotlightSearch(query, live: true, sortBy: sortBy, limit: limit)
        if let snapshot = loadSnapshot(key) { search.seed(snapshot) }
        NotificationCenter.default.addObserver(forName: SpotlightSearch.didUpdate, object: search, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSave(key) }
        }
        search.start()
        searches[key] = search
        return search
    }

    func contains(_ query: SmartQuery) -> Bool {
        searches.keys.contains { $0.query == query }
    }

    /// 启动时预热：用过主页（记过卡片数量）才做，没用过的人启动时不弹桌面 / 文稿 / 下载的授权
    func prefetchIfUsed() {
        guard !HomeViewController.savedCounts.isEmpty else { return }
        for kind in SmartQuery.Kind.allCases { _ = search(.category(kind)) }
        _ = search(.recent, sortBy: .lastUsed, limit: HomeViewController.recentLimit)
    }

    /// 只给调试脚本用：模拟重启 app（内存里的查询全部丢掉，快照留着）
    func removeAllSearches() {
        searches.values.forEach { $0.stop() }
        searches = [:]
    }

    /// 智能分类改了条件、关了智能更新或被删掉：停掉不再用到的查询，别让它一直在后台跑
    @objc private func categoriesChanged() {
        let defaults = Set(SmartQuery.Kind.allCases.map(SmartQuery.category) + [.recent])
        let smart = Set(SmartCategoryStore.shared.categories.filter(\.autoUpdate).map(\.query))
        for (key, search) in searches {
            let isTag = key.query.tag != nil && key.query == SmartQuery(tag: key.query.tag)
            guard !defaults.contains(key.query), !smart.contains(key.query), !isTag else { continue }
            search.stop()
            searches[key] = nil
            try? FileManager.default.removeItem(at: snapshotURL(key))
        }
    }

    // MARK: - 快照

    /// 查询条件 + 排序 + 数量上限 + 搜索范围 一起决定文件名（调试脚本跳过受保护目录时的结果不会混进正常的）
    private func snapshotURL(_ key: Key) -> URL {
        let identity = "\(key.query.metadataQueryString)|\(key.sortBy)|\(key.limit ?? 0)|\(SpotlightSearch.excludesProtectedFolders)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identity.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return snapshotDirectory.appending(path: String(hash, radix: 16) + ".json")
    }

    private func loadSnapshot(_ key: Key) -> [SpotlightSearch.Result]? {
        guard let data = try? Data(contentsOf: snapshotURL(key)) else { return nil }
        return try? JSONDecoder().decode([SpotlightSearch.Result].self, from: data)
    }

    /// 查询完成后存；之后的更新攒 5 秒存一次
    private func scheduleSave(_ key: Key) {
        guard let search = searches[key], search.isFinished, pendingSaves.insert(key).inserted else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            pendingSaves.remove(key)
            guard let search = searches[key], let data = try? JSONEncoder().encode(search.results) else { return }
            let url = snapshotURL(key)
            let directory = snapshotDirectory
            Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 只给调试脚本用：立即把已完成的查询存盘
    func saveAllNow() {
        for (key, search) in searches where search.isFinished {
            guard let data = try? JSONEncoder().encode(search.results) else { continue }
            try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
            try? data.write(to: snapshotURL(key), options: .atomic)
        }
    }
}
