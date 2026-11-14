import AppKit
import HarborCore
import SwiftTerm

/// 窗口底部的内嵌终端，和活动的那一栏双向同步目录：
/// - 终端里 cd：shell 在提示符处用 OSC 7 报告目录 → onDirectoryChange → 浏览区跟着跳
/// - 浏览区跳转：sync(to:) 把目标写进 cdFile，再发一个绑定了「静默 cd」的按键序列给 shell。
///   终端里正在跑命令时（前台进程组不是 shell）先记下来，等回到提示符再发
@MainActor
final class TerminalPanelController: NSViewController, LocalProcessTerminalViewDelegate {
    var onDirectoryChange: ((URL) -> Void)?
    var onExit: (() -> Void)?

    private(set) var terminalView: HarborTerminalView?
    /// shell 最近一次报告的目录
    private(set) var reportedDirectory: String?
    /// 等 shell 回到提示符后再切过去的目录
    private(set) var pendingDirectory: String?
    /// 已经发出按键、shell 还没报告到达的目录。在途期间迟到的 OSC 7（中间目录）不拿来驱动浏览区，
    /// 否则连按 ⌘[ 时浏览区会被拽回中间那一级。shell 没响应时 2 秒后作废
    private var inFlight: (path: String, deadline: ContinuousClock.Instant)?
    private var lastSend: ContinuousClock.Instant?
    /// 本次 shell 的令牌（见 ShellIntegration.launch）。见过带令牌的报告后，只认带令牌的
    private var session = UUID().uuidString
    private var sawSessionReport = false
    private var shellKind = ShellIntegration.Kind.unsupported
    private let cdFile = FileManager.default.temporaryDirectory
        .appending(path: "harbor-cd-\(UUID().uuidString)")

    var isRunning: Bool { terminalView?.process?.running == true }

    override func loadView() {
        view = NSView()
    }

    // MARK: - 进程

    func start(in directory: URL) {
        guard terminalView == nil else { return }
        let terminal = HarborTerminalView(frame: view.bounds)
        terminal.autoresizingMask = [.width, .height]
        terminal.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.processDelegate = self
        view.addSubview(terminal)
        terminalView = terminal

        let shell = Self.userShell()
        shellKind = ShellIntegration.kind(ofShell: shell)
        var environment = Self.baseEnvironment()
        var args: [String] = []
        var execName = "-" + (shell as NSString).lastPathComponent
        if shellKind != .unsupported, let integration = Self.integrationDirectory {
            session = UUID().uuidString
            sawSessionReport = false
            let launch = ShellIntegration.launch(shell: shell, directory: integration, cdFile: cdFile,
                                                 session: session, environment: environment)
            environment = launch.environment
            args = launch.args
            execName = launch.execName
        }
        reportedDirectory = nil
        pendingDirectory = nil
        terminal.startProcess(executable: shell, args: args,
                              environment: environment.map { "\($0.key)=\($0.value)" },
                              execName: execName, currentDirectory: directory.path(percentEncoded: false))
    }

    /// 关窗口时结束 shell：发 SIGHUP（和 Terminal.app 一样），交互式 shell 会忽略 SIGTERM；
    /// 收到 SIGHUP 的 shell 会保存历史、通知自己的后台作业
    func terminate() {
        guard let terminal = terminalView else { return }
        // 主动结束的不再回调 onExit
        terminal.processDelegate = nil
        if let process = terminal.process, process.running, process.shellPid > 0 {
            kill(process.shellPid, SIGHUP)
        }
        discardTerminal()
    }

    private func discardTerminal() {
        // SwiftTerm 要求永久移除视图前停掉渲染循环
        _ = terminalView?.updateUiClosed()
        terminalView?.removeFromSuperview()
        terminalView = nil
        reportedDirectory = nil
        pendingDirectory = nil
        inFlight = nil
        lastSend = nil
        try? FileManager.default.removeItem(at: cdFile)
    }

    // MARK: - 浏览区 → 终端

    func sync(to url: URL) {
        guard isRunning, shellKind != .unsupported else { return }
        let path = url.pathKey
        // 和「shell 即将到达的目录」比，而不是只和上次报告的比：跳到 X 还没到、又退回 A 时也要再发一次
        guard path != (activeInFlight?.path ?? reportedDirectory) else {
            pendingDirectory = nil
            return
        }
        pendingDirectory = path
        flushPending()
    }

    private var activeInFlight: (path: String, deadline: ContinuousClock.Instant)? {
        guard let inFlight, ContinuousClock.now < inFlight.deadline else { return nil }
        return inFlight
    }

    /// 前台进程组是 shell：停在提示符或在输入命令，而不是在跑别的程序
    private var isShellForeground: Bool {
        guard let process = terminalView?.process, process.running else { return false }
        return tcgetpgrp(process.childfd) == process.shellPid
    }

    /// shell 在前台时才发，否则会把按键发给正在运行的程序
    private func flushPending() {
        guard let target = pendingDirectory, isShellForeground, let process = terminalView?.process else { return }
        // 上次写的文件一秒多了还没被取走：集成失效了（exec 了别的 shell、在 read 里等输入），
        // 再发按键只会往命令行里插垃圾字符。文件被取走后自动恢复
        if FileManager.default.fileExists(atPath: cdFile.path(percentEncoded: false)),
           let lastSend, ContinuousClock.now - lastSend > .seconds(1) {
            return
        }
        do {
            try Data(target.utf8).write(to: cdFile, options: .atomic)
        } catch {
            return
        }
        pendingDirectory = nil
        inFlight = (target, ContinuousClock.now + .seconds(2))
        lastSend = ContinuousClock.now
        // 直接写给进程，不经过视图：视图的 send 会把正在翻看的回滚拉到底部
        process.send(data: Array(ShellIntegration.cdKeySequence.utf8)[...])
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // 命令输出、cat 的文件内容、ssh 远端的 shell 都可能发 OSC 7，不能让浏览区乱跳。
        // 注入了集成的 shell 在主机名位置带会话令牌（子进程拿不到），只认它；
        // 没注入的 shell（fish 等）退而求其次：本机主机名，且前台是 shell
        guard let directory, let path = ShellIntegration.directory(fromOSC7: directory) else { return }
        let host = ShellIntegration.host(fromOSC7: directory)
        if host == session {
            sawSessionReport = true
        } else if sawSessionReport || !isShellForeground
                    || !ShellIntegration.isLocalHost(host, localNames: Self.localHostNames) {
            return
        }
        let changed = path != reportedDirectory
        reportedDirectory = path
        if pendingDirectory == path { pendingDirectory = nil }
        if let flight = activeInFlight {
            // 同步在途：到了就结束在途状态；没到（迟到的中间目录）不驱动浏览区
            if flight.path == path { inFlight = nil }
        } else {
            inFlight = nil
            if changed { onDirectoryChange?(URL(filePath: path, directoryHint: .isDirectory)) }
        }
        // 每次回到提示符都会报告一次：趁这时把命令运行期间积压的同步发出去
        flushPending()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        discardTerminal()
        onExit?()
    }

    /// shell 没能启动（路径错、没权限）：清掉视图，下次打开重新尝试
    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        FileHandle.standardError.write(Data("[harbor] 终端启动失败：\(error)\n".utf8))
        discardTerminal()
        onExit?()
    }

    private static let localHostNames: Set<String> = {
        var names: Set<String> = [ProcessInfo.processInfo.hostName]
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            names.insert(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        if let local = Host.current().localizedName { names.insert(local) }
        return names
    }()

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    // MARK: - 环境

    private static func userShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }

    /// 从图形界面启动时没有 LANG，中文文件名会显示成转义；按系统语言补上
    private static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HARBOR_") }
        // 调试脚本敲的命令不进用户的 shell 历史
        if ProcessInfo.processInfo.environment["HARBOR_SCRIPT"] != nil { env["HARBOR_NO_HISTORY"] = "1" }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Harbor"
        if env["LANG"] == nil {
            let language = Locale.current.language
            let candidate = [language.languageCode?.identifier, language.region?.identifier].compactMap { $0 }.joined(separator: "_") + ".UTF-8"
            env["LANG"] = FileManager.default.fileExists(atPath: "/usr/share/locale/" + candidate) ? candidate : "en_US.UTF-8"
        }
        return env
    }

    /// 脚本每次启动程序时重写一遍，和程序版本保持一致
    private static let integrationDirectory: URL? = {
        let directory = URL.applicationSupportDirectory.appending(path: "Harbor/shell-integration", directoryHint: .isDirectory)
        do {
            try ShellIntegration.install(in: directory)
            return directory
        } catch {
            FileHandle.standardError.write(Data("[harbor] 写入 shell integration 失败：\(error)\n".utf8))
            return nil
        }
    }()
}

/// 支持把文件粘贴、拖进终端：插入转义过的路径
final class HarborTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 剪贴板里有文件（在 Harbor 或 Finder 里 ⌘C 的）时粘贴成路径。
    /// Finder 同时还放了文件名字符串，这里优先用文件
    override func paste(_ sender: Any) {
        let pasteboard = NSPasteboard.general
        if let urls = Self.fileURLs(pasteboard) {
            insertPaths(urls)
            return
        }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = Self.fileURLs(sender.draggingPasteboard) else { return false }
        insertPaths(urls)
        window?.makeFirstResponder(self)
        return true
    }

    private func insertPaths(_ urls: [URL]) {
        let text = urls.map { ShellIntegration.quote($0.pathKey) }.joined(separator: " ") + " "
        process?.send(data: Array(text.utf8)[...])
    }

    private static func fileURLs(_ pasteboard: NSPasteboard) -> [URL]? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }
}
