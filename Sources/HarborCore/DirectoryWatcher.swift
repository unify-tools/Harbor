import CoreServices
import Foundation

/// 用 FSEvents 监听一个目录的直接子项变化（增、删、改名、内容修改）。
/// FSEvents 是递归的，更深层的变化在回调里过滤掉。
public final class DirectoryWatcher: @unchecked Sendable {
    private let watchedPath: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "harbor.directory-watcher")
    // 只在 init 和 queue 上读写
    private var stream: FSEventStreamRef?

    public init?(url: URL, latency: TimeInterval = 0.1, onChange: @escaping @Sendable () -> Void) {
        // FSEvents 报告的是真实路径（/tmp 会变成 /private/tmp）
        watchedPath = url.resolvingSymlinksInPath().pathKey
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
                watcher.handle(paths: list, flags: UnsafeBufferPointer(start: flags, count: count))
            },
            &context,
            [watchedPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        stop()
    }

    public func stop() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func handle(paths: [String], flags: UnsafeBufferPointer<FSEventStreamEventFlags>) {
        let mustRescan = FSEventStreamEventFlags(
            kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        )
        for (path, flag) in zip(paths, flags) where flag & mustRescan != 0 || Self.isRelevant(path, to: watchedPath) {
            onChange()
            return
        }
    }

    /// 目录本身或它的直接子项算相关；路径前缀对不上（固件链接等情况）时保守地算相关
    static func isRelevant(_ eventPath: String, to watchedPath: String) -> Bool {
        let path = eventPath.count > 1 && eventPath.hasSuffix("/") ? String(eventPath.dropLast()) : eventPath
        if path == watchedPath { return true }
        let prefix = watchedPath == "/" ? "/" : watchedPath + "/"
        guard path.hasPrefix(prefix) else { return true }
        return !path.dropFirst(prefix.count).contains("/")
    }
}
