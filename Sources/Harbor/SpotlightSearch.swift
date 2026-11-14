import AppKit
import HarborCore

/// 用 NSMetadataQuery 执行 SmartQuery。收集、过滤结果都在后台队列上做，
/// 结果几万条时主线程也不卡；live 时文件变化会再次回调
@MainActor
final class SpotlightSearch {
    struct Result: Hashable, Sendable {
        let url: URL
        let name: String
        let modified: Date?
        let lastUsed: Date?
        let size: Int64?
    }

    enum SortKey: Sendable { case modified, lastUsed }

    /// 第二个参数：首次收集是否已经完成（完成前结果可能不全）
    var onUpdate: (([Result], Bool) -> Void)?
    private(set) var results: [Result] = []
    /// 过滤后的结果数（只计数时 results 为空，只有这个）
    private(set) var count = 0
    private(set) var isFinished = false
    private let worker: Worker

    /// countOnly：只要数量（主页卡片），每条结果只读路径用来过滤，不读其他属性、不排序
    init(_ query: SmartQuery, live: Bool, sortBy: SortKey = .modified, limit: Int? = nil, countOnly: Bool = false) {
        worker = Worker(query: query, live: live, sortBy: sortBy, limit: limit, countOnly: countOnly)
    }

    func start() {
        worker.start { [weak self] results, count, finished in
            Task { @MainActor in
                guard let self else { return }
                self.results = results
                self.count = count
                self.isFinished = self.isFinished || finished
                self.onUpdate?(results, self.isFinished)
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

        init(query smart: SmartQuery, live: Bool, sortBy: SortKey, limit: Int?, countOnly: Bool) {
            self.countOnly = countOnly
            self.live = live
            self.sortBy = sortBy
            self.limit = limit
            super.init()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            query.operationQueue = queue
            query.predicate = NSPredicate(fromMetadataQueryString: smart.metadataQueryString)
            query.searchScopes = SpotlightSearch.userScopes()
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
