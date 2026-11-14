import AppKit
import HarborCore
import Quartz

/// 分类、标签、智能分类、主页「最近」的结果列表：结果分散在不同文件夹，
/// 所以和浏览区的文件列表分开。能打开、打开方式、在所在文件夹中显示、快速查看、拷贝
@MainActor
final class QueryResultsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
                                        NSMenuItemValidation, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private enum Column: String, CaseIterable { case name, location, modified, size }

    weak var owner: BrowserViewController?
    /// 结果数量变化（状态栏显示）
    var onCountChange: ((Int, Bool) -> Void)?

    let tableView = FileTableView()
    private let placeholder = PlaceholderView()
    private let search: SpotlightSearch
    private(set) var results: [SpotlightSearch.Result] = []
    private(set) var isFinished = false
    private let showsDateColumnAs: String

    init(_ query: SmartQuery, live: Bool, sortBy: SpotlightSearch.SortKey = .modified, limit: Int? = nil) {
        search = SpotlightSearch(query, live: live, sortBy: sortBy, limit: limit)
        showsDateColumnAs = sortBy == .lastUsed ? "上次打开" : "修改日期"
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let titles: [Column: (String, CGFloat)] = [.name: ("名称", 280), .location: ("位置", 220), .modified: (showsDateColumnAs, 150), .size: ("大小", 80)]
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = titles[column]!.0
            tableColumn.width = titles[column]!.1
            tableColumn.minWidth = 60
            if column == .size { tableColumn.headerCell.alignment = .right }
            tableView.addTableColumn(tableColumn)
        }
        tableView.style = .fullWidth
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClicked(_:))
        tableView.onReturn = { [weak self] in self?.openSelection() }
        tableView.onSpace = { [weak self] in self?.toggleQuickLook(nil) }
        tableView.onFocus = { [weak self] in
            guard let self, let owner else { return }
            owner.delegate?.browserDidBecomeActive(owner)
        }
        tableView.onTab = { [weak self] in
            guard let self, let owner else { return false }
            return owner.delegate?.browserRequestsPaneSwitch(owner) ?? false
        }
        tableView.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let root = NSView()
        for subview in [scrollView, placeholder] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),
        ])
        view = root
        placeholder.show(symbol: "magnifyingglass", message: "正在查找…")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        search.onUpdate = { [weak self] results, finished in self?.apply(results, finished: finished) }
        search.start()
    }

    func stop() {
        search.stop()
    }

    private func apply(_ newResults: [SpotlightSearch.Result], finished: Bool) {
        let keep = Set(selectedURLs)
        results = newResults
        isFinished = finished
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(results.indices.filter { keep.contains(results[$0].url) }), byExtendingSelection: false)
        if !results.isEmpty {
            placeholder.hide()
        } else if finished {
            placeholder.show(symbol: "doc.text.magnifyingglass", message: "没有找到文件")
        }
        onCountChange?(results.count, finished)
        refreshQuickLook()
    }

    var selectedURLs: [URL] {
        tableView.selectedRowIndexes.compactMap { $0 < results.count ? results[$0].url : nil }
    }

    func focus() {
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: - 打开

    @objc private func openClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        openSelection()
    }

    /// 文件夹（智能分类里可能有）在浏览区里进入，文件用默认应用打开
    func openSelection() {
        for url in selectedURLs {
            if AppDelegate.isDirectory(url), !FileTypes.isPackageExtension(url.pathExtension) {
                owner?.navigate(to: url)
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    @objc func revealInFolder(_ sender: Any?) {
        guard let url = selectedURLs.first else { return }
        owner?.navigate(to: url.deletingLastPathComponent(), selecting: [url.lastPathComponent])
    }

    @objc func copy(_ sender: Any?) {
        owner?.writeToPasteboard(selectedURLs, cut: false)
    }

    @objc func copyPath(_ sender: Any?) {
        owner?.writePaths(selectedURLs)
    }

    @objc func openSelectionFromMenu(_ sender: Any?) {
        openSelection()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleQuickLook(_:)):
            return BrowserViewController.isQuickLookVisible || tableView.selectedRow >= 0
        case #selector(copy(_:)), #selector(copyPath(_:)), #selector(revealInFolder(_:)), #selector(openSelectionFromMenu(_:)):
            return tableView.selectedRow >= 0
        default:
            return true
        }
    }

    // MARK: - 右键菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        if row >= 0, !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        guard row >= 0, let owner else { return }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("打开", #selector(openSelectionFromMenu(_:)))
        let openWith = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
        openWith.submenu = owner.makeOpenWithMenu(for: selectedURLs)
        menu.addItem(openWith)
        add("在所在文件夹中显示", #selector(revealInFolder(_:)))
        add("快速查看", #selector(toggleQuickLook(_:)))
        menu.addItem(.separator())
        add("拷贝", #selector(copy(_:)))
        add("拷贝路径", #selector(copyPath(_:)))
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < results.count, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let result = results[row]
        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? FileCellView
            ?? FileCellView(identifier: tableColumn.identifier, style: column == .name ? .name : column == .size ? .number : .detail)
        switch column {
        case .name:
            cell.textField?.stringValue = result.name
            let icon = NSWorkspace.shared.icon(forFile: result.url.path(percentEncoded: false))
            icon.size = NSSize(width: 16, height: 16)
            cell.imageView?.image = icon
        case .location:
            cell.textField?.stringValue = (result.url.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        case .modified:
            cell.textField?.stringValue = (showsDateColumnAs == "上次打开" ? result.lastUsed : result.modified).map(Formatters.date) ?? "--"
        case .size:
            cell.textField?.stringValue = result.size.map(Formatters.size) ?? "--"
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        row < results.count ? results[row].url as NSURL : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshQuickLook()
        onCountChange?(results.count, isFinished)
    }

    var selectedCount: Int { tableView.selectedRowIndexes.count }

    // MARK: - 快速查看

    @objc func toggleQuickLook(_ sender: Any?) {
        if BrowserViewController.isQuickLookVisible {
            QLPreviewPanel.shared()?.orderOut(nil)
        } else if tableView.selectedRow >= 0 {
            QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
        }
    }

    private func refreshQuickLook() {
        guard BrowserViewController.isQuickLookVisible, let panel = QLPreviewPanel.shared(),
              (panel.dataSource as AnyObject?) === self else { return }
        panel.reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // 预览面板总在主线程回调
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = selectedURLs
        return index < urls.count ? urls[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49 || (123...126).contains(event.keyCode) else { return false }
        tableView.keyDown(with: event)
        return true
    }
}
