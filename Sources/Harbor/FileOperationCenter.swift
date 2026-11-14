import AppKit
import HarborCore

/// 进行中的一次拷贝 / 移动，供进度条显示
@MainActor
final class TransferActivity {
    let title: String
    let startedAt = ContinuousClock.now
    var progress = TransferProgress()
    fileprivate var cancelHandler: () -> Void = {}

    init(title: String) {
        self.title = title
    }

    func cancel() {
        cancelHandler()
    }
}

/// 全局的文件操作入口：执行操作、记录撤销、汇报进度。所有窗口共用一份撤销历史（和 Finder 一样）。
///
/// 撤销和 NSUndoManager 的配合：NSUndoManager 只负责菜单标题和撤销/重做的次序，
/// 真正的数据在 undoEntries / redoEntries 里。撤销、重做的执行排进一个串行队列，
/// 这样连按几次 ⌘Z 时，后一次一定在前一次完成后才开始。
@MainActor
final class FileOperationCenter {
    static let shared = FileOperationCenter()
    static let didChange = Notification.Name("HarborFileOperationsDidChange")

    let undoManager = UndoManager()
    private(set) var activeTransfers: [TransferActivity] = []
    /// 冒烟脚本里换成假的废纸篓
    var fileSystem = FileSystem.live

    private final class UndoEntry {
        let name: String
        /// 撤销条目在执行完之前就要入栈（重做要用），步骤稍后填上
        var steps: [UndoStep]
        init(name: String, steps: [UndoStep]) {
            self.name = name
            self.steps = steps
        }
    }

    private var undoEntries: [UndoEntry] = []
    private var redoEntries: [UndoEntry] = []
    private var queueTail: Task<Void, Never>?

    /// 撤销 / 重做过程中出错时，交给当前窗口提示
    var errorPresenter: (([FileOperationError], String) -> Void)?

    // MARK: - 操作

    func transfer(_ mode: TransferMode, sources: [URL], to destination: URL, presenter: BrowserViewController) async -> TransferResult {
        let verb = mode == .copy ? "拷贝" : "移动"
        let what = sources.count == 1 ? "「\(sources[0].lastPathComponent)」" : "\(sources.count) 项"
        let activity = TransferActivity(title: "正在\(verb)\(what)到「\(destination.lastPathComponent)」")
        let transfer = FileTransfer(mode: mode, sources: sources, destination: destination, fileSystem: fileSystem) { progress in
            Task { @MainActor in
                activity.progress = progress
                FileOperationCenter.shared.notify()
            }
        }
        activity.cancelHandler = { transfer.cancel() }
        activeTransfers.append(activity)
        notify()
        // 很快结束的操作不显示进度条；超过 0.3 秒再刷新一次让进度条出现
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            notify()
        }

        let askMultiple = sources.count > 1
        let result = await transfer.run { conflict in
            await ConflictPrompt.ask(conflict, presenter: presenter, offerApplyToAll: askMultiple)
        }

        activeTransfers.removeAll { $0 === activity }
        notify()
        if !result.undoSteps.isEmpty {
            register(name: "\(verb)\(what)", steps: result.undoSteps)
        }
        return result
    }

    func trash(_ urls: [URL]) async -> [FileOperationError] {
        let fileSystem = fileSystem
        let (undo, errors) = await Task.detached { FileActions.trash(urls, fileSystem: fileSystem) }.value
        if !undo.isEmpty {
            register(name: "移到废纸篓", steps: undo)
        }
        return errors
    }

    func delete(_ urls: [URL]) async -> [FileOperationError] {
        await Task.detached { FileActions.delete(urls) }.value
    }

    func rename(_ url: URL, to newName: String) async -> Result<URL, FileOperationError> {
        let result = await Task.detached { () -> Result<URL, FileOperationError> in
            do throws(FileOperationError) {
                return .success(try FileActions.rename(url, to: newName))
            } catch {
                return .failure(error)
            }
        }.value
        if case .success(let renamed) = result {
            register(name: "重命名", steps: [.move(from: renamed, to: url)])
        }
        return result
    }

    func createFolder(in directory: URL, name: String) async -> Result<URL, FileOperationError> {
        let result = await Task.detached { () -> Result<URL, FileOperationError> in
            do throws(FileOperationError) {
                return .success(try FileActions.createFolder(in: directory, name: name))
            } catch {
                return .failure(error)
            }
        }.value
        if case .success(let folder) = result {
            register(name: "新建文件夹", steps: [.trash(folder)])
        }
        return result
    }

    // MARK: - 压缩、解压

    /// 解压到 directory。加密的压缩包弹窗要密码，输错可以重试
    func extract(_ archive: URL, into directory: URL, presenter: BrowserViewController) async -> Result<Archives.ExtractResult, ArchiveError> {
        var password: String?
        while true {
            let attempt = password
            let result = await runArchiveTask(title: "正在解压「\(archive.lastPathComponent)」") { cancellation, progress throws(ArchiveError) in
                try Archives.extract(archive, into: directory, password: attempt, cancellation: cancellation, progress: progress)
            }
            switch result {
            case .failure(let error) where error == .passwordRequired || error == .wrongPassword:
                guard let entered = await PasswordPrompt.ask(for: archive, retry: error == .wrongPassword, presenter: presenter) else {
                    return .failure(.cancelled)
                }
                password = entered
            case .success(let extracted):
                register(name: "解压「\(archive.lastPathComponent)」", steps: [.trash(extracted.output)])
                return result
            case .failure:
                return result
            }
        }
    }

    func compress(_ sources: [URL], format: ArchiveFormat, in directory: URL) async -> Result<URL, ArchiveError> {
        let what = sources.count == 1 ? "「\(sources[0].lastPathComponent)」" : "\(sources.count) 项"
        let result = await runArchiveTask(title: "正在压缩\(what)") { cancellation, progress throws(ArchiveError) in
            try Archives.create(sources, format: format, in: directory, cancellation: cancellation, progress: progress)
        }
        if case .success(let archive) = result {
            register(name: "压缩\(what)", steps: [.trash(archive)])
        }
        return result
    }

    /// 在后台跑压缩 / 解压，进度和取消接到操作栏上
    private func runArchiveTask<T: Sendable>(
        title: String,
        _ work: @escaping @Sendable (ArchiveCancellation, @escaping @Sendable (ArchiveProgress) -> Void) throws(ArchiveError) -> T
    ) async -> Result<T, ArchiveError> {
        let activity = TransferActivity(title: title)
        let cancellation = ArchiveCancellation()
        activity.cancelHandler = { cancellation.cancel() }
        activeTransfers.append(activity)
        notify()
        // 很快结束的操作不显示进度条；超过 0.3 秒再刷新一次让进度条出现
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            notify()
        }
        let result = await Task.detached { () -> Result<T, ArchiveError> in
            do throws(ArchiveError) {
                return .success(try work(cancellation) { progress in
                    Task { @MainActor in
                        activity.progress.totalBytes = progress.totalBytes
                        activity.progress.completedBytes = progress.completedBytes
                        activity.progress.currentName = progress.currentName
                        FileOperationCenter.shared.notify()
                    }
                })
            } catch {
                return .failure(error)
            }
        }.value
        activeTransfers.removeAll { $0 === activity }
        notify()
        return result
    }

    // MARK: - 撤销

    private func register(name: String, steps: [UndoStep]) {
        undoEntries.append(UndoEntry(name: name, steps: steps))
        redoEntries.removeAll()
        registerHandler(redo: false, name: name)
    }

    /// 在撤销中注册的动作会成为重做，在重做中注册的会成为撤销
    private func registerHandler(redo: Bool, name: String) {
        undoManager.registerUndo(withTarget: self) { center in
            MainActor.assumeIsolated {
                redo ? center.performRedo() : center.performUndo()
            }
        }
        undoManager.setActionName(name)
    }

    private func performUndo() {
        guard let entry = undoEntries.popLast() else { return }
        let redoEntry = UndoEntry(name: entry.name, steps: [])
        redoEntries.append(redoEntry)
        registerHandler(redo: true, name: entry.name)
        enqueue { [weak self] in
            // 重做的步骤要等前一次撤销执行完才填好，所以在队列里轮到时再读
            let steps = entry.steps
            let fileSystem = self?.fileSystem ?? .live
            let (inverse, errors) = await Task.detached { FileActions.perform(steps, fileSystem: fileSystem) }.value
            redoEntry.steps = inverse
            if !errors.isEmpty { self?.errorPresenter?(errors, "撤销「\(entry.name)」时出错") }
        }
    }

    private func performRedo() {
        guard let entry = redoEntries.popLast() else { return }
        let undoEntry = UndoEntry(name: entry.name, steps: [])
        undoEntries.append(undoEntry)
        registerHandler(redo: false, name: entry.name)
        enqueue { [weak self] in
            // 重做的步骤要等前一次撤销执行完才填好，所以在队列里轮到时再读
            let steps = entry.steps
            let fileSystem = self?.fileSystem ?? .live
            let (inverse, errors) = await Task.detached { FileActions.perform(steps, fileSystem: fileSystem) }.value
            undoEntry.steps = inverse
            if !errors.isEmpty { self?.errorPresenter?(errors, "重做「\(entry.name)」时出错") }
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queueTail
        queueTail = Task {
            await previous?.value
            await work()
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// 加密压缩包的密码输入
@MainActor
enum PasswordPrompt {
    /// 取消时返回 nil
    static func ask(for archive: URL, retry: Bool, presenter: BrowserViewController) async -> String? {
        let alert = NSAlert()
        alert.messageText = retry ? "密码不正确，请重新输入" : "「\(archive.lastPathComponent)」已加密"
        alert.informativeText = "输入解压密码。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "解压")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        let response: NSApplication.ModalResponse
        if let window = presenter.view.window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

/// 同名冲突时弹出的询问
@MainActor
enum ConflictPrompt {
    static func ask(_ conflict: TransferConflict, presenter: BrowserViewController, offerApplyToAll: Bool) async -> ConflictAnswer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "「\(conflict.destination.lastPathComponent)」已存在"
        alert.informativeText = "「\(conflict.destination.deletingLastPathComponent().lastPathComponent)」里已有同名的项目。选择「替换」时，原有项目会移到废纸篓。"
        let decisions: [ConflictDecision] = [.replace, .keepBoth, .skip, .stop]
        for title in ["替换", "保留两者", "跳过", "停止"] {
            alert.addButton(withTitle: title)
        }
        if offerApplyToAll {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "对后面的冲突都这样处理"
        }

        let response: NSApplication.ModalResponse
        if let window = presenter.view.window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let decision = decisions.indices.contains(index) ? decisions[index] : .stop
        return ConflictAnswer(decision, applyToAll: alert.suppressionButton?.state == .on)
    }
}
