import AppKit

/// 工作区的上半部分：一到两栏浏览区，加上悬浮在底部的进度胶囊（Liquid Glass）。
/// 进度条放在这一层而不是每一栏里，双栏时也只显示一份
@MainActor
final class PanesContainerController: NSViewController {
    let paneSplit: ChildSplitViewController
    let operationsBar = OperationsBar()
    private let glass = NSGlassEffectView()
    /// 最近一次 update 的结论；淡出动画结束时据此决定是否真的隐藏
    private var wantsVisible = false

    /// 胶囊底边离浏览区底部的距离：让开状态栏再空一点
    private static let bottomInset: CGFloat = BrowserViewController.statusBarHeight + 12
    /// 胶囊显示时各栏列表要让出的高度：胶囊盖住的部分再加一点
    private static let listOverlap: CGFloat = bottomInset - BrowserViewController.statusBarHeight + OperationsBar.height + 8
    private static let maxWidth: CGFloat = 440

    init(paneSplit: ChildSplitViewController) {
        self.paneSplit = paneSplit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isOperationsBarVisible: Bool { !glass.isHidden && wantsVisible }

    override func loadView() {
        let root = NSView()
        addChild(paneSplit)
        let panes = paneSplit.view
        glass.contentView = operationsBar
        glass.cornerRadius = OperationsBar.height / 2
        glass.isHidden = true
        for subview in [panes, glass] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        let preferredWidth = glass.widthAnchor.constraint(equalToConstant: Self.maxWidth)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            panes.topAnchor.constraint(equalTo: root.topAnchor),
            panes.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panes.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            glass.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            glass.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.bottomInset),
            glass.heightAnchor.constraint(equalToConstant: OperationsBar.height),
            glass.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -32),
            preferredWidth,
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(operationsDidChange),
                                               name: FileOperationCenter.didChange, object: nil)
    }

    @objc private func operationsDidChange() {
        let visible = operationsBar.update(with: FileOperationCenter.shared.activeTransfers)
        guard visible != wantsVisible else { return }
        wantsVisible = visible
        updatePaneInsets()
        if visible {
            glass.alphaValue = 0
            glass.isHidden = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            glass.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // 淡出期间又有新任务时不隐藏
                guard let self, !self.wantsVisible else { return }
                self.glass.isHidden = true
            }
        }
    }

    /// 胶囊显示时各栏列表留出底部余量。双栏切换后由窗口再调一次，给新加的那一栏补上
    func updatePaneInsets() {
        let overlap = wantsVisible ? Self.listOverlap : 0
        for item in paneSplit.splitViewItems {
            (item.viewController as? BrowserViewController)?.bottomOverlap = overlap
        }
    }
}
