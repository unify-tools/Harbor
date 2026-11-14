import AppKit
import HarborCore

/// 边栏：个人收藏 + 位置（挂载的磁盘），挂载变化时自动刷新
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Section {
        let title: String
        let items: [Item]
        init(title: String, items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    final class Item {
        let title: String
        let url: URL
        let symbol: String
        init(title: String, url: URL, symbol: String) {
            self.title = title
            self.url = url
            self.symbol = symbol
        }
    }

    var onSelect: ((URL) -> Void)?

    private var sections: [Section] = []
    private let outlineView = NSOutlineView()
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
    }

    /// 浏览区跳转后同步高亮；不在边栏里的位置取消高亮
    func reveal(_ url: URL) {
        revealedKey = url.pathKey
        isRevealing = true
        defer { isRevealing = false }
        for row in 0..<outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) as? Item, item.url.pathKey == revealedKey {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
        outlineView.deselectAll(nil)
    }

    @objc private func volumesChanged() {
        reloadSections()
    }

    private func reloadSections() {
        let fm = FileManager.default
        let favorites = [
            Item(title: NSUserName(), url: fm.homeDirectoryForCurrentUser, symbol: "house"),
            Item(title: "桌面", url: .desktopDirectory, symbol: "menubar.dock.rectangle"),
            Item(title: "文稿", url: .documentsDirectory, symbol: "doc"),
            Item(title: "下载", url: .downloadsDirectory, symbol: "arrow.down.circle"),
            Item(title: "应用程序", url: .applicationDirectory, symbol: "square.grid.2x2"),
        ]
        sections = [
            Section(title: "个人收藏", items: favorites),
            Section(title: "位置", items: volumeItems()),
        ]
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        if let revealedKey { reveal(URL(filePath: revealedKey)) }
    }

    private func volumeItems() -> [Item] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let symbol = values?.volumeIsRootFileSystem == true ? "internaldrive"
                : values?.volumeIsLocal == false ? "network" : "externaldrive"
            return Item(title: values?.volumeLocalizedName ?? url.lastPathComponent, url: url, symbol: symbol)
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return sections.count }
        return (item as? Section)?.items.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let section = item as? Section else { return sections[index] }
        return section.items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Section
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is Section
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is Item
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
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
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRevealing, let item = outlineView.item(atRow: outlineView.selectedRow) as? Item else { return }
        revealedKey = item.url.pathKey
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
