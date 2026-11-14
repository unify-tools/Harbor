import AppKit
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

    /// 把窗口内容渲染成 PNG（不需要屏幕录制权限）
    static func snapshot(_ window: NSWindow, to path: String) {
        guard let content = window.contentView,
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
        await wait()
        check(exists("folder/未命名文件夹") && !exists("folder/改名后"), "撤销重命名")

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
}
