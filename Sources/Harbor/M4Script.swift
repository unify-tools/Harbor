import AppKit
import HarborCore

/// HARBOR_SCRIPT=m4：内嵌终端。用真实的用户 shell 和配置跑，验证目录双向同步。
/// 启动目录里需要有 folder/、folder2/、「with space/」。设置 HARBOR_SNAPSHOT_DIR 时保存带终端的截图。
@MainActor
enum M4Script {
    static func run() async {
        try? await Task.sleep(for: .seconds(1))
        guard let controller = MainWindowController.all.first, let window = controller.window else {
            return SmokeScript.finish("找不到窗口")
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // 上次运行（或用户）把边栏收起来了的话先展开，后面的检查从固定状态开始
        if controller.isSidebarCollapsed {
            ResponderChain.send(#selector(NSSplitViewController.toggleSidebar(_:)), in: window)
            try? await Task.sleep(for: .milliseconds(800))
        }
        let primary = controller.activeBrowser
        let root = primary.currentURL
        let terminal = controller.terminal
        let folder = root.appending(path: "folder"), folder2 = root.appending(path: "folder2")
        func check(_ condition: Bool, _ label: String) { SmokeScript.check(condition, label) }
        func send(_ action: String) {
            if !ResponderChain.send(Selector(action), in: window) { check(false, "动作 \(action) 没有对象响应") }
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        /// 轮询到条件成立或超时
        func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
            while ContinuousClock.now < deadline {
                if condition() { return true }
                await wait(0.1)
            }
            return condition()
        }
        func type(_ text: String) { terminal.terminalView?.send(data: Array(text.utf8)[...]) }
        func screenText() -> String {
            guard let view = terminal.terminalView else { return "" }
            view.selectAll(nil)
            return view.getSelection() ?? ""
        }

        // 打开终端：在当前目录启动，shell 用 OSC 7 报告目录
        send("toggleTerminal:")
        check(controller.isTerminalVisible && terminal.isRunning, "⌃` 打开终端并启动 shell")
        check(window.firstResponder is HarborTerminalView, "焦点在终端")
        let started = await waitUntil(15) { terminal.reportedDirectory == root.pathKey }
        check(started, "shell 报告当前目录（OSC 7）：\(terminal.reportedDirectory ?? "无")")
        guard started else { return SmokeScript.finish("shell integration 没生效，后面的步骤跳过") }

        // 浏览区 → 终端
        primary.navigate(to: folder)
        check(await waitUntil(5) { terminal.reportedDirectory == folder.pathKey }, "浏览区跳转后终端跟着 cd")

        // 终端 → 浏览区
        type("cd ../folder2\r")
        check(await waitUntil(5) { primary.currentURL.pathKey == folder2.pathKey }, "终端 cd 后浏览区跟着跳")

        // 静默 cd 不清掉用户输入到一半的命令
        type("echo harbor-kept")
        await wait(0.3)
        primary.navigate(to: root)
        check(await waitUntil(5) { terminal.reportedDirectory == root.pathKey }, "输入到一半时也能同步")
        type("\r")
        await wait(0.5)
        let lines = screenText().split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        check(lines.contains("harbor-kept"), "输入到一半的命令被保留并执行")

        // 终端在跑命令时先排队，回到提示符后再同步；浏览区不会被弹回去
        type("sleep 1.5\r")
        await wait(0.4)
        primary.navigate(to: folder)
        await wait(0.4)
        check(terminal.reportedDirectory == root.pathKey && terminal.pendingDirectory == folder.pathKey, "命令运行时不发按键，先排队")
        check(await waitUntil(6) { terminal.reportedDirectory == folder.pathKey }, "命令结束后补上同步")
        check(primary.currentURL.pathKey == folder.pathKey, "浏览区停在原处，没被弹回")

        // 连续快速跳转：迟到的中间目录报告不会把浏览区拽回去
        primary.navigate(to: folder2)
        primary.navigate(to: root)
        primary.navigate(to: folder)
        await wait(3)
        check(primary.currentURL.pathKey == folder.pathKey && terminal.reportedDirectory == folder.pathKey,
              "连续跳转后两边都停在最后的目录（浏览区 \(primary.currentURL.lastPathComponent)，终端 \((terminal.reportedDirectory as NSString?)?.lastPathComponent ?? "无")）")

        // 命令输出里夹带的 OSC 7 不算数（前台不是 shell）
        // 要在命令还在跑时检查：回到提示符后 shell 会再报一次真实目录，浏览区就被拉回来了，看不出问题
        type("printf '\\033]7;file:///etc\\007'; sleep 2\r")
        await wait(1)
        check(primary.currentURL.pathKey == folder.pathKey, "命令输出里的 OSC 7 不让浏览区跳走（\(primary.currentURL.pathKey)）")
        _ = await waitUntil(4) { terminal.pendingDirectory == nil && primary.currentURL.pathKey == folder.pathKey }
        await wait(1.5)

        // 焦点在终端时：⌘⌫ 等不作用于列表，⌘Z 不撤销文件操作
        window.makeFirstResponder(terminal.terminalView)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        await wait(0.3)
        if NSApp.keyWindow === window {
            let items = allItems(NSApp.mainMenu)
            for action in [#selector(BrowserViewController.moveToTrash(_:)), #selector(NSText.cut(_:)), #selector(MainWindowController.goUp(_:))] {
                let item = items.first { $0.action == action }
                item?.menu?.update()
                check(item?.isEnabled == false, "终端里「\(item?.title ?? "?")」不可用")
            }
        } else {
            // 窗口不是 key 时菜单不按它校验，直接调校验函数（逻辑相同）
            for (target, action) in [(primary as NSMenuItemValidation, #selector(BrowserViewController.moveToTrash(_:))),
                                     (primary, #selector(NSText.cut(_:))),
                                     (controller, #selector(MainWindowController.goUp(_:)))] {
                let item = NSMenuItem(title: "\(action)", action: action, keyEquivalent: "")
                check(!target.validateMenuItem(item), "终端里 \(action) 不可用（直接校验）")
            }
        }
        check(window.undoManager !== FileOperationCenter.shared.undoManager, "终端里 ⌘Z 不碰文件操作的撤销历史")

        // 剪贴板里是文件：粘贴成转义过的路径
        let spaced = root.appending(path: "with space")
        let entry = NSPasteboardItem()
        entry.setString(spaced.absoluteString, forType: .fileURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([entry])
        send("paste:")
        await wait(0.5)
        check(screenText().contains("'\(spaced.pathKey)'"), "粘贴文件成为带引号的路径")
        type("\u{15}")

        // 嵌套分栏后「显示/隐藏边栏」仍然送到最外层（里层的分栏控制器不能把它吞掉）。
        // 只断言状态：应用不在前台时收起动画不执行，量不到实际宽度
        primary.focusList()
        send("toggleSidebar:")
        check(controller.isSidebarCollapsed, "焦点在列表时「显示/隐藏边栏」送到外层分栏")
        send("toggleSidebar:")
        check(!controller.isSidebarCollapsed, "再展开边栏")

        if let dir = ProcessInfo.processInfo.environment["HARBOR_SNAPSHOT_DIR"] {
            await wait(0.5)
            DebugHooks.snapshot(window, to: dir + "/terminal.png")
        }

        // ⌃`：焦点不在终端时先聚焦，在终端时收起；收起不结束进程
        send("toggleTerminal:")
        check(window.firstResponder is HarborTerminalView, "再按 ⌃` 聚焦终端")
        send("toggleTerminal:")
        check(!controller.isTerminalVisible && window.firstResponder === primary.tableView && terminal.isRunning, "收起终端，焦点回到列表，shell 保留")
        send("toggleTerminal:")
        check(controller.isTerminalVisible && terminal.reportedDirectory == folder.pathKey, "重新打开还是原来的 shell")

        // shell 退出：终端收起，下次打开重新启动
        type("exit\r")
        check(await waitUntil(5) { !terminal.isRunning && !controller.isTerminalVisible }, "exit 后终端收起")
        check(window.firstResponder === primary.tableView, "焦点回到列表")

        SmokeScript.finish(nil)
    }

    private static func allItems(_ menu: NSMenu?) -> [NSMenuItem] {
        guard let menu else { return [] }
        return menu.items.flatMap { [$0] + allItems($0.submenu) }
    }
}
