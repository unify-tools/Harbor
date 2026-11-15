import AppKit
import HarborCore

@MainActor
protocol BrowserViewControllerDelegate: AnyObject {
    func browserDidNavigate(_ browser: BrowserViewController)
    /// 列表或地址栏获得焦点：双栏时成为活动的一栏
    func browserDidBecomeActive(_ browser: BrowserViewController)
    /// 列表里按 Tab：切到另一栏。返回 false 表示没有另一栏
    func browserRequestsPaneSwitch(_ browser: BrowserViewController) -> Bool
    /// 多选打开、⌘双击时，文件夹在新标签页打开
    func browser(_ browser: BrowserViewController, openInNewTabs urls: [URL])
}

/// 浏览区：地址栏 + 文件列表 + 状态栏。
/// 读目录和排序都在后台做，主线程只负责把结果交给表格。
@MainActor
final class BrowserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Column: String, CaseIterable {
        case name, modified, size, kind
    }

    private enum LoadOutcome: Sendable {
        case success([FileItem])
        case failure(DirectoryReadError)
    }

    weak var delegate: BrowserViewControllerDelegate?

    private(set) var currentURL: URL
    private(set) var history = NavigationHistory()

    var showHidden = Preferences.showHidden {
        didSet {
            Preferences.showHidden = showHidden
            reload(selecting: nil, isNavigation: false)
        }
    }

    /// 双栏时非活动的一栏把地址栏和状态栏调暗
    var isActivePane = true {
        didSet {
            pathBar.alphaValue = isActivePane ? 1 : 0.5
            statusBar.alphaValue = isActivePane ? 1 : 0.5
        }
    }

    var canGoUp: Bool { !isVirtual && currentURL.pathKey != "/" }

    /// 主页、分类、标签、智能分类（harbor:// 地址）：内容换成主页或搜索结果，文件操作不可用
    private(set) var virtualLocation: VirtualLocation?
    var isVirtual: Bool { virtualLocation != nil }
    /// 虚拟位置的内容：HomeViewController 或 QueryResultsViewController
    private(set) var virtualContent: NSViewController?
    var virtualResults: QueryResultsViewController? {
        (virtualContent as? QueryResultsViewController) ?? (virtualContent as? HomeViewController)?.recent
    }

    /// 列表 / 图标，所有窗口共用一个设置
    private(set) var viewMode = Preferences.viewMode
    let gridView = FileGridView()
    let gridScroll = NSScrollView()
    /// 网格和列表互相同步选中状态时，避免来回触发
    var isSyncingSelection = false
    var hasSelection: Bool { !tableView.selectedRowIndexes.isEmpty }

    private(set) var items: [FileItem] = []
    private var sortOrder = Preferences.sortOrder
    private var watcher: DirectoryWatcher?
    /// 每次加载加一，过期的后台结果直接丢弃
    private var generation = 0
    private var isLoading = false
    /// 加载期间目录又变了：本次结束后再刷一次
    var refreshPending = false
    private var freeSpace: Int64?

    /// 正在行内重命名的项目。重命名期间暂缓刷新，否则 reloadData 会打断编辑。
    var renamingItem: FileItem?
    weak var renamingField: NSTextField?
    /// 新建文件夹后，等它出现在列表里再开始重命名
    var pendingRenameName: String?

    private let pathBar = PathBarView()
    private let scrollView = NSScrollView()
    let tableView = FileTableView()
    private let statusBar = StatusBarView()
    static let statusBarHeight: CGFloat = 24

    /// 列表底部被悬浮的进度胶囊盖住的高度。留出等量的滚动余量，最后几行能滚到胶囊上面
    var bottomOverlap: CGFloat = 0 {
        didSet {
            guard bottomOverlap != oldValue else { return }
            for scroll in [scrollView, gridScroll] {
                scroll.automaticallyAdjustsContentInsets = false
                scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomOverlap, right: 0)
            }
        }
    }
    private let placeholder = PlaceholderView()

    init(url: URL) {
        currentURL = url.standardizedFileURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 视图

    override func loadView() {
        let root = NSView()
        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        configureGrid()

        pathBar.onNavigate = { [weak self] url in self?.navigate(to: url) }
        pathBar.onSubmit = { [weak self] text in self?.submitPath(text) ?? false }
        pathBar.completer = { [weak self] text in
            guard let self else { return nil }
            return PathInput.complete(text, relativeTo: directoryForInput, showHidden: showHidden)
        }
        pathBar.onEndEditing = { [weak self] in self?.focusList() }
        pathBar.onBeginEditing = { [weak self] in
            guard let self else { return }
            delegate?.browserDidBecomeActive(self)
        }
        pathBar.onCopyPath = { [weak self] in self?.copyCurrentPath(nil) }

        placeholder.isHidden = true
        for subview in [pathBar, scrollView, gridScroll, statusBar, placeholder] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: 32),

            scrollView.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            gridScroll.topAnchor.constraint(equalTo: scrollView.topAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Self.statusBarHeight),

            placeholder.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyViewMode()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(viewModeDidChange), name: Preferences.viewModeDidChange, object: nil)
        center.addObserver(self, selector: #selector(smartCategoriesDidChange), name: SmartCategoryStore.didChange, object: nil)
        navigate(to: currentURL)
    }

    @objc private func viewModeDidChange() {
        guard viewMode != Preferences.viewMode else { return }
        let hadFocus = view.window?.firstResponder === tableView || view.window?.firstResponder === gridView
        viewMode = Preferences.viewMode
        applyViewMode()
        if hadFocus { focusList() }
    }

    /// 正在看的智能分类改了条件或名称：重新查询
    @objc private func smartCategoriesDidChange() {
        guard case .smart = virtualLocation else { return }
        navigate(to: currentURL, recordHistory: false)
    }

    private func applyViewMode() {
        let icons = viewMode == .icons
        scrollView.isHidden = isVirtual || icons
        gridScroll.isHidden = isVirtual || !icons
        if icons {
            gridView.reloadData()
            syncGridFromTable(scroll: true)
        }
    }

    /// 地址栏补全、输入相对路径时的基准目录
    private var directoryForInput: URL {
        isVirtual ? FileManager.default.homeDirectoryForCurrentUser : currentURL
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // 只在窗口里还没有焦点时抢焦点；打开双栏时新出现的第二栏不抢第一栏的焦点
        if let window = view.window, window.firstResponder === window { focusList() }
        // 撤销 / 重做出错时由最近显示的窗口提示
        FileOperationCenter.shared.errorPresenter = { [weak self] errors, title in
            self?.presentErrors(errors, title: title)
        }
    }

    private func configureTable() {
        let titles: [Column: (String, CGFloat, CGFloat)] = [
            .name: ("名称", 340, 120),
            .modified: ("修改日期", 170, 80),
            .size: ("大小", 90, 50),
            .kind: ("种类", 150, 60),
        ]
        for column in Column.allCases {
            let (title, width, minWidth) = titles[column]!
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = title
            tableColumn.width = width
            tableColumn.minWidth = minWidth
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            if column == .size { tableColumn.headerCell.alignment = .right }
            tableView.addTableColumn(tableColumn)
        }
        tableView.style = .fullWidth
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.autosaveName = "FileList"
        tableView.autosaveTableColumns = true
        // 先设排序再接 delegate，避免触发 sortDescriptorsDidChange
        tableView.sortDescriptors = [NSSortDescriptor(key: sortOrder.key.rawValue, ascending: sortOrder.ascending)]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClicked(_:))
        tableView.onReturn = { [weak self] in self?.beginRename() }
        tableView.onSpace = { [weak self] in self?.toggleQuickLook(nil) }
        tableView.onFocus = { [weak self] in
            guard let self else { return }
            delegate?.browserDidBecomeActive(self)
        }
        tableView.onTab = { [weak self] in
            guard let self else { return false }
            return delegate?.browserRequestsPaneSwitch(self) ?? false
        }
        configureFileOperations()
    }

    private var lastLayoutWidth: CGFloat = 0

    /// 栏宽变化时（拖窗口、开关双栏）重新收窄名称列；只看宽度变化，不干涉用户手动拉宽列
    override func viewDidLayout() {
        super.viewDidLayout()
        guard view.bounds.width != lastLayoutWidth else { return }
        lastLayoutWidth = view.bounds.width
        fitColumnsToWidth()
    }

    /// 表格比可见区域宽时，收窄名称列让所有列都能看到（不小于名称列的最小宽度）
    func fitColumnsToWidth() {
        let visible = scrollView.contentView.bounds.width
        guard tableView.frame.width > visible + 1,
              let name = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(Column.name.rawValue)) else { return }
        let columns = tableView.tableColumns
        let others = columns.filter { $0 !== name }.reduce(0) { $0 + $1.width }
        let spacing = tableView.intercellSpacing.width * CGFloat(columns.count)
        name.width = max(name.minWidth, visible - others - spacing)
        tableView.sizeToFit()
    }

    func focusList() {
        if isVirtual {
            virtualResults?.focus()
        } else {
            view.window?.makeFirstResponder(viewMode == .icons ? gridView : tableView)
        }
    }

    // MARK: - 导航

    func navigate(to url: URL, selecting names: [String] = [], recordHistory: Bool = true) {
        let target = url.isVirtualLocation ? url : url.standardizedFileURL
        let previous = currentURL
        if recordHistory { history.visit(target) }
        currentURL = target
        if let location = VirtualLocation(url: target) {
            showVirtual(location)
            delegate?.browserDidNavigate(self)
            return
        }
        if isVirtual { hideVirtual() }

        // 回到上层（返回、上一级）时选中刚才所在的文件夹
        var selection = names
        if selection.isEmpty, previous.pathKey != target.pathKey, previous.deletingLastPathComponent().pathKey == target.pathKey {
            selection = [previous.lastPathComponent]
        }

        Preferences.lastDirectory = target
        RecentPlaces.shared.record(target)
        pathBar.url = target
        watcher = DirectoryWatcher(url: target) { [weak self] in
            Task { @MainActor in self?.directoryDidChange() }
        }
        reload(selecting: selection, isNavigation: true)
        updateFreeSpace()
        delegate?.browserDidNavigate(self)
    }

    func goBack() {
        guard let url = history.goBack() else { return }
        navigate(to: url, recordHistory: false)
    }

    func goForward() {
        guard let url = history.goForward() else { return }
        navigate(to: url, recordHistory: false)
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: currentURL.deletingLastPathComponent())
    }

    func refresh() {
        if isVirtual {
            navigate(to: currentURL, recordHistory: false)
        } else {
            reload(selecting: nil, isNavigation: false)
        }
    }

    // MARK: - 快速搜索

    /// 工具栏搜索框：在当前文件夹（含子文件夹）里按文件名搜；在主页、分类里搜就搜所有位置。
    /// 连续输入只替换当前这条搜索，不留一串历史；清空回到搜索前的位置
    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .search(_, let scope) = virtualLocation {
            if trimmed.isEmpty {
                goBack()
            } else {
                navigate(to: VirtualLocation.search(trimmed, scope: scope).url, recordHistory: false)
            }
        } else if !trimmed.isEmpty {
            navigate(to: VirtualLocation.search(trimmed, scope: isVirtual ? nil : currentURL).url)
        }
    }

    // MARK: - 虚拟位置

    private func showVirtual(_ location: VirtualLocation) {
        removeVirtualContent()
        virtualLocation = location
        watcher = nil
        generation += 1
        isLoading = false
        items = []
        tableView.reloadData()
        gridView.reloadData()
        placeholder.hide()
        pathBar.showVirtual(title: location.title, symbol: location.symbol)
        scrollView.isHidden = true
        gridScroll.isHidden = true
        statusBar.set(left: "", right: "")

        let onCount: (Int, Bool) -> Void = { [weak self] count, finished in self?.updateVirtualStatus(count: count, finished: finished) }
        let controller: NSViewController
        if case .home = location {
            let home = HomeViewController()
            home.owner = self
            home.onCountChange = onCount
            controller = home
        } else if case .search(let text, let scope) = location {
            let search = SpotlightSearch(queryString: SmartQuery.nameSearchString(text), scopes: scope.map { [$0] }, live: true)
            let results = QueryResultsViewController(owning: search)
            if scope != nil {
                results.emptyAction = ("在所有位置中搜索", { [weak self] in
                    self?.navigate(to: VirtualLocation.search(text, scope: nil).url, recordHistory: false)
                })
            }
            results.owner = self
            results.onCountChange = onCount
            controller = results
        } else if let (query, live) = location.query {
            // 实时更新的用共享的常驻查询，再次进来不用重新搜
            let results = live ? QueryResultsViewController(shared: SpotlightCache.shared.search(query))
                               : QueryResultsViewController(query, live: false)
            results.owner = self
            results.onCountChange = onCount
            controller = results
        } else {
            placeholder.show(symbol: "questionmark.folder", message: "这个智能分类已经删除")
            return
        }
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view, positioned: .below, relativeTo: placeholder)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])
        virtualContent = controller
    }

    private func hideVirtual() {
        removeVirtualContent()
        virtualLocation = nil
        applyViewMode()
    }

    private func removeVirtualContent() {
        (virtualContent as? HomeViewController)?.stop()
        (virtualContent as? QueryResultsViewController)?.stop()
        virtualContent?.view.removeFromSuperview()
        virtualContent?.removeFromParent()
        virtualContent = nil
    }

    private func updateVirtualStatus(count: Int, finished: Bool) {
        let selected = virtualResults?.selectedCount ?? 0
        var text = selected > 0 ? "已选择 \(selected) 项，共 \(count) 项" : "\(count) 项"
        // 先显示的是上次的快照时写「正在更新」，还什么都没有时写「正在查找」
        if !finished { text = (count > 0 ? "正在更新… " : "正在查找… ") + text }
        statusBar.set(left: text, right: "")
    }

    func beginEditingPath() {
        pathBar.beginEditing()
    }

    /// 地址栏回车：目录就进入，文件就进入所在目录并选中它
    private func submitPath(_ text: String) -> Bool {
        guard let url = PathInput.resolve(text, relativeTo: directoryForInput) else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) else { return false }
        if isDir.boolValue, !FileTypes.isPackageExtension(url.pathExtension) {
            navigate(to: url)
        } else {
            navigate(to: url.deletingLastPathComponent(), selecting: [url.lastPathComponent])
        }
        return true
    }

    // MARK: - 打开

    func openSelection() {
        if isVirtual {
            virtualResults?.openSelection()
        } else {
            open(rows: tableView.selectedRowIndexes)
        }
    }

    @objc private func openClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        // ⌘双击：文件夹在新标签页打开
        let inNewTabs = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        open(rows: tableView.selectedRowIndexes.contains(row) ? tableView.selectedRowIndexes : [row], foldersInNewTabs: inNewTabs)
    }

    /// 单个文件夹就进入；多选时文件夹各开一个新标签页，文件用默认应用打开
    func open(rows: IndexSet, foldersInNewTabs: Bool = false) {
        let selected = rows.compactMap { $0 < items.count ? items[$0] : nil }
        guard !selected.isEmpty else { return }
        if selected.count == 1, !foldersInNewTabs, let folder = folderTarget(for: selected[0]) {
            navigate(to: folder)
            return
        }
        let folders = selected.compactMap(folderTarget(for:))
        if !folders.isEmpty { delegate?.browser(self, openInNewTabs: folders) }
        // 压缩包和 Finder（归档实用工具）一样，打开就是解压到当前文件夹
        var archives: [URL] = []
        for item in selected where folderTarget(for: item) == nil {
            let url = item.url(in: currentURL)
            if item.kind == .file, Archives.isExtractable(url) {
                archives.append(url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        extract(archives)
    }

    /// 双击后应该进入的目录：普通文件夹，或者指向文件夹的符号链接
    func folderTarget(for item: FileItem) -> URL? {
        let url = item.url(in: currentURL)
        if item.isFolder { return url }
        guard item.kind == .symlink else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        guard AppDelegate.isDirectory(resolved), !FileTypes.isPackageExtension(resolved.pathExtension) else { return nil }
        return resolved
    }

    // MARK: - 加载

    private func directoryDidChange() {
        if isLoading || renamingItem != nil {
            refreshPending = true
        } else {
            reload(selecting: nil, isNavigation: false)
        }
    }

    /// names 为 nil 表示保留当前选中项
    func reload(selecting names: [String]?, isNavigation: Bool) {
        generation += 1
        let token = generation
        let url = currentURL
        let showHidden = showHidden
        let order = sortOrder
        isLoading = true
        refreshPending = false
        let startedAt = ContinuousClock.now
        Task.detached(priority: .userInitiated) {
            let outcome: LoadOutcome
            do throws(DirectoryReadError) {
                let raw = try DirectoryReader.read(url)
                outcome = .success(FileSorter.arrange(raw, showHidden: showHidden, order: order))
            } catch {
                outcome = .failure(error)
            }
            await self.apply(outcome, token: token, selecting: names, isNavigation: isNavigation, startedAt: startedAt)
        }
    }

    private func apply(_ outcome: LoadOutcome, token: Int, selecting names: [String]?, isNavigation: Bool, startedAt: ContinuousClock.Instant) {
        guard token == generation else { return }
        isLoading = false
        // 重命名期间收到的刷新结果先不用，编辑结束后再刷
        if renamingItem != nil, !isNavigation {
            refreshPending = true
            return
        }

        switch outcome {
        case .success(let newItems):
            let keep = names ?? selectedNames()
            items = newItems
            tableView.reloadData()
            if viewMode == .icons { gridView.reloadData() }
            select(names: keep, scroll: isNavigation)
            if isNavigation, tableView.selectedRowIndexes.isEmpty, !items.isEmpty {
                tableView.scrollRowToVisible(0)
                if viewMode == .icons { gridView.scroll(.zero) }
            }
            if viewMode == .icons { syncGridFromTable(scroll: false) }
            if items.isEmpty {
                placeholder.show(symbol: "folder", message: "空文件夹")
            } else {
                placeholder.hide()
            }
            DebugHooks.didLoad(view, count: items.count, startedAt: startedAt)
            if let name = pendingRenameName, selectedNames() == [name] {
                pendingRenameName = nil
                beginRename()
            }

        case .failure(let error):
            // 正在看的目录被删了或改名了：退到最近一个还存在的上层目录
            if error.isMissing, !isNavigation {
                retreatToExistingAncestor()
                return
            }
            items = []
            tableView.reloadData()
            if viewMode == .icons { gridView.reloadData() }
            showError(error)
        }

        updateStatus()
        if refreshPending, renamingItem == nil {
            reload(selecting: nil, isNavigation: false)
        }
    }

    private func showError(_ error: DirectoryReadError) {
        let name = FileManager.default.displayName(atPath: currentURL.path(percentEncoded: false))
        if error.isPermissionDenied {
            placeholder.show(
                symbol: "lock",
                message: "没有权限读取「\(name)」\n在「完全磁盘访问权限」里允许 Harbor 后重试",
                buttonTitle: "打开系统设置"
            ) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        } else if error.isMissing {
            placeholder.show(symbol: "questionmark.folder", message: "「\(name)」不存在")
        } else {
            placeholder.show(symbol: "exclamationmark.triangle", message: "无法读取「\(name)」：\(error.message)")
        }
    }

    private func retreatToExistingAncestor() {
        var url = currentURL.deletingLastPathComponent()
        while url.pathKey != "/", !AppDelegate.isDirectory(url) {
            url = url.deletingLastPathComponent()
        }
        navigate(to: url)
    }

    func selectedNames() -> [String] {
        tableView.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].name : nil }
    }

    private func select(names: [String], scroll: Bool) {
        guard !names.isEmpty else {
            tableView.deselectAll(nil)
            return
        }
        let wanted = Set(names)
        var indexes = IndexSet()
        for (index, item) in items.enumerated() where wanted.contains(item.name) {
            indexes.insert(index)
        }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        if scroll, let first = indexes.first {
            tableView.scrollRowToVisible(first)
            if viewMode == .icons { syncGridFromTable(scroll: true) }
        }
    }

    // MARK: - 状态栏

    private func updateFreeSpace() {
        guard !isVirtual else { return }
        let url = currentURL
        Task.detached(priority: .utility) {
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let free = values?.volumeAvailableCapacityForImportantUsage
            await MainActor.run {
                guard self.currentURL.pathKey == url.pathKey else { return }
                self.freeSpace = free
                self.updateStatus()
            }
        }
    }

    func updateStatus() {
        let selected = tableView.selectedRowIndexes.count
        let count = selected > 0 ? "已选择 \(selected) 项，共 \(items.count) 项" : "\(items.count) 项"
        statusBar.set(left: count, right: freeSpace.map { "可用 \(Formatters.size($0))" } ?? "")
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < items.count, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let item = items[row]
        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? FileCellView
            ?? FileCellView(identifier: tableColumn.identifier, style: column == .name ? .name : column == .size ? .number : .detail)
        switch column {
        case .name:
            cell.textField?.stringValue = item.name
            cell.imageView?.image = IconProvider.shared.icon(for: item, in: currentURL)
        case .modified:
            cell.textField?.stringValue = Formatters.date(item.modified)
        case .size:
            cell.textField?.stringValue = item.size.map(Formatters.size) ?? "--"
        case .kind:
            cell.textField?.stringValue = FileTypes.kindDescription(for: item)
        }
        // 隐藏文件淡显，和 Finder 一致
        cell.alphaValue = item.isHidden ? 0.5 : 1
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key.flatMap(FileSortOrder.Key.init(rawValue:)) else { return }
        sortOrder.key = key
        sortOrder.ascending = descriptor.ascending
        Preferences.sortOrder = sortOrder
        reload(selecting: nil, isNavigation: false)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if viewMode == .icons, !isSyncingSelection { syncGridFromTable(scroll: false) }
        updateStatus()
        refreshQuickLook()
    }

    /// 输入文件名快速定位（系统自带的 type-select），只按名称列匹配
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier.rawValue == Column.name.rawValue, row < items.count else { return nil }
        return items[row].name
    }
}
