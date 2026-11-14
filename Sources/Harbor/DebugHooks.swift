import AppKit
import Quartz
import HarborCore

/// 验证用钩子，只在设置了对应环境变量时生效（release 构建也能用来测性能）：
/// - HARBOR_TIMING=1：每次加载目录完成后，在 stderr 打印条目数和耗时
/// - HARBOR_SNAPSHOT=<路径>：首次加载完成后把窗口内容渲染成 PNG（不需要屏幕录制权限；
///   边栏的系统材质画不出来，会是空白）
@MainActor
enum DebugHooks {
    private static let environment = ProcessInfo.processInfo.environment
    private static var snapshotTaken = false

    static func didLoad(_ view: NSView, count: Int, startedAt: ContinuousClock.Instant) {
        if environment["HARBOR_TIMING"] != nil {
            let elapsed = ContinuousClock.now - startedAt
            FileHandle.standardError.write(Data("[harbor] 加载 \(count) 项，耗时 \(elapsed.formatted(.units(allowed: [.milliseconds])))\n".utf8))
        }
        guard let path = environment["HARBOR_SNAPSHOT"], !snapshotTaken else { return }
        snapshotTaken = true
        // 等一轮布局和图标绘制
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let window = view.window { snapshot(window, to: path) }
        }
    }

    /// 把窗口内容渲染成 PNG（不需要屏幕录制权限）。
    /// 玻璃（NSGlassEffectView）这一层画不出来，连里面的内容也一起丢掉，所以改画它的 contentView
    static func snapshot(_ window: NSWindow, to path: String) {
        guard let content = (window.contentView as? NSGlassEffectView)?.contentView ?? window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
        FileHandle.standardError.write(Data("[harbor] 截图已保存 \(path)\n".utf8))
    }
}

/// HARBOR_SCRIPT=smoke：在启动目录里走一遍文件操作，全部经由真实的响应链和撤销管理器。
/// 用假的废纸篓（启动目录下的 .smoke-trash），不碰真实的废纸篓。结果打印到 stderr，跑完退出。
@MainActor
enum SmokeScript {
    private static var failures = 0

    static func runIfRequested() {
        switch ProcessInfo.processInfo.environment["HARBOR_SCRIPT"] {
        case "smoke": Task { await run() }
        case "m3": Task { await M3Script.run() }
        case "m4": Task { await M4Script.run() }
        case "m5": Task { await M5Script.run() }
        case "m8": Task { await M8Script.run() }
        default: break
        }
    }

    private static func run() async {
        try? await Task.sleep(for: .seconds(1))
        guard let controller = MainWindowController.all.first, let window = controller.window else { return finish("找不到窗口") }
        let browser = controller.activeBrowser
        window.makeKeyAndOrderFront(nil)
        let root = browser.currentURL
        let trash = root.appending(path: ".smoke-trash", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        FileOperationCenter.shared.fileSystem = FileSystem(trash: { url in
            let target = FileNaming.uniqueURL(for: trash.appending(path: url.lastPathComponent))
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        let fm = FileManager.default
        func exists(_ relative: String) -> Bool { fm.fileExists(atPath: root.appending(path: relative).path) }
        func send(_ action: String) {
            if !ResponderChain.send(Selector(action), in: window) { check(false, "动作 \(action) 没有对象响应") }
        }
        func select(_ names: String...) {
            let wanted = Set(names)
            let rows = IndexSet(browser.items.indices.filter { wanted.contains(browser.items[$0].name) })
            browser.tableView.selectRowIndexes(rows, byExtendingSelection: false)
            browser.focusList()
        }
        func wait(_ seconds: Double = 0.6) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        /// 异步的文件操作（撤销、重做）完成时间不固定，轮询等待，不用固定时长
        func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                await wait(0.1)
            }
            return condition()
        }

        // 菜单校验走 supplementalTarget：有选中项时「移到废纸篓」可用
        select("a.txt")
        let trashItem = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "移到废纸篓" }
        trashItem?.menu?.update()
        if NSApp.keyWindow === window {
            check(trashItem?.isEnabled == true, "有选中项时「移到废纸篓」可用")
        } else {
            // 菜单只校验 key window 的响应链，后台运行时测不了
            FileHandle.standardError.write(Data("[smoke] 跳过 菜单可用性（窗口不是 key window）\n".utf8))
        }

        // 拷贝 → 进入 folder → 粘贴
        send("copy:")
        browser.navigate(to: root.appending(path: "folder"))
        await wait()
        send("paste:")
        await wait()
        check(exists("folder/a.txt") && exists("a.txt"), "拷贝粘贴")
        check(FileOperationCenter.shared.undoManager.undoMenuItemTitle.contains("拷贝"), "撤销菜单标题：\(FileOperationCenter.shared.undoManager.undoMenuItemTitle)")

        send("undo:")
        await wait()
        check(!exists("folder/a.txt"), "撤销拷贝")
        send("redo:")
        await wait()
        check(exists("folder/a.txt"), "重做拷贝")

        // 再粘贴一次：同名冲突，点「保留两者」
        send("paste:")
        await wait()
        if let sheet = window.attachedSheet, let keep = findButton("保留两者", in: sheet.contentView) {
            keep.performClick(nil)
        } else {
            check(false, "冲突时弹出询问")
        }
        await wait()
        check(exists("folder/a 2.txt"), "冲突时保留两者")

        // 新建文件夹 → 自动进入重命名 → 改名
        send("newFolder:")
        await wait()
        if let field = browser.renamingField {
            field.stringValue = "改名后"
            browser.focusList()
        } else {
            check(false, "新建文件夹后进入重命名")
        }
        await wait()
        check(exists("folder/改名后") && !exists("folder/未命名文件夹"), "新建文件夹并重命名")
        send("undo:")
        check(await waitUntil(3) { exists("folder/未命名文件夹") && !exists("folder/改名后") }, "撤销重命名")

        // 回到上层，移到废纸篓再撤销
        browser.goUp()
        await wait()
        select("b.txt")
        send("moveToTrash:")
        await wait()
        check(!exists("b.txt") && fm.fileExists(atPath: trash.appending(path: "b.txt").path), "移到（假）废纸篓")
        send("undo:")
        await wait()
        check(exists("b.txt"), "撤销移到废纸篓")

        // 剪切 → 进入 folder → 粘贴 = 移动
        select("b.txt")
        send("cut:")
        browser.navigate(to: root.appending(path: "folder"))
        await wait()
        send("paste:")
        await wait()
        check(exists("folder/b.txt") && !exists("b.txt"), "剪切粘贴（移动）")

        // ⌘D 复制
        select("b.txt")
        send("duplicate:")
        await wait()
        check(exists("folder/b 2.txt"), "复制出副本")

        // 空格快速查看：打开、方向键换文件预览跟着变、再按空格关闭。第一次加载 Quick Look 较慢，轮询等待
        // 右键「打开方式」：默认应用排第一并标注，最后是「其他…」
        select("b.txt")
        let contextMenu = NSMenu()
        browser.populateContextMenu(contextMenu, row: browser.tableView.selectedRow)
        let openWith = contextMenu.items.first { $0.title == "打开方式" }?.submenu
        let apps = openWith?.items.filter { ($0.representedObject as? OpenWithChoice)?.app != nil } ?? []
        let expectedDefault = NSWorkspace.shared.urlForApplication(toOpen: root.appending(path: "folder/b.txt"))?.standardizedFileURL
        check(openWith != nil && (apps.first?.representedObject as? OpenWithChoice)?.app == expectedDefault && apps.first?.title.hasSuffix("（默认）") == true
              && apps.dropFirst().allSatisfy { !$0.title.hasSuffix("（默认）") } && openWith?.items.last?.title == "其他…",
              "右键「打开方式」：\(apps.map(\.title))")

        // 预览面板沿 key window 的响应链找控制者，应用在后台时没有 key window，测不了
        if NSApp.isActive {
            select("b.txt")
            let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: " ",
                                         charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
            browser.tableView.keyDown(with: space)
            let panel = QLPreviewPanel.shared()
            let previewing = { (panel?.currentPreviewItem?.previewItemURL)?.lastPathComponent ?? "无" }
            check(await waitUntil(5) { BrowserViewController.isQuickLookVisible && (panel?.dataSource as AnyObject?) === browser && previewing() == "b.txt" },
                  "空格打开快速查看：\(previewing())")
            select("b 2.txt")
            check(await waitUntil(3) { previewing() == "b 2.txt" }, "换选中项后预览跟着变：\(previewing())")
            browser.tableView.keyDown(with: space)
            check(await waitUntil(3) { !BrowserViewController.isQuickLookVisible }, "再按空格关闭快速查看")
            // 预览在前面时 ⌘Y 关闭：走真实的事件分发（菜单快捷键，动作沿主窗口的响应链找到这一栏）
            browser.tableView.keyDown(with: space)
            if await waitUntil(5, { BrowserViewController.isQuickLookVisible }), let panel {
                let commandY = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                windowNumber: panel.windowNumber, context: nil, characters: "y",
                                                charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16)!
                NSApp.sendEvent(commandY)
                check(await waitUntil(3) { !BrowserViewController.isQuickLookVisible }, "预览在前面时 ⌘Y 关闭快速查看")
            } else {
                check(false, "再次按空格打开快速查看")
            }
        } else {
            FileHandle.standardError.write(Data("[smoke] 跳过 快速查看（应用不在前台）\n".utf8))
        }

        finish(nil)
    }

    static func check(_ condition: Bool, _ label: String) {
        if !condition { failures += 1 }
        FileHandle.standardError.write(Data("[smoke] \(condition ? "通过" : "失败") \(label)\n".utf8))
    }

    static func finish(_ error: String?) {
        if let error { check(false, error) }
        FileHandle.standardError.write(Data("[smoke] 结束，失败 \(failures) 项\n".utf8))
        exit(failures == 0 ? 0 : 1)
    }

    static func findButton(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let found = findButton(title, in: subview) { return found }
        }
        return nil
    }

    static func findViews<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        var result: [T] = []
        if let match = view as? T { result.append(match) }
        for subview in view.subviews { result += findViews(type, in: subview) }
        return result
    }
}
