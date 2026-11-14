import AppKit
import HarborCore

/// HARBOR_SCRIPT=m3：双栏、标签页、命令面板、快速跳转、拷贝路径。
/// 启动目录里需要有 a.txt、b.txt、folder/、folder2/。结果打到 stderr，跑完退出。
/// 设置 HARBOR_SNAPSHOT_DIR 时顺便保存双栏、命令面板、快速跳转的截图。
/// 跑完把「双栏」偏好恢复原样；访问记录只放内存（见 RecentPlaces）。
@MainActor
enum M3Script {
    static func run() async {
        try? await Task.sleep(for: .seconds(1))
        guard let controller = MainWindowController.all.first, let window = controller.window else {
            return SmokeScript.finish("找不到窗口")
        }
        let originalDualPane = Preferences.dualPane
        // finish 里直接 exit，defer 不会执行，所以收尾都走这里
        func done(_ error: String?) {
            Preferences.dualPane = originalDualPane
            SmokeScript.finish(error)
        }
        window.makeKeyAndOrderFront(nil)
        let root = controller.activeBrowser.currentURL
        let fm = FileManager.default
        let snapshotDir = ProcessInfo.processInfo.environment["HARBOR_SNAPSHOT_DIR"]
        func exists(_ relative: String) -> Bool { fm.fileExists(atPath: root.appending(path: relative).path) }
        func check(_ condition: Bool, _ label: String) { SmokeScript.check(condition, label) }
        func send(_ action: String) {
            if !ResponderChain.send(Selector(action), in: window) { check(false, "动作 \(action) 没有对象响应") }
        }
        func wait(_ seconds: Double = 0.6) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        func select(_ names: String..., in browser: BrowserViewController) {
            let wanted = Set(names)
            browser.tableView.selectRowIndexes(IndexSet(browser.items.indices.filter { wanted.contains(browser.items[$0].name) }),
                                               byExtendingSelection: false)
            browser.focusList()
        }
        func tabCount() -> Int { window.tabGroup?.windows.count ?? 1 }
        func closeOtherTabs() async {
            for other in window.tabGroup?.windows ?? [] where other !== window { other.close() }
            window.makeKeyAndOrderFront(nil)
            await wait(0.3)
        }
        let tabKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\t",
                                      charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!

        // 双栏：打开时第二栏和当前位置一致，Tab 切换焦点
        if controller.isDualPane { send("toggleDualPane:") }
        let primary = controller.activeBrowser
        primary.focusList()
        send("toggleDualPane:")
        await wait()
        check(controller.isDualPane && controller.panes.count == 2, "打开双栏")
        guard controller.panes.count == 2 else { return done("双栏没打开，后面的步骤跳过") }
        let second = controller.panes[1]
        check(second.currentURL.pathKey == root.pathKey, "第二栏从当前位置开始")
        primary.tableView.keyDown(with: tabKey)
        check(controller.activeBrowser === second && window.firstResponder === second.tableView, "Tab 切到第二栏")
        for (index, pane) in controller.panes.enumerated() {
            let visible = pane.tableView.enclosingScrollView?.contentView.bounds.width ?? 0
            check(pane.tableView.frame.width <= visible + 1, "第 \(index + 1) 栏的列不超出可见宽度（\(Int(pane.tableView.frame.width)) / \(Int(visible))）")
        }
        if let dir = snapshotDir { DebugHooks.snapshot(window, to: dir + "/dual.png") }

        // F5 / F6：拷贝、移动到另一栏，另一栏选中新项目
        second.navigate(to: root.appending(path: "folder"))
        await wait()
        send("switchPane:")
        check(controller.activeBrowser === primary, "切换到另一栏（菜单命令）")
        select("a.txt", in: primary)
        send("copyToOtherPane:")
        await wait(1)
        check(exists("a.txt") && exists("folder/a.txt"), "拷贝到另一栏")
        check(second.selectedNames() == ["a.txt"], "另一栏选中拷贝过来的项目：\(second.selectedNames())")
        select("b.txt", in: primary)
        send("moveToOtherPane:")
        await wait(1)
        check(!exists("b.txt") && exists("folder/b.txt"), "移动到另一栏")

        // 焦点在第二栏时关闭双栏：焦点回到第一栏
        send("switchPane:")
        send("toggleDualPane:")
        await wait()
        check(!controller.isDualPane && controller.activeBrowser === primary && window.firstResponder === primary.tableView,
              "关闭双栏后焦点回到第一栏")

        // 标签页：⌘T 新标签在当前位置
        send("newWindowForTab:")
        await wait()
        check(tabCount() == 2 && MainWindowController.all.count == 2, "新建标签页（\(tabCount()) 个标签）")
        check(MainWindowController.all.last?.activeBrowser.currentURL.pathKey == root.pathKey, "新标签页在当前位置")
        await closeOtherTabs()
        check(MainWindowController.all.count == 1, "关闭标签页后释放")

        // 多选里的文件夹按顺序在后台标签页打开
        select("folder", "folder2", in: primary)
        send("openSelection:")
        await wait()
        let tabURLs = (window.tabGroup?.windows ?? []).compactMap { ($0.windowController as? MainWindowController)?.activeBrowser.currentURL.lastPathComponent }
        check(tabURLs == [root.lastPathComponent, "folder", "folder2"], "多选文件夹在新标签页打开：\(tabURLs)")
        check(window.tabGroup?.selectedWindow === window && primary.currentURL.pathKey == root.pathKey, "打开后停留在原标签页")
        await closeOtherTabs()

        // 命令面板：来自菜单、按当前状态过滤、支持拼音
        primary.tableView.deselectAll(nil)
        send("showCommandPalette:")
        await wait(0.3)
        guard let palette = QuickPanel.current else { return done("命令面板没有打开") }
        check(!palette.items.contains { $0.title == "移到废纸篓" } && palette.items.contains { $0.title == "新建文件夹" },
              "没有选中项时不列出「移到废纸篓」")
        palette.query = "xjwjj"
        check(palette.items.first?.title == "新建文件夹", "拼音首字母 xjwjj → \(palette.items.first?.title ?? "无")")
        palette.query = "kblj"
        check(palette.items.first?.title == "拷贝路径", "kblj → \(palette.items.first?.title ?? "无")")
        palette.query = "双栏"
        check(palette.items.first?.title == "双栏" && palette.items.first?.detail?.contains("⌘\\") == true,
              "标题匹配并显示快捷键：\(palette.items.first?.detail ?? "")")
        palette.query = "kb"
        if let dir = snapshotDir, let panelWindow = window.childWindows?.first { DebugHooks.snapshot(panelWindow, to: dir + "/palette.png") }
        palette.query = "新建标签页"
        palette.confirm(alternate: false)
        await wait()
        check(QuickPanel.current == nil && tabCount() == 2, "在命令面板里执行「新建标签页」")
        await closeOtherTabs()

        // 快速跳转：按访问记录模糊匹配
        primary.navigate(to: root.appending(path: "folder2"))
        await wait(0.3)
        primary.navigate(to: root)
        await wait(0.3)
        send("quickJump:")
        await wait(0.3)
        guard let jump = QuickPanel.current else { return done("快速跳转没有打开") }
        check(!jump.items.contains { $0.title == root.lastPathComponent }, "不列出当前所在的文件夹")
        jump.query = "fdr2"
        check(jump.items.first?.title == "folder2", "fdr2 → \(jump.items.first?.title ?? "无")")
        if let dir = snapshotDir, let panelWindow = window.childWindows?.first { DebugHooks.snapshot(panelWindow, to: dir + "/jump.png") }
        jump.confirm(alternate: false)
        await wait()
        check(primary.currentURL.lastPathComponent == "folder2", "回车跳转")
        send("quickJump:")
        await wait(0.3)
        QuickPanel.current?.query = "folder"
        QuickPanel.current?.confirm(alternate: true)
        await wait()
        check(tabCount() == 2 && MainWindowController.all.last?.activeBrowser.currentURL.lastPathComponent == "folder", "⌘回车在新标签页打开")
        await closeOtherTabs()

        // 拷贝路径：没有选中项时是当前文件夹；拷贝当前文件夹路径
        primary.navigate(to: root)
        await wait()
        primary.tableView.deselectAll(nil)
        send("copyPath:")
        check(NSPasteboard.general.string(forType: .string) == root.pathKey, "无选中项时拷贝当前文件夹路径")
        select("folder", in: primary)
        send("copyCurrentPath:")
        check(NSPasteboard.general.string(forType: .string) == root.pathKey, "拷贝当前文件夹路径")
        send("copyPath:")
        check(NSPasteboard.general.string(forType: .string) == root.appending(path: "folder").pathKey, "拷贝所选项目路径")

        // 输入文字时：⌘⌫ 不能落到列表上，⌘Z 不撤销文件操作
        select("folder", in: primary)
        primary.beginEditingPath()
        await wait(0.2)
        check(window.undoManager !== FileOperationCenter.shared.undoManager, "输入路径时 ⌘Z 不碰文件操作的撤销历史")
        if NSApp.keyWindow === window {
            let trashItem = allItems(NSApp.mainMenu).first { $0.action == #selector(BrowserViewController.moveToTrash(_:)) }
            trashItem?.menu?.update()
            check(trashItem?.isEnabled == false, "输入路径时「移到废纸篓」不可用")
            primary.focusList()
            trashItem?.menu?.update()
            check(trashItem?.isEnabled == true && window.undoManager === FileOperationCenter.shared.undoManager, "回到列表后恢复")
        } else {
            FileHandle.standardError.write(Data("[smoke] 跳过 菜单可用性（窗口不是 key window）\n".utf8))
            primary.focusList()
        }

        // 菜单里的标签页命令没有被系统重复插入
        let actions = allItems(NSApp.mainMenu).compactMap(\.action)
        for action in [#selector(NSWindow.selectNextTab(_:)), #selector(NSWindow.mergeAllWindows(_:)), #selector(NSWindow.toggleTabBar(_:))] {
            check(actions.filter { $0 == action }.count == 1, "菜单里只有一个 \(action)")
        }

        done(nil)
    }

    private static func allItems(_ menu: NSMenu?) -> [NSMenuItem] {
        guard let menu else { return [] }
        return menu.items.flatMap { [$0] + allItems($0.submenu) }
    }
}
