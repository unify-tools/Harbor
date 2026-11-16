import AppKit
import HarborCore
import QuickLookThumbnailing
import Synchronization

/// 图标视图：和列表用同一份 items，选中状态以列表为准（见 BrowserViewController+Grid）。
/// 回车重命名、空格快速查看、Tab 切栏、双击打开，和列表一致
final class FileGridView: NSCollectionView {
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    var onTab: (() -> Bool)?
    var onFocus: (() -> Void)?
    var onDoubleClick: ((IndexPath) -> Void)?
    /// 右键点中的项目，nil 表示空白处（菜单据此决定内容）
    private(set) var clickedIndexPath: IndexPath?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty, let onReturn {
            onReturn()
            return
        }
        if event.keyCode == 49, modifiers.isEmpty, let onSpace {
            onSpace()
            return
        }
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift, onTab?() == true {
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onDoubleClick?(indexPath)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        clickedIndexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        return super.menu(for: event)
    }

    /// 菜单关掉后清掉，免得键盘打开的菜单用上一次的位置
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        clickedIndexPath = nil
    }
}

/// 一个图标：缩略图（拿到之前先显示文件类型图标）+ 文件名，选中时圆角色块
final class FileGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileGridItem")
    static let size = NSSize(width: 108, height: 112)

    let nameField = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    /// 防止复用的格子收到上一个文件的缩略图
    private var representedPath: String?

    override func loadView() {
        let root = GridItemBackground()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameField.alignment = .center
        nameField.font = .systemFont(ofSize: 12)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.maximumNumberOfLines = 1
        for subview in [iconView, nameField] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            iconView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            nameField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            nameField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            nameField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
        ])
        view = root
        imageView = iconView
        textField = nameField
    }

    func configure(item: FileItem, in directory: URL) {
        nameField.stringValue = item.name
        view.alphaValue = item.isHidden ? 0.5 : 1
        let url = item.url(in: directory)
        let path = url.path(percentEncoded: false)
        representedPath = path
        iconView.image = IconProvider.shared.icon(for: item, in: directory)
        // 文件夹、包用系统图标就好；普通文件取缩略图（图片、PDF、视频……）
        guard item.kind == .file else { return }
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        ThumbnailProvider.shared.thumbnail(for: url, modified: item.modified, size: NSSize(width: 64, height: 64), scale: scale) { [weak self] image in
            guard let self, self.representedPath == path, let image else { return }
            self.iconView.image = image
        }
    }

    override var isSelected: Bool {
        didSet { (view as? GridItemBackground)?.isSelected = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedPath = nil
    }
}

private final class GridItemBackground: NSView {
    var isSelected = false { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        }
    }
}

/// 缩略图缓存：按路径 + 修改时间 + 尺寸，文件改了就重新生成
@MainActor
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()
    private let cache = NSCache<NSString, NSImage>()
    private var pending: [NSString: [(NSImage?) -> Void]] = [:]

    private init() {
        cache.countLimit = 1000
    }

    func cached(for url: URL, modified: Date?, size: NSSize) -> NSImage? {
        cache.object(forKey: key(url, modified, size))
    }

    func thumbnail(for url: URL, modified: Date?, size: NSSize, scale: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let key = key(url, modified, size)
        if let hit = cache.object(forKey: key) {
            completion(hit)
            return
        }
        // 同一个文件同时只生成一次
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        pending[key] = [completion]
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        let keyString = key as String
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let cgImage = representation?.cgImage
            Task { @MainActor in
                let key = keyString as NSString
                let image = cgImage.map { NSImage(cgImage: $0, size: size) }
                if let image { self.cache.setObject(image, forKey: key) }
                let waiting = self.pending.removeValue(forKey: key) ?? []
                waiting.forEach { $0(image) }
            }
        }
    }

    private func key(_ url: URL, _ modified: Date?, _ size: NSSize) -> NSString {
        "\(url.path(percentEncoded: false))|\(modified?.timeIntervalSince1970 ?? 0)|\(Int(size.width))" as NSString
    }
}

/// 分组时的组标题：列表里是组标题行，网格里是分区标题，样式一致
final class GroupHeaderView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GroupHeader")
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class GridGroupHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("GridGroupHeader")
    static let height: CGFloat = 30
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        // 吸顶时盖在图标上，要有底色
        wantsLayer = true
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        }
    }
}

/// 「应用程序」分组用：按扩展名缓存默认应用的名称（后台线程调用）
enum AppNames {
    private static let cache = Mutex<[String: String]>([:])

    static func name(for item: FileItem, in directory: URL) -> String {
        let key = item.pathExtension.lowercased()
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let app = NSWorkspace.shared.urlForApplication(toOpen: item.url(in: directory))
        let name = app.map { (FileManager.default.displayName(atPath: $0.path(percentEncoded: false)) as NSString).deletingPathExtension } ?? ""
        cache.withLock { $0[key] = name }
        return name
    }
}

