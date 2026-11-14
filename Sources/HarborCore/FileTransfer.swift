import Foundation
import Synchronization

public enum TransferMode: Sendable {
    case copy, move
}

public struct TransferProgress: Sendable {
    public var totalBytes: Int64 = 0
    public var completedBytes: Int64 = 0
    public var totalItems = 0
    public var completedItems = 0
    public var currentName = ""

    public init() {}

    public var fraction: Double {
        if totalBytes > 0 { return min(Double(completedBytes) / Double(totalBytes), 1) }
        return totalItems > 0 ? Double(completedItems) / Double(totalItems) : 0
    }
}

public struct TransferConflict: Sendable {
    public let source: URL
    public let destination: URL
}

public enum ConflictDecision: Sendable {
    /// 原有项目移到废纸篓，再放入新项目
    case replace
    /// 新项目改名为「名称 2」
    case keepBoth
    case skip
    /// 停止整个操作
    case stop
}

public struct ConflictAnswer: Sendable {
    public let decision: ConflictDecision
    /// 后面的冲突都按这个处理，不再询问
    public let applyToAll: Bool

    public init(_ decision: ConflictDecision, applyToAll: Bool = false) {
        self.decision = decision
        self.applyToAll = applyToAll
    }
}

public struct TransferResult: Sendable {
    /// 出现在目标目录里的新项目
    public var destinations: [URL] = []
    /// 撤销这次操作要执行的步骤
    public var undoSteps: [UndoStep] = []
    public var errors: [FileOperationError] = []
    public var wasCancelled = false
}

/// 批量拷贝 / 移动：处理同名冲突、「放进自己里面」、原地拷贝，汇报进度，支持取消。
public final class FileTransfer: Sendable {
    public let mode: TransferMode
    public let sources: [URL]
    public let destination: URL
    private let context: TransferContext
    private let fileSystem: FileSystem

    public init(mode: TransferMode, sources: [URL], destination: URL, fileSystem: FileSystem = .live,
                onProgress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) {
        self.mode = mode
        self.sources = sources.map(\.standardizedFileURL)
        self.destination = destination.standardizedFileURL
        self.fileSystem = fileSystem
        context = TransferContext(onProgress: onProgress)
    }

    public func cancel() {
        context.cancel()
    }

    @concurrent
    public func run(resolve: @escaping @Sendable (TransferConflict) async -> ConflictAnswer) async -> TransferResult {
        await withTaskCancellationHandler {
            await perform(resolve: resolve)
        } onCancel: {
            context.cancel()
        }
    }

    private func perform(resolve: @Sendable (TransferConflict) async -> ConflictAnswer) async -> TransferResult {
        var result = TransferResult()
        var undoForward: [UndoStep] = []
        var restoreReplaced: [UndoStep] = []
        var applyToAll: ConflictDecision?

        // 同卷移动只是 rename，不用统计大小
        let destinationDevice = FileSystem.device(destination)
        let sizes = sources.map { source -> (bytes: Int64, files: Int) in
            if mode == .move, FileSystem.device(source) == destinationDevice { return (0, 1) }
            return TreeSize.measure(source)
        }
        context.start(totalBytes: sizes.reduce(0) { $0 + $1.bytes }, totalItems: sources.count)

        itemLoop: for (index, source) in sources.enumerated() {
            if context.isCancelled {
                result.wasCancelled = true
                break
            }
            context.beginItem(name: source.lastPathComponent)
            defer { context.finishItem(bytes: sizes[index].bytes) }

            let sourceKey = source.pathKey
            let destinationKey = destination.pathKey
            var target = destination.appending(path: source.lastPathComponent)

            if FileSystem.isDirectory(source), destinationKey == sourceKey || destinationKey.hasPrefix(sourceKey + "/") {
                result.errors.append(FileOperationError(url: source, message: "不能放进它自己里面。"))
                continue
            }

            if target.pathKey == sourceKey {
                // 原地移动什么都不做；原地拷贝自动生成副本
                if mode == .move { continue }
                target = FileNaming.uniqueURL(for: target)
            } else if FileSystem.exists(target) {
                if sourceKey.hasPrefix(target.pathKey + "/") {
                    result.errors.append(FileOperationError(url: source, message: "目标位置的同名项目包含它，不能替换。"))
                    continue
                }
                let decision: ConflictDecision
                if let applyToAll {
                    decision = applyToAll
                } else {
                    let answer = await resolve(TransferConflict(source: source, destination: target))
                    if answer.applyToAll { applyToAll = answer.decision }
                    decision = answer.decision
                }
                switch decision {
                case .skip:
                    continue
                case .stop:
                    result.wasCancelled = true
                    break itemLoop
                case .keepBoth:
                    target = FileNaming.uniqueURL(for: target)
                case .replace:
                    do {
                        let trashed = try fileSystem.trash(target)
                        restoreReplaced.append(.move(from: trashed, to: target))
                    } catch {
                        result.errors.append(FileOperationError(url: target, message: "无法把原有项目移到废纸篓：\(error.localizedDescription)"))
                        continue
                    }
                }
            }

            do throws(FileOperationError) {
                switch mode {
                case .copy:
                    try fileSystem.copyItem(from: source, to: target, context: context)
                    undoForward.append(.trash(target))
                case .move:
                    try fileSystem.moveItem(from: source, to: target, context: context)
                    undoForward.append(.move(from: target, to: source))
                }
                result.destinations.append(target)
            } catch {
                if error.isCancellation {
                    result.wasCancelled = true
                    break
                }
                result.errors.append(error)
            }
        }

        // 撤销时先把新项目挪走，再把被替换的原有项目放回去
        result.undoSteps = undoForward.reversed() + restoreReplaced
        context.report(force: true)
        return result
    }
}

/// 在拷贝线程、copyfile 回调和取消方之间共享的进度和取消状态
final class TransferContext: Sendable {
    private struct State {
        var progress = TransferProgress()
        /// 当前这一项开始前已完成的字节数
        var itemBase: Int64 = 0
        /// 当前这一项里已拷完的文件字节数
        var finishedInItem: Int64 = 0
        var lastReport = ContinuousClock.now - .seconds(1)
    }

    private let cancelled = Atomic<Bool>(false)
    private let state = Mutex(State())
    private let onProgress: @Sendable (TransferProgress) -> Void

    init(onProgress: @escaping @Sendable (TransferProgress) -> Void) {
        self.onProgress = onProgress
    }

    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
    }

    func start(totalBytes: Int64, totalItems: Int) {
        state.withLock {
            $0.progress.totalBytes = totalBytes
            $0.progress.totalItems = totalItems
        }
        report(force: true)
    }

    func beginItem(name: String) {
        state.withLock {
            $0.progress.currentName = name
            $0.finishedInItem = 0
        }
        report(force: true)
    }

    func finishItem(bytes: Int64) {
        state.withLock {
            $0.itemBase += bytes
            $0.finishedInItem = 0
            $0.progress.completedBytes = $0.itemBase
            $0.progress.completedItems += 1
        }
        report(force: false)
    }

    func fileFinished(bytes: Int64) {
        state.withLock {
            $0.finishedInItem += bytes
            $0.progress.completedBytes = $0.itemBase + $0.finishedInItem
        }
        report(force: false)
    }

    func currentFileProgress(bytes: Int64) {
        state.withLock { $0.progress.completedBytes = $0.itemBase + $0.finishedInItem + bytes }
        report(force: false)
    }

    /// 最多每 50ms 汇报一次
    func report(force: Bool) {
        let snapshot: TransferProgress? = state.withLock {
            let now = ContinuousClock.now
            guard force || now - $0.lastReport >= .milliseconds(50) else { return nil }
            $0.lastReport = now
            return $0.progress
        }
        if let snapshot { onProgress(snapshot) }
    }
}
