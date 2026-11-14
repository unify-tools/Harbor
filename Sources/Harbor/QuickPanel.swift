import AppKit

/// 面板里的一行
struct QuickPanelItem {
    var title: String
    /// 标题里需要加粗的字符位置（模糊匹配命中的字符）
    var highlights: [Int] = []
    var subtitle: String?
    /// 右侧的提示，比如快捷键
    var detail: String?
    var icon: NSImage?
    /// alternate：按住 ⌘ 回车
    var perform: @MainActor (_ alternate: Bool) -> Void
}

/// 命令面板和快速跳转共用的浮层：顶部输入框 + 结果列表，挂在主窗口上方居中。
/// ↑↓（或 ⌃P / ⌃N）移动，回车执行，Esc 或点到别处关闭。
@MainActor
final class QuickPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    /// 同一时间只有一个面板；也给调试脚本用
    private(set) static var current: QuickPanel?

    private static let width: CGFloat = 600
    private static let fieldHeight: CGFloat = 48
    private static let rowHeight: CGFloat = 40
    private static let maxVisibleRows = 9
    private static let footerHeight: CGFloat = 26
    private static let cornerRadius: CGFloat = 22

    private let search: (String) -> [QuickPanelItem]
    private(set) var items: [QuickPanelItem] = []
    private weak var parent: NSWindow?
    private let panel: PanelWindow
    private let field = NSTextField()
    private let tableView = PanelTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "没有匹配的结果")
    private var isClosing = false

    /// 在 parent 上打开面板；已有面板时先关掉
    @discardableResult
    static func show(in parent: NSWindow, placeholder: String, footer: String,
                     search: @escaping (String) -> [QuickPanelItem]) -> QuickPanel {
        current?.close()
        let quickPanel = QuickPanel(parent: parent, placeholder: placeholder, footer: footer, search: search)
        current = quickPanel
        quickPanel.present()
        return quickPanel
    }

    private init(parent: NSWindow, placeholder: String, footer: String, search: @escaping (String) -> [QuickPanelItem]) {
        self.parent = parent
        self.search = search
        panel = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.onCommandReturn = { [weak self] in self?.confirm(alternate: true) }
        panel.contentView = makeContent(placeholder: placeholder, footer: footer)
    }

    var query: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            refresh()
        }
    }

    var selectedIndex: Int { tableView.selectedRow }

    // MARK: - 布局

    private func makeContent(placeholder: String, footer: String) -> NSView {
        // Liquid Glass：玻璃本身负责圆角、边缘高光和阴影，内容放在 contentView 里
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.cornerRadius
        let background = NSView()
        glass.contentView = background

        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 18)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.allowsUndo = false

        let searchIcon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        searchIcon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        searchIcon.contentTintColor = .secondaryLabelColor

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // .inset 会给滚动区加上下内边距，高度就算不准了；圆角选中背景自己画
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true

        let footerLabel = NSTextField(labelWithString: footer)
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .tertiaryLabelColor

        for subview in [searchIcon, field, topSeparator, scrollView, emptyLabel, bottomSeparator, footerLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: background.topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            field.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),

            topSeparator.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.fieldHeight),
            topSeparator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: background.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor, constant: -4),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            bottomSeparator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.footerHeight),

            footerLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            footerLabel.centerYAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.footerHeight / 2),
        ])
        return glass
    }

    private func present() {
        guard let parent else { return }
        refresh()
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// 高度随结果条数变化，顶边固定在主窗口标题栏下方
    private func resize() {
        guard let parent else { return }
        let rows = max(1, min(items.count, Self.maxVisibleRows))
        let height = Self.fieldHeight + 1 + 8 + CGFloat(rows) * Self.rowHeight + 1 + Self.footerHeight
        let parentFrame = parent.frame
        let top = parentFrame.maxY - min(90, parentFrame.height * 0.15)
        let width = min(Self.width, parentFrame.width - 40)
        let frame = NSRect(x: parentFrame.midX - width / 2, y: top - height, width: width, height: height)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func refresh() {
        items = search(field.stringValue)
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        if !items.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        resize()
    }

    // MARK: - 动作

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, tableView.selectedRow + delta))
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func confirm(alternate: Bool) {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else {
            NSSound.beep()
            return
        }
        let item = items[row]
        close()
        item.perform(alternate)
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        // 点到别的窗口导致的关闭不抢回焦点；Esc、回车关闭时焦点回到主窗口（主窗口里的第一响应者没变过）
        let restoreFocus = panel.isKeyWindow
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if restoreFocus { parent?.makeKeyAndOrderFront(nil) }
        if Self.current === self { Self.current = nil }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        confirm(alternate: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: - 输入框

    func controlTextDidChange(_ notification: Notification) {
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            moveSelection(by: -Self.maxVisibleRows)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            moveSelection(by: Self.maxVisibleRows)
        case #selector(NSResponder.insertNewline(_:)):
            confirm(alternate: false)
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            // 文本框里 Esc 默认触发 complete:
            close()
        default:
            return false
        }
        return true
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? PanelCell ?? PanelCell(identifier: identifier)
        cell.configure(items[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PanelRowView()
    }
}

/// 无边框窗口默认不能成为 key window，输入框就收不到键盘
private final class PanelWindow: NSPanel {
    var onCommandReturn: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌘↩ 不经过 doCommandBy，在这里截下来；输入法正在组字时不截
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]) == .command,
           (firstResponder as? NSTextView)?.hasMarkedText() != true, let onCommandReturn {
            onCommandReturn()
            return
        }
        super.sendEvent(event)
    }
}

private final class PanelTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

/// 选中行始终用强调色（焦点在输入框，表格本身不是第一响应者），左右留边、圆角
private final class PanelRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        // 和玻璃面板的大圆角同心：左右留 10，圆角 10
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 10, yRadius: 10).fill()
    }
}

private final class PanelCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var titleCenter: NSLayoutConstraint!
    private var titleTop: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingHead
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView = icon
        textField = title

        for subview in [icon, title, subtitle, detail] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        titleCenter = title.centerYAnchor.constraint(equalTo: centerYAnchor)
        titleTop = title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -12),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: QuickPanelItem) {
        icon.image = item.icon
        title.attributedStringValue = Self.highlighted(item.title, item.highlights)
        subtitle.stringValue = item.subtitle ?? ""
        subtitle.isHidden = item.subtitle == nil
        detail.stringValue = item.detail ?? ""
        // 有副标题时两行，没有时标题垂直居中
        titleCenter.isActive = item.subtitle == nil
        titleTop.isActive = item.subtitle != nil
    }

    private static func highlighted(_ text: String, _ positions: [Int]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let marks = Set(positions)
        let regular: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .bold)]
        for (index, char) in text.enumerated() {
            result.append(NSAttributedString(string: String(char), attributes: marks.contains(index) ? bold : regular))
        }
        return result
    }
}
