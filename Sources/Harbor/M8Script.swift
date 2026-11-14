import AppKit
import HarborCore

/// HARBOR_SCRIPT=m8：图标视图、主页、分类、智能分类、标签、边栏分组。
/// 启动目录里要有 a.txt、b.txt、folder/、pic.png。分类查询用你主目录里真实的文件（只读）
@MainActor
enum M8Script {
    static func run() async {
        try? await Task.sleep(for: .seconds(1))
        guard let controller = MainWindowController.all.first, let window = controller.window else {
            return SmokeScript.finish("找不到窗口")
        }
        window.makeKeyAndOrderFront(nil)
        let browser = controller.activeBrowser
        let root = browser.currentURL
        let fm = FileManager.default
        func check(_ condition: Bool, _ label: String) { SmokeScript.check(condition, label) }
        func exists(_ relative: String) -> Bool { fm.fileExists(atPath: root.appending(path: relative).path) }
        func wait(_ seconds: Double = 0.6) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
            while ContinuousClock.now < deadline {
                if condition() { return true }
                await wait(0.1)
            }
            return condition()
        }
        func index(_ name: String) -> Int? { browser.items.firstIndex { $0.name == name } }
        /// HARBOR_SNAPSHOT_DIR 设了就截图，方便看布局
        func snapshot(_ name: String) {
            guard let dir = ProcessInfo.processInfo.environment["HARBOR_SNAPSHOT_DIR"] else { return }
            DebugHooks.snapshot(window, to: dir + "/m8-\(name).png")
        }
        func validates(_ action: Selector) -> Bool {
            browser.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }
        // 桌面、文稿、下载要用户点授权，脚本里没人点，跳过这三个目录
        SpotlightSearch.excludesProtectedFolders = true
        // 测试会动到的偏好，结束时恢复
        let originalMode = Preferences.viewMode
        let hadQuickAccess = UserDefaults.standard.object(forKey: "quickAccess") != nil
        let categoriesFile = URL.applicationSupportDirectory.appending(path: "Harbor/smart-categories.json")
        let hadCategoriesFile = fm.fileExists(atPath: categoriesFile.path)
        defer {
            Preferences.viewMode = originalMode
            if !hadQuickAccess { UserDefaults.standard.removeObject(forKey: "quickAccess") }
            if !hadCategoriesFile { try? fm.removeItem(at: categoriesFile) }
        }

        // MARK: 图标视图
        Preferences.viewMode = .list
        await wait(0.3)
        Preferences.viewMode = .icons
        await wait(0.5)
        check(!browser.gridScroll.isHidden && browser.view.window != nil && browser.gridView.numberOfItems(inSection: 0) == browser.items.count,
              "⌘1 切到图标视图：\(browser.gridView.numberOfItems(inSection: 0)) / \(browser.items.count) 项")
        if let pic = browser.items.first(where: { $0.name == "pic.png" }) {
            let url = pic.url(in: root)
            check(await waitUntil(8) { ThumbnailProvider.shared.cached(for: url, modified: pic.modified, size: NSSize(width: 64, height: 64)) != nil },
                  "图片显示缩略图")
            snapshot("icons")
        } else {
            check(false, "启动目录里没有 pic.png")
        }
        browser.gridView.selectAll(nil)
        check(browser.tableView.selectedRowIndexes.count == browser.items.count, "网格里 ⌘A 全选同步到列表")
        browser.gridView.deselectAll(nil)
        check(browser.tableView.selectedRowIndexes.isEmpty, "网格里取消全选同步到列表")
        if let a = index("a.txt") {
            browser.gridView.selectionIndexPaths = [IndexPath(item: a, section: 0)]
            browser.collectionView(browser.gridView, didSelectItemsAt: [IndexPath(item: a, section: 0)])
            check(browser.selectedNames() == ["a.txt"], "网格里选中同步到列表：\(browser.selectedNames())")
        }
        if let b = index("b.txt") {
            browser.tableView.selectRowIndexes([b], byExtendingSelection: false)
            check(browser.gridView.selectionIndexPaths == [IndexPath(item: b, section: 0)], "列表选中同步到网格")
            browser.focusList()
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            browser.gridView.keyDown(with: enter)
            await wait(0.3)
            let field = (browser.gridView.item(at: IndexPath(item: b, section: 0)) as? FileGridItem)?.nameField
            check(field != nil && browser.renamingField === field, "网格里回车开始重命名")
            field?.stringValue = "b2.txt"
            browser.focusList()
            check(await waitUntil(3) { exists("b2.txt") && !exists("b.txt") }, "网格里重命名")
        }
        if let folder = index("folder") {
            let menu = NSMenu()
            browser.tableView.selectRowIndexes([folder], byExtendingSelection: false)
            browser.populateContextMenu(menu, row: folder)
            check(menu.items.contains { $0.title == "添加至快速访问" }, "文件夹右键有「添加至快速访问」")
            browser.gridView.onDoubleClick?(folder)
            check(await waitUntil(3) { browser.currentURL.pathKey == root.appending(path: "folder").pathKey }, "网格里双击进入文件夹")
            browser.navigate(to: root)
            await wait()
        }
        Preferences.viewMode = .list
        await wait(0.3)
        check(browser.gridScroll.isHidden && !browser.tableView.enclosingScrollView!.isHidden, "⌘2 切回列表")

        // MARK: 主页
        browser.navigate(to: VirtualLocation.home.url)
        let home = browser.virtualContent as? HomeViewController
        check(browser.isVirtual && home != nil && window.title == "主页" && !browser.canGoUp, "打开主页")
        check((home?.cards.count ?? 0) == SmartQuery.Kind.allCases.count + SmartCategoryStore.shared.categories.count + 1,
              "主页分类卡片：\(home?.cards.map(\.title) ?? [])")
        check(!validates(#selector(BrowserViewController.newFolder(_:))) && !validates(#selector(BrowserViewController.paste(_:))),
              "主页上新建文件夹、粘贴不可用")
        check(await waitUntil(15) { home?.recent.isFinished == true }, "主页「最近」查询完成：\(home?.recent.results.count ?? -1) 项")
        check(await waitUntil(15) { home?.cards.first?.detail.hasSuffix("项") == true }, "卡片显示数量：\(home?.cards.first?.detail ?? "")")
        await wait(0.5)
        snapshot("home")

        let tab = controller.openTab(VirtualLocation.home.url, select: false)
        await wait()
        check(tab.activeBrowser.isVirtual && tab.activeBrowser.virtualContent is HomeViewController, "主页可以在新标签页打开")
        tab.window?.close()
        await wait(0.3)

        // MARK: 分类（真实的 Spotlight 查询）
        browser.navigate(to: VirtualLocation.category(.image).url)
        let images = browser.virtualContent as? QueryResultsViewController
        check(await waitUntil(30) { images?.isFinished == true }, "图片分类查询完成")
        let imageResults = images?.results ?? []
        snapshot("images")
        let library = fm.homeDirectoryForCurrentUser.appending(path: "Library").path + "/"
        check(!imageResults.isEmpty, "图片分类有结果：\(imageResults.count) 项")
        check(imageResults.allSatisfy { SpotlightFilter.isBrowsable($0.url.path) && !$0.url.path.hasPrefix(library) },
              "结果里没有隐藏目录、node_modules、~/Library、包内部的文件")
        if let first = imageResults.first {
            images?.tableView.selectRowIndexes([0], byExtendingSelection: false)
            images?.revealInFolder(nil)
            check(await waitUntil(3) { !browser.isVirtual && browser.selectedNames() == [first.name] }, "在所在文件夹中显示：\(first.name)")
            browser.goBack()
            await wait()
        }

        // MARK: 智能分类
        let category = SmartCategory(name: "测试图片", query: .category(.image), autoUpdate: false)
        SmartCategoryStore.shared.save(category)
        browser.navigate(to: VirtualLocation.smart(category.id).url)
        let smart = browser.virtualContent as? QueryResultsViewController
        check(await waitUntil(30) { smart?.isFinished == true } && smart?.results.count == imageResults.count,
              "智能分类（图片、不限时间）和图片分类结果一致：\(smart?.results.count ?? -1) / \(imageResults.count)")
        QuickAccessStore.shared.add(VirtualLocation.smart(category.id).url)
        await wait(0.3)
        check(sidebarTitles(controller.sidebar).contains("测试图片"), "智能分类固定到快速访问")
        var renamed = category
        renamed.name = "测试图片2"
        SmartCategoryStore.shared.save(renamed)
        await wait(0.5)
        check(window.title == "测试图片2" && sidebarTitles(controller.sidebar).contains("测试图片2"), "改名后标题和边栏跟着变")
        SmartCategoryStore.shared.remove(category.id)
        await wait(0.3)
        check(!QuickAccessStore.shared.contains(VirtualLocation.smart(category.id).url) && !sidebarTitles(controller.sidebar).contains("测试图片2"),
              "删除智能分类后从快速访问移除")
        check(SmartCategoryEditor.Form.automaticName(for: SmartQuery(keyword: "报告", kinds: [.document], range: .week)) == "近 7 天修改的名称含“报告”的文档",
              "智能分类自动命名")

        // MARK: 标签
        if let tag = NSWorkspace.shared.fileLabels.dropFirst().first {
            browser.navigate(to: VirtualLocation.tag(tag).url)
            let tagged = browser.virtualContent as? QueryResultsViewController
            check(await waitUntil(15) { tagged?.isFinished == true } && window.title == tag, "标签「\(tag)」查询完成：\(tagged?.results.count ?? -1) 项")
        }

        // MARK: 边栏
        let sidebar = controller.sidebar
        let firstRow = sidebar.outlineView.item(atRow: 0) as? SidebarViewController.Item
        check(firstRow?.title == "主页" && sidebar.sections.map(\.title) == ["快速访问", "存储位置", "标签"],
              "边栏分组：主页 / \(sidebar.sections.map(\.title))")
        QuickAccessStore.shared.add(root.appending(path: "folder", directoryHint: .isDirectory))
        await wait(0.3)
        check(sidebarTitles(sidebar).contains("folder"), "文件夹添加到快速访问")
        QuickAccessStore.shared.remove(root.appending(path: "folder", directoryHint: .isDirectory))
        await wait(0.3)
        check(!sidebarTitles(sidebar).contains("folder"), "从快速访问移除")
        if let volume = sidebar.sections.first(where: { $0.title == "存储位置" })?.items.first {
            sidebar.outlineView.expandItem(volume)
            check(sidebar.outlineView.isItemExpanded(volume) && !volume.children.isEmpty, "存储位置展开：\(volume.title) 下 \(volume.children.count) 个文件夹")
            sidebar.outlineView.collapseItem(volume)
        }

        // MARK: 回到真实目录
        browser.navigate(to: root)
        await wait()
        check(!browser.isVirtual && browser.virtualContent == nil && !browser.tableView.enclosingScrollView!.isHidden && index("a.txt") != nil,
              "从虚拟位置回到文件夹")
        fm.createFile(atPath: root.appending(path: "new.txt").path, contents: Data())
        check(await waitUntil(4) { index("new.txt") != nil }, "回到文件夹后目录监听照常工作")

        SmokeScript.finish(nil)
    }

    /// 边栏里当前显示的所有项目名称（展开的部分）
    private static func sidebarTitles(_ sidebar: SidebarViewController) -> [String] {
        (0..<sidebar.outlineView.numberOfRows).compactMap { (sidebar.outlineView.item(atRow: $0) as? SidebarViewController.Item)?.title }
    }
}
