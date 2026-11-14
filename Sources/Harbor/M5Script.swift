import AppKit
import HarborCore

/// HARBOR_SCRIPT=m5：压缩、解压。启动目录里需要有 docs/a.txt、docs/sub/b.txt、x.txt、
/// enc.zip（密码 pw，内含 secret.txt）、big.bin（几十 MB 随机数据，测取消）。
/// 用假的废纸篓（启动目录下的 .smoke-trash）。
@MainActor
enum M5Script {
    static func run() async {
        try? await Task.sleep(for: .seconds(1))
        guard let controller = MainWindowController.all.first, let window = controller.window else {
            return SmokeScript.finish("找不到窗口")
        }
        window.makeKeyAndOrderFront(nil)
        let browser = controller.activeBrowser
        let root = browser.currentURL
        let fm = FileManager.default
        let trash = root.appending(path: ".smoke-trash", directoryHint: .isDirectory)
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        FileOperationCenter.shared.fileSystem = FileSystem(trash: { url in
            let target = FileNaming.uniqueURL(for: trash.appending(path: url.lastPathComponent))
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        func check(_ condition: Bool, _ label: String) { SmokeScript.check(condition, label) }
        func exists(_ relative: String) -> Bool { fm.fileExists(atPath: root.appending(path: relative).path) }
        func text(_ relative: String) -> String? { try? String(contentsOf: root.appending(path: relative), encoding: .utf8) }
        func send(_ action: String) {
            if !ResponderChain.send(Selector(action), in: window) { check(false, "动作 \(action) 没有对象响应") }
        }
        func wait(_ seconds: Double = 0.8) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
            while ContinuousClock.now < deadline {
                if condition() { return true }
                await wait(0.1)
            }
            return condition()
        }
        func select(_ names: String...) {
            let wanted = Set(names)
            browser.tableView.selectRowIndexes(IndexSet(browser.items.indices.filter { wanted.contains(browser.items[$0].name) }),
                                               byExtendingSelection: false)
            browser.focusList()
        }
        func leftovers() -> [String] {
            ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix(".harbor-") }
        }
        /// 在密码框里填密码，点按钮
        func answerPassword(_ password: String?, expectRetry: Bool) async -> Bool {
            guard await waitUntil(3, { window.attachedSheet != nil }), let sheet = window.attachedSheet else { return false }
            let title = (sheet.contentView.flatMap { findLabels(in: $0) } ?? []).joined()
            if expectRetry != title.contains("不正确") { check(false, "密码框标题不对：\(title)") }
            if let password, let field = findSecureField(in: sheet.contentView) { field.stringValue = password }
            let button = SmokeScript.findButton(password == nil ? "取消" : "解压", in: sheet.contentView)
            button?.performClick(nil)
            return button != nil
        }

        // 压缩 → 撤销 → 重做
        select("docs")
        send("compressZip:")
        check(await waitUntil(5) { exists("docs.zip") }, "压缩为 ZIP")
        await wait(0.5)
        check(browser.selectedNames() == ["docs.zip"], "压缩后选中压缩包：\(browser.selectedNames())")
        check(FileOperationCenter.shared.undoManager.undoMenuItemTitle.contains("压缩"), "撤销菜单标题：\(FileOperationCenter.shared.undoManager.undoMenuItemTitle)")
        send("undo:")
        check(await waitUntil(3) { !exists("docs.zip") }, "撤销压缩")
        send("redo:")
        check(await waitUntil(3) { exists("docs.zip") }, "重做压缩")
        await wait(0.5)

        // 双击压缩包 = 解压；已有 docs 时放到「docs 2」
        select("docs.zip")
        send("openSelection:")
        check(await waitUntil(5) { exists("docs 2/sub/b.txt") }, "打开压缩包即解压，重名时加编号")
        check(text("docs 2/a.txt") == "A", "解压内容正确")
        await wait(0.5)
        check(browser.selectedNames() == ["docs 2"], "解压后选中结果：\(browser.selectedNames())")

        // 多个项目 → 7z → 解压成同名文件夹
        select("docs", "x.txt")
        send("compress7z:")
        check(await waitUntil(5) { exists("归档.7z") }, "多个项目压缩为「归档.7z」")
        await wait(0.5)
        select("归档.7z")
        send("extractSelection:")
        check(await waitUntil(5) { exists("归档/docs/a.txt") && exists("归档/x.txt") }, "多个顶层项目解压到「归档」文件夹")

        // 加密：先输错，再输对
        await wait(0.5)
        select("enc.zip")
        send("extractSelection:")
        check(await answerPassword("wrong", expectRetry: false), "要求输入密码")
        check(await answerPassword("pw", expectRetry: true), "密码错误后再次询问")
        check(await waitUntil(5) { exists("secret.txt") }, "输对密码后解压")
        check(text("secret.txt") == "top secret", "加密内容正确")

        // 密码框点取消：什么也不留下
        await wait(0.5)
        select("enc.zip")
        send("extractSelection:")
        check(await answerPassword(nil, expectRetry: false), "再次解压时询问密码")
        await wait(0.8)
        check(!exists("secret 2.txt") && leftovers().isEmpty, "取消输入密码后没有残留")

        // 压缩到一半取消：进度条出现（双栏时也只有一份），取消后不留文件
        // 先单栏开始压缩，任务进行中再打开双栏：新加的那一栏也要让出底部
        let wasDual = controller.isDualPane
        controller.setDualPane(false)
        browser.focusList()
        await wait(0.3)
        select("big.bin")
        send("compressTarXz:")
        check(await waitUntil(3) { FileOperationCenter.shared.activeTransfers.count == 1 }, "压缩大文件时显示进度")
        // 进度条延迟出现，等胶囊真的显示了再切双栏
        check(await waitUntil(3) { controller.panesContainer.isOperationsBarVisible }, "进度胶囊出现")
        controller.setDualPane(true)
        await wait(0.5)
        let bars = SmokeScript.findViews(OperationsBar.self, in: window.contentView)
        let visibleBars = bars.filter { !$0.isHiddenOrHasHiddenAncestor }
        check(bars.count == 1 && visibleBars.count == 1 && controller.panesContainer.isOperationsBarVisible
              && controller.panes.allSatisfy { !visibleBars[0].isDescendant(of: $0.view) && $0.bottomOverlap > 0 },
              "双栏时进度条只有一份（共 \(bars.count) 个，可见 \(visibleBars.count) 个）：\(visibleBars.first?.displayedTitle ?? "")")
        let fraction = FileOperationCenter.shared.activeTransfers.first?.progress.fraction ?? 0
        check(fraction > 0 && fraction < 1, "进度在 0 和 1 之间：\(fraction)")
        FileOperationCenter.shared.activeTransfers.first?.cancel()
        check(await waitUntil(5) { FileOperationCenter.shared.activeTransfers.isEmpty }, "取消后任务结束")
        await wait(0.3)
        check(!exists("big.bin.tar.xz") && leftovers().isEmpty, "取消压缩后没有残留：\(leftovers())")
        check(await waitUntil(2) { !controller.panesContainer.isOperationsBarVisible && bars.allSatisfy(\.isHiddenOrHasHiddenAncestor)
                  && controller.panes.allSatisfy { $0.bottomOverlap == 0 } },
              "任务结束后进度条收起，列表的底部余量也撤掉")
        controller.setDualPane(wasDual)

        // 命令面板：拼音能找到压缩命令；没有选中项时不列出
        select("x.txt")
        send("showCommandPalette:")
        await wait(0.3)
        if let palette = QuickPanel.current {
            palette.query = "yasuo7z"
            check(palette.items.first?.title == "压缩为 7z", "命令面板拼音 yasuo7z → \(palette.items.first?.title ?? "无")")
            palette.query = "jy"
            check(!palette.items.contains { $0.title == "解压" }, "选中的不是压缩包时不列出「解压」")
            palette.close()
        } else {
            check(false, "命令面板没有打开")
        }

        SmokeScript.finish(nil)
    }

    private static func findSecureField(in view: NSView?) -> NSSecureTextField? {
        guard let view else { return nil }
        if let field = view as? NSSecureTextField { return field }
        for subview in view.subviews {
            if let found = findSecureField(in: subview) { return found }
        }
        return nil
    }

    private static func findLabels(in view: NSView) -> [String] {
        var result: [String] = []
        if let field = view as? NSTextField, !field.isEditable { result.append(field.stringValue) }
        for subview in view.subviews { result += findLabels(in: subview) }
        return result
    }
}
