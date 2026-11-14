import AppKit
import HarborCore

/// 主页（借鉴鸿蒙文件管理的主页）：上面是分类卡片（文档、图片…和自建的智能分类），
/// 下面是最近打开过的文件
@MainActor
final class HomeViewController: NSViewController {
    weak var owner: BrowserViewController?
    /// 「最近」结果数量变化（状态栏）
    var onCountChange: ((Int, Bool) -> Void)?

    private let cardsView = CardsView()
    private(set) var recent: QueryResultsViewController!
    /// 卡片上的数量：每张卡片一个一次性查询
    private var counters: [SpotlightSearch] = []

    static var recentLimit: Int {
        let value = UserDefaults.standard.integer(forKey: "homeRecentLimit")
        return value > 0 ? value : 50
    }

    override func loadView() {
        recent = QueryResultsViewController(.recent, live: true, sortBy: .lastUsed, limit: Self.recentLimit)
        recent.owner = owner
        recent.onCountChange = { [weak self] count, finished in self?.onCountChange?(count, finished) }
        addChild(recent)

        let categoriesTitle = Self.sectionTitle("分类")
        let recentTitle = Self.sectionTitle("最近")
        let root = NSView()
        for subview in [categoriesTitle, cardsView, recentTitle, recent.view] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            categoriesTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            categoriesTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            cardsView.topAnchor.constraint(equalTo: categoriesTitle.bottomAnchor, constant: 10),
            cardsView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            cardsView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            recentTitle.topAnchor.constraint(equalTo: cardsView.bottomAnchor, constant: 18),
            recentTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            recent.view.topAnchor.constraint(equalTo: recentTitle.bottomAnchor, constant: 8),
            recent.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            recent.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            recent.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadCards()
        NotificationCenter.default.addObserver(self, selector: #selector(categoriesChanged),
                                               name: SmartCategoryStore.didChange, object: nil)
    }

    func stop() {
        counters.forEach { $0.stop() }
        counters = []
        recent.stop()
    }

    @objc private func categoriesChanged() {
        reloadCards()
    }

    var cards: [CardView] { cardsView.cards }

    private func reloadCards() {
        counters.forEach { $0.stop() }
        counters = []
        var cards: [CardView] = SmartQuery.Kind.allCases.map { kind in
            CardView(title: kind.title, symbol: kind.symbol, tint: kind.tint, location: .category(kind))
        }
        cards += SmartCategoryStore.shared.categories.map { category in
            CardView(title: category.name, symbol: VirtualLocation.smart(category.id).symbol, tint: .systemIndigo,
                     location: .smart(category.id))
        }
        for card in cards {
            card.onOpen = { [weak self] location in
                if let location { self?.owner?.navigate(to: location.url) }
            }
            card.menuProvider = { [weak self] location in self?.menu(for: location) }
            guard let (query, _) = card.location?.query else { continue }
            let counter = SpotlightSearch(query, live: false, countOnly: true)
            counter.onUpdate = { [weak card, weak counter] _, finished in
                if finished, let counter { card?.detail = "\(counter.count) 项" }
            }
            counter.start()
            counters.append(counter)
        }
        let add = CardView(title: "新建智能分类", symbol: "plus", tint: .secondaryLabelColor, location: nil)
        add.onOpen = { [weak self] _ in self?.owner?.newSmartCategory(nil) }
        add.detail = "按类型、时间、名称"
        cards.append(add)
        cardsView.cards = cards
    }

    private func menu(for location: VirtualLocation) -> NSMenu {
        let menu = NSMenu()
        let pinned = QuickAccessStore.shared.contains(location.url)
        menu.addItem(ClosureMenuItem(pinned ? "从快速访问移除" : "固定到快速访问") {
            if pinned { QuickAccessStore.shared.remove(location.url) } else { QuickAccessStore.shared.add(location.url) }
        })
        if case .smart(let id) = location {
            menu.addItem(ClosureMenuItem("编辑…") { [weak self] in
                guard let category = SmartCategoryStore.shared.category(id), let window = self?.view.window else { return }
                SmartCategoryEditor.edit(category, in: window) { SmartCategoryStore.shared.save($0) }
            })
            menu.addItem(ClosureMenuItem("删除") { SmartCategoryStore.shared.remove(id) })
        }
        return menu
    }

    private static func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }
}

/// 卡片按宽度自动换行排列
final class CardsView: NSView {
    static let cardSize = NSSize(width: 168, height: 76)
    private static let spacing: CGFloat = 12

    var cards: [CardView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            cards.forEach(addSubview)
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
    }

    override var isFlipped: Bool { true }

    private var columns: Int {
        max(1, Int((bounds.width + Self.spacing) / (Self.cardSize.width + Self.spacing)))
    }

    override var intrinsicContentSize: NSSize {
        let rows = (cards.count + columns - 1) / columns
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: CGFloat(rows) * Self.cardSize.height + CGFloat(max(0, rows - 1)) * Self.spacing)
    }

    override func layout() {
        super.layout()
        let columns = columns
        // 卡片拉伸填满整行
        let width = (bounds.width - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns)
        for (index, card) in cards.enumerated() {
            let row = index / columns, column = index % columns
            card.frame = NSRect(x: CGFloat(column) * (width + Self.spacing), y: CGFloat(row) * (Self.cardSize.height + Self.spacing),
                                width: width, height: Self.cardSize.height)
        }
        invalidateIntrinsicContentSize()
    }
}

/// 一张分类卡片：彩色圆形图标 + 名称 + 数量，点击进入
final class CardView: NSView {
    let location: VirtualLocation?
    var onOpen: ((VirtualLocation?) -> Void)?
    var menuProvider: ((VirtualLocation) -> NSMenu?)?
    var detail: String = "" { didSet { detailLabel.stringValue = detail } }
    let title: String

    private let tint: NSColor
    private let detailLabel = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { needsDisplay = true } }

    init(title: String, symbol: String, tint: NSColor, location: VirtualLocation?) {
        self.title = title
        self.tint = tint
        self.location = location
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 18
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        icon.contentTintColor = location == nil ? .secondaryLabelColor : .white
        badge.layer?.backgroundColor = (location == nil ? NSColor.quaternaryLabelColor : tint).cgColor
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.stringValue = location == nil ? "" : "…"

        for subview in [badge, icon, titleLabel, detailLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 36),
            badge.heightAnchor.constraint(equalToConstant: 36),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            detailLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        updateBackground()
    }

    /// 底色是主题色的淡色（深浅色都按当前外观解析）
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = location == nil ? NSColor.labelColor : tint
            layer?.backgroundColor = base.withAlphaComponent(isHovered ? 0.16 : 0.09).cgColor
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?(location) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        location.flatMap { menuProvider?($0) }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool {
        onOpen?(location)
        return true
    }
}

/// 用闭包当动作的菜单项（一次性菜单用）
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
