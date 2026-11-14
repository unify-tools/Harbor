import AppKit
import HarborCore

/// 边栏（分组借鉴鸿蒙文件管理）：主页、快速访问（可添加 / 移除）、存储位置（磁盘按树展开）、标签。
/// 挂载变化、快速访问变化时自动刷新
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    final class Section {
        let title: String
        var items: [Item]
        init(title: String, items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    final class Item {
        let title: String
        let url: URL
        let symbol: String
        let tint: NSColor?
        /// 存储位置里的文件夹：可以展开看子文件夹
        let isTree: Bool
        /// 子文件夹，第一次展开时读
        lazy var children: [Item] = isTree ? SidebarViewController.subfolders(of: url) : []

        init(title: String, url: URL, symbol: String, tint: NSColor? = nil, isTree: Bool = false) {
            self.title = title
            self.url = url
            self.symbol = symbol
            self.tint = tint
            self.isTree = isTree
        }
    }

    var onSelect: ((URL) -> Void)?

    private let homeItem = Item(title: "主页", url: VirtualLocation.home.url, symbol: "house.circle")
    private(set) var sections: [Section] = []
    private let quickAccess = Section(title: "快速访问", items: [])
    let outlineView = NSOutlineView()
    private var revealedKey: String?
    /// 程序设置选中项时不触发 onSelect
    private var isRevealing = false

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadSections()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
        }
        for name in [QuickAccessStore.didChange, SmartCategoryStore.didChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(quickAccessChanged), name: name, object: nil)
        }
    }

    /// 浏览区跳转后同步高亮；不在边栏里的位置取消高亮
    func reveal(_ url: URL) {
        revealedKey = url.locationKey
        isRevealing = true
        defer { isRevealing = false }
        for row in 0..<outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) as? Item, item.url.locationKey == revealedKey {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
        outlineView.deselectAll(nil)
    }

    @objc private func volumesChanged() {
        reloadSections()
    }

    /// 只刷新快速访问这一组，存储位置展开的树保持不动
    @objc private func quickAccessChanged() {
        quickAccess.items = quickAccessItems()
        outlineView.reloadItem(quickAccess, reloadChildren: true)
        if let revealedKey { reveal(Self.url(forKey: revealedKey)) }
    }

    private func reloadSections() {
        quickAccess.items = quickAccessItems()
        sections = [
            quickAccess,
            Section(title: "存储位置", items: volumeItems()),
            Section(title: "标签", items: tagItems()),
        ]
        outlineView.reloadData()
        sections.forEach { outlineView.expandItem($0) }
        if let revealedKey { reveal(Self.url(forKey: revealedKey)) }
    }

    private static func url(forKey key: String) -> URL {
        key.hasPrefix("/") ? URL(filePath: key) : URL(string: key) ?? URL(filePath: "/")
    }

    private func quickAccessItems() -> [Item] {
        let fm = FileManager.default
        let known: [String: (String, String)] = [
            fm.homeDirectoryForCurrentUser.pathKey: (NSUserName(), "house"),
            URL.desktopDirectory.pathKey: ("桌面", "menubar.dock.rectangle"),
            URL.documentsDirectory.pathKey: ("文稿", "doc"),
            URL.downloadsDirectory.pathKey: ("下载", "arrow.down.circle"),
            URL.applicationDirectory.pathKey: ("应用程序", "square.grid.2x2"),
        ]
        return QuickAccessStore.shared.urls.compactMap { url in
            if let location = VirtualLocation(url: url) {
                // 固定的智能分类被删了就不显示
                if case .smart(let id) = location, SmartCategoryStore.shared.category(id) == nil { return nil }
                return Item(title: location.title, url: url, symbol: location.symbol)
            }
            if let (title, symbol) = known[url.pathKey] { return Item(title: title, url: url, symbol: symbol) }
            return Item(title: fm.displayName(atPath: url.path(percentEncoded: false)), url: url, symbol: "folder")
        }
    }

    private func volumeItems() -> [Item] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let symbol = values?.volumeIsRootFileSystem == true ? "internaldrive"
                : values?.volumeIsLocal == false ? "network" : "externaldrive"
            return Item(title: values?.volumeLocalizedName ?? url.lastPathComponent, url: url, symbol: symbol, isTree: true)
        }
    }

    /// Finder 的标签颜色（系统本地化的名称），点开按标签查找
    private func tagItems() -> [Item] {
        let names = NSWorkspace.shared.fileLabels
        let colors = NSWorkspace.shared.fileLabelColors
        return names.indices.dropFirst().compactMap { index in
            guard index < colors.count else { return nil }
            return Item(title: names[index], url: VirtualLocation.tag(names[index]).url, symbol: "circle.fill", tint: colors[index])
        }
    }

    /// 可见的子文件夹（不含包），按 Finder 规则排序
    nonisolated static func subfolders(of url: URL) -> [Item] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return children
            .filter { child in
                let values = try? child.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Item(title: $0.lastPathComponent, url: $0, symbol: "folder", isTree: true) }
    }

    // MARK: - 右键菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? Item else { return }
        let url = item.url
        if QuickAccessStore.shared.contains(url) {
            menu.addItem(ClosureMenuItem("从快速访问移除") { QuickAccessStore.shared.remove(url) })
        } else if url.isFileURL {
            menu.addItem(ClosureMenuItem("添加至快速访问") { QuickAccessStore.shared.add(url) })
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return 1 + sections.count }
        if let section = item as? Section { return section.items.count }
        return (item as? Item)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return index == 0 ? homeItem : sections[index - 1] }
        if let section = item as? Section { return section.items[index] }
        return (item as! Item).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Section || (item as? Item)?.isTree == true
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is Section
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is Item
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        (item as? Item)?.isTree == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? Section {
            let cell = reuse("header") { SidebarCell(isHeader: true) }
            cell.textField?.stringValue = section.title
            return cell
        }
        guard let item = item as? Item else { return nil }
        let cell = reuse("item") { SidebarCell(isHeader: false) }
        cell.textField?.stringValue = item.title
        cell.imageView?.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
        cell.imageView?.contentTintColor = item.tint ?? .controlAccentColor
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRevealing, let item = outlineView.item(atRow: outlineView.selectedRow) as? Item else { return }
        revealedKey = item.url.locationKey
        onSelect?(item.url)
    }

    private func reuse(_ id: String, make: () -> SidebarCell) -> SidebarCell {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCell { return cell }
        let cell = make()
        cell.identifier = identifier
        return cell
    }
}

private final class SidebarCell: NSTableCellView {
    init(isHeader: Bool) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label

        if isHeader {
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            return
        }

        let icon = NSImageView()
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
