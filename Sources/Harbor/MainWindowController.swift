import AppKit
import HarborCore

private extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let forward = Self("forward")
    static let dualPane = Self("dualPane")
    static let terminal = Self("terminal")
    static let search = Self("search")
}

/// 一个窗口（或一个标签页）= 边栏 + 工作区；工作区上面是一到两个浏览区，下面是可收起的终端。
/// 标签页用系统原生的窗口标签，每个标签是一个独立窗口。
/// 菜单动作都在这里接住再转给当前活动的浏览区，这样焦点在边栏时快捷键也能用。
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation, BrowserViewControllerDelegate {
    /// 所有打开的窗口和标签页；窗口关闭时移除
    private(set) static var all: [MainWindowController] = []

    /// 边栏 | 工作区
    private let splitController = NSSplitViewController()
    /// 浏览区（上）/ 终端（下）
    private let workspace = ChildSplitViewController()
    /// 第一栏 | 第二栏
    private let paneSplit = ChildSplitViewController()
    /// 包着 paneSplit，加一层悬浮的进度胶囊
    private(set) lazy var panesContainer = PanesContainerController(paneSplit: paneSplit)
    private let terminalPanel = TerminalPanelController()
    private let terminalItem: NSSplitViewItem
    let sidebar = SidebarViewController()
    private let primary: BrowserViewController
    private let primaryItem: NSSplitViewItem
    /// 双栏的第二栏。收起后保留实例，再次打开时回到原来的位置
    private var secondary: BrowserViewController?
    private var secondaryItem: NSSplitViewItem?
    /// 菜单动作、边栏、标题栏都跟着它走：最后获得焦点的那一栏
    private(set) var activeBrowser: BrowserViewController
    private var backItem: NSToolbarItem?
    private var forwardItem: NSToolbarItem?

    var isDualPane: Bool { secondaryItem != nil }
    var panes: [BrowserViewController] { isDualPane ? [primary, secondary!] : [primary] }
    private var otherBrowser: BrowserViewController? {
        guard isDualPane else { return nil }
        return activeBrowser === primary ? secondary : primary
    }

    init(url: URL) {
        primary = BrowserViewController(url: url)
        activeBrowser = primary
        primaryItem = NSSplitViewItem(viewController: primary)
        terminalItem = NSSplitViewItem(viewController: terminalPanel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.tabbingIdentifier = "HarborBrowser"
        window.isReleasedWhenClosed = false

        primary.delegate = self
        sidebar.onSelect = { [weak self] url in
            guard let self else { return }
            activeBrowser.navigate(to: url)
            activeBrowser.focusList()
        }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 320
        primaryItem.minimumThickness = 420
        paneSplit.addSplitViewItem(primaryItem)
        if Preferences.dualPane { setDualPane(true) } else { updateSplitAutosave() }

        workspace.splitView.isVertical = false
        let panesItem = NSSplitViewItem(viewController: panesContainer)
        panesItem.minimumThickness = 160
        terminalItem.canCollapse = true
        terminalItem.minimumThickness = 80
        // 拖窗口大小时终端保持高度，变化都给浏览区
        terminalItem.holdingPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 10)
        workspace.addSplitViewItem(panesItem)
        workspace.addSplitViewItem(terminalItem)
        // 不用 NSSplitView 的自动保存：它会在首次布局时恢复上次的展开状态，而终端进程不跨启动保留。
        // 终端高度自己存在 Preferences.terminalHeight，一律从收起开始
        terminalItem.isCollapsed = true
        terminalPanel.onDirectoryChange = { [weak self] url in self?.terminalDidChangeDirectory(url) }
        // 拖分隔条把终端拖没了：焦点不能留在看不见的终端里（列表相关的菜单都会被禁用）
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceDidResize),
                                               name: NSSplitView.didResizeSubviewsNotification, object: workspace.splitView)
        terminalPanel.onExit = { [weak self] in self?.terminalDidExit() }

        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(NSSplitViewItem(viewController: workspace))
        splitController.splitView.autosaveName = "MainSplit"

        window.contentViewController = splitController
        window.minSize = NSSize(width: 700, height: 360)
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        window.setContentSize(NSSize(width: 1100, height: 680))
        if let last = Self.all.last?.window {
            // 后开的窗口在前一个的基础上错开一点
            window.setFrame(last.frame, display: false)
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        } else {
            if !window.setFrameUsingName("MainWindow") { window.center() }
            window.setFrameAutosaveName("MainWindow")
        }
        if isDualPane, !hasSavedDualSplit { equalizePanes() }
        Self.all.append(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        terminalPanel.terminate()
        Self.all.removeAll { $0 === self }
    }

    /// 输入框都关了 allowsUndo，自己不处理 ⌘Z，会一路落到窗口上；给它们一个空的撤销管理器，
    /// 免得在地址栏、重命名框里按 ⌘Z 撤销掉上一次文件操作
    private let textUndoManager = UndoManager()

    /// 所有窗口共用文件操作的撤销历史
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        BrowserViewController.isTextInput(window.firstResponder) ? textUndoManager : FileOperationCenter.shared.undoManager
    }

    /// 焦点在边栏时，拷贝、粘贴、移到废纸篓等动作也交给活动的浏览区处理
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if activeBrowser.responds(to: action) { return activeBrowser }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    // MARK: - 双栏

    private func makeBrowser(url: URL) -> BrowserViewController {
        let browser = BrowserViewController(url: url)
        browser.delegate = self
        return browser
    }

    func setDualPane(_ on: Bool) {
        guard on != isDualPane else { return }
        // 双栏的宽度单独保存；增删分栏期间先停掉自动保存
        paneSplit.splitView.autosaveName = nil
        if on {
            let browser = secondary ?? makeBrowser(url: activeBrowser.currentURL)
            secondary = browser
            let item = NSSplitViewItem(viewController: browser)
            item.minimumThickness = 260
            primaryItem.minimumThickness = 260
            secondaryItem = item
            paneSplit.addSplitViewItem(item)
        } else if let item = secondaryItem {
            // 先把焦点交给第一栏，再拿掉第二栏
            if activeBrowser === secondary { activate(primary, focus: true) }
            paneSplit.removeSplitViewItem(item)
            secondaryItem = nil
            primaryItem.minimumThickness = 420
        }
        updateSplitAutosave()
        // 第一次用双栏、还没有保存过分栏宽度时，两栏等宽
        if on, !hasSavedDualSplit { equalizePanes() }
        updatePaneAppearance()
        panesContainer.updatePaneInsets()
    }

    private var hasSavedDualSplit: Bool {
        UserDefaults.standard.object(forKey: "NSSplitView Subview Frames PaneSplitDual") != nil
    }

    private func updateSplitAutosave() {
        paneSplit.splitView.autosaveName = isDualPane ? "PaneSplitDual" : nil
    }

    /// 两栏等宽
    private func equalizePanes() {
        let splitView = paneSplit.splitView
        splitView.layoutSubtreeIfNeeded()
        guard splitView.subviews.count == 2 else { return }
        splitView.setPosition(((splitView.bounds.width - splitView.dividerThickness) / 2).rounded(), ofDividerAt: 0)
    }

    // MARK: - 终端

    var isTerminalVisible: Bool { !terminalItem.isCollapsed }
    var isSidebarCollapsed: Bool { splitController.splitViewItems.first?.isCollapsed ?? false }
    var terminal: TerminalPanelController { terminalPanel }

    private var isTerminalFocused: Bool {
        guard let view = window?.firstResponder as? NSView, let terminalView = terminalPanel.terminalView else { return false }
        return view === terminalView || view.isDescendant(of: terminalView)
    }

    /// ⌃`：没显示就显示并聚焦；显示了但焦点不在终端就聚焦；焦点在终端就收起
    @objc func toggleTerminal(_ sender: Any?) {
        if !isTerminalVisible {
            showTerminal()
        } else if isTerminalFocused {
            hideTerminal()
        } else {
            window?.makeFirstResponder(terminalPanel.terminalView)
        }
    }

    /// 工具栏的搜索框（快速搜索文件）
    private(set) weak var searchItem: NSSearchToolbarItem?

    @objc func searchFieldChanged(_ sender: NSSearchField) {
        activeBrowser.search(sender.stringValue)
    }

    /// ⌘F
    @objc func focusSearch(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
    }

    /// 工具栏按钮：单纯的显示 / 收起（点按钮时焦点不在终端，⌃` 的「先聚焦」不适用）
    @objc private func terminalButtonClicked(_ sender: Any?) {
        if isTerminalVisible { hideTerminal() } else { showTerminal() }
    }

    private func showTerminal() {
        terminalItem.isCollapsed = false
        let splitView = workspace.splitView
        splitView.layoutSubtreeIfNeeded()
        let height = min(Preferences.terminalHeight, splitView.bounds.height - 160)
        splitView.setPosition(max(160, splitView.bounds.height - splitView.dividerThickness - height), ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        if !terminalPanel.isRunning {
            terminalPanel.start(in: activeBrowser.isVirtual ? FileManager.default.homeDirectoryForCurrentUser : activeBrowser.currentURL)
        }
        window?.makeFirstResponder(terminalPanel.terminalView)
    }

    private func hideTerminal() {
        let hadFocus = isTerminalFocused
        if terminalPanel.view.frame.height >= 80 { Preferences.terminalHeight = terminalPanel.view.frame.height }
        terminalItem.isCollapsed = true
        if hadFocus { activeBrowser.focusList() }
    }

    @objc private func workspaceDidResize(_ notification: Notification) {
        if terminalItem.isCollapsed, isTerminalFocused { activeBrowser.focusList() }
    }

    private func terminalDidChangeDirectory(_ url: URL) {
        guard activeBrowser.currentURL.pathKey != url.pathKey, AppDelegate.isDirectory(url) else { return }
        activeBrowser.navigate(to: url)
    }

    /// shell 退出（exit、⌃D）：收起终端，下次打开重新启动
    private func terminalDidExit() {
        if isTerminalVisible { hideTerminal() }
        if window?.firstResponder === window { activeBrowser.focusList() }
    }

    private func activate(_ browser: BrowserViewController, focus: Bool) {
        if browser !== activeBrowser {
            activeBrowser = browser
            updatePaneAppearance()
            updateForActiveBrowser()
        }
        if focus { browser.focusList() }
    }

    private func updatePaneAppearance() {
        for pane in [primary, secondary].compactMap({ $0 }) {
            pane.isActivePane = !isDualPane || pane === activeBrowser
        }
    }

    private func updateForActiveBrowser() {
        let url = activeBrowser.currentURL
        sidebar.reveal(url)
        // 搜索框跟着当前位置：在搜索结果里显示搜的文字，离开搜索就清空
        if let field = searchItem?.searchField {
            var text = ""
            if case .search(let searching, _) = VirtualLocation(url: url) { text = searching }
            if field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != text { field.stringValue = text }
        }
        if let location = VirtualLocation(url: url) {
            // 主页、分类没有对应的目录：标题用名称，终端不跟着跳
            window?.title = location.title
            window?.representedURL = nil
        } else {
            window?.title = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
            window?.representedURL = url
            terminalPanel.sync(to: url)
        }
        backItem?.isEnabled = activeBrowser.history.canGoBack
        forwardItem?.isEnabled = activeBrowser.history.canGoForward
    }

    // MARK: - 标签页

    /// 在本窗口的标签组里开一个新标签。select 为 false 时留在当前标签
    @discardableResult
    func openTab(_ url: URL, select: Bool, after anchor: NSWindow? = nil) -> MainWindowController {
        let controller = MainWindowController(url: url)
        guard let window, let newWindow = controller.window else { return controller }
        (anchor ?? window).addTabbedWindow(newWindow, ordered: .above)
        if select {
            newWindow.makeKeyAndOrderFront(nil)
        } else {
            window.tabGroup?.selectedWindow = window
        }
        return controller
    }

    /// 按顺序排在当前标签后面，焦点留在当前标签
    func openTabs(_ urls: [URL]) {
        var anchor = window
        for url in urls {
            anchor = openTab(url, select: false, after: anchor).window
        }
    }

    // MARK: - BrowserViewControllerDelegate

    func browserDidNavigate(_ browser: BrowserViewController) {
        if browser === activeBrowser { updateForActiveBrowser() }
    }

    func browserDidBecomeActive(_ browser: BrowserViewController) {
        activate(browser, focus: false)
    }

    func browserRequestsPaneSwitch(_ browser: BrowserViewController) -> Bool {
        guard let other = otherBrowser else { return false }
        activate(other, focus: true)
        return true
    }

    func browser(_ browser: BrowserViewController, openInNewTabs urls: [URL]) {
        openTabs(urls)
    }

    // MARK: - 动作

    @objc func goBack(_ sender: Any?) { activeBrowser.goBack() }
    @objc func goForward(_ sender: Any?) { activeBrowser.goForward() }
    @objc func goUp(_ sender: Any?) { activeBrowser.goUp() }
    @objc func openSelection(_ sender: Any?) { activeBrowser.openSelection() }
    @objc func refresh(_ sender: Any?) { activeBrowser.refresh() }
    @objc func editPath(_ sender: Any?) { activeBrowser.beginEditingPath() }
    @objc func toggleHiddenFiles(_ sender: Any?) {
        let show = !activeBrowser.showHidden
        // 收起的第二栏也要同步，再打开时才一致
        [primary, secondary].compactMap { $0 }.forEach { $0.showHidden = show }
    }

    @objc func goHome(_ sender: Any?) { go(FileManager.default.homeDirectoryForCurrentUser) }
    @objc func goHomePage(_ sender: Any?) { go(VirtualLocation.home.url) }
    @objc func goDesktop(_ sender: Any?) { go(.desktopDirectory) }
    @objc func goDocuments(_ sender: Any?) { go(.documentsDirectory) }
    @objc func goDownloads(_ sender: Any?) { go(.downloadsDirectory) }
    @objc func goApplications(_ sender: Any?) { go(.applicationDirectory) }

    private func go(_ url: URL) {
        activeBrowser.navigate(to: url)
        activeBrowser.focusList()
    }

    @objc func newWindow(_ sender: Any?) {
        MainWindowController(url: activeBrowser.currentURL).showWindow(nil)
    }

    /// ⌘T，以及标签栏上的 + 按钮
    override func newWindowForTab(_ sender: Any?) {
        openTab(activeBrowser.currentURL, select: true)
    }

    @objc func toggleDualPane(_ sender: Any?) {
        setDualPane(!isDualPane)
        Preferences.dualPane = isDualPane
    }

    @objc func switchPane(_ sender: Any?) {
        _ = browserRequestsPaneSwitch(activeBrowser)
    }

    @objc func copyToOtherPane(_ sender: Any?) { transferToOtherPane(.copy) }
    @objc func moveToOtherPane(_ sender: Any?) { transferToOtherPane(.move) }

    private func transferToOtherPane(_ mode: TransferMode) {
        guard let other = otherBrowser else { return }
        let destination = other.currentURL
        activeBrowser.startTransfer(mode, activeBrowser.selectedURLs, to: destination) { [weak other] results in
            // 另一栏还停在目标目录时，选中新出现的项目
            guard let other, other.currentURL.pathKey == destination.pathKey else { return }
            other.reload(selecting: results.map(\.lastPathComponent), isNavigation: false)
        }
    }

    @objc func showCommandPalette(_ sender: Any?) {
        guard let window else { return }
        CommandPalette.show(in: window)
    }

    @objc func quickJump(_ sender: Any?) {
        QuickJump.show(for: self)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // 输入文字时，⌘↑ ⌘↓ ⌘[ ⌘]、F5 F6 不要作用到列表上
        if activeBrowser.isEditingText {
            switch menuItem.action {
            case #selector(goBack(_:)), #selector(goForward(_:)), #selector(goUp(_:)), #selector(openSelection(_:)),
                 #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)):
                return false
            default:
                break
            }
        }
        switch menuItem.action {
        case #selector(goBack(_:)): return activeBrowser.history.canGoBack
        case #selector(goForward(_:)): return activeBrowser.history.canGoForward
        case #selector(goUp(_:)): return activeBrowser.canGoUp
        case #selector(openSelection(_:)): return activeBrowser.hasSelection
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = activeBrowser.showHidden ? .on : .off
            return true
        case #selector(toggleDualPane(_:)):
            menuItem.state = isDualPane ? .on : .off
            return true
        case #selector(switchPane(_:)):
            return isDualPane
        case #selector(toggleTerminal(_:)):
            menuItem.state = isTerminalVisible ? .on : .off
            return true
        case #selector(copyToOtherPane(_:)):
            return isDualPane && activeBrowser.hasSelection && otherBrowser?.isVirtual == false
        case #selector(moveToOtherPane(_:)):
            return isDualPane && activeBrowser.hasSelection && otherBrowser?.isVirtual == false
                && otherBrowser?.currentURL.pathKey != activeBrowser.currentURL.pathKey
        default: return true
        }
    }

    // MARK: - 工具栏

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .forward, .flexibleSpace, .dualPane, .terminal, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .back:
            let item = navigationItem(identifier, symbol: "chevron.left", label: "后退", action: #selector(goBack(_:)))
            backItem = item
            item.isEnabled = activeBrowser.history.canGoBack
            return item
        case .forward:
            let item = navigationItem(identifier, symbol: "chevron.right", label: "前进", action: #selector(goForward(_:)))
            forwardItem = item
            item.isEnabled = activeBrowser.history.canGoForward
            return item
        case .dualPane:
            return actionItem(identifier, symbol: "rectangle.split.2x1", label: "双栏", action: #selector(toggleDualPane(_:)))
        case .terminal:
            return actionItem(identifier, symbol: "apple.terminal", label: "终端", action: #selector(terminalButtonClicked(_:)))
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.label = "搜索"
            item.searchField.placeholderString = "搜索文件名"
            // 输入停顿一下再搜（系统默认的节奏），不是每个字都搜
            item.searchField.sendsSearchStringImmediately = false
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldChanged(_:))
            searchItem = item
            return item
        default:
            return nil
        }
    }

    private func actionItem(_ identifier: NSToolbarItem.Identifier, symbol: String, label: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    private func navigationItem(_ identifier: NSToolbarItem.Identifier, symbol: String, label: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.isNavigational = true
        item.isBordered = true
        item.target = self
        item.action = action
        // 启用状态在 updateForActiveBrowser 里手动更新
        item.autovalidates = false
        return item
    }
}

/// 嵌在里面的分栏控制器。NSSplitViewController 都响应「显示/隐藏边栏」，
/// 里层的不让出来的话，焦点在浏览区时这个动作会落到没有边栏的里层控制器上，什么也不做
final class ChildSplitViewController: NSSplitViewController {
    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(toggleSidebar(_:)) || selector == #selector(toggleInspector(_:)) { return false }
        return super.responds(to: selector)
    }
}
