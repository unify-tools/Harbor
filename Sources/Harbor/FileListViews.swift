import AppKit
import HarborCore
import UniformTypeIdentifiers

/// 文件列表的单元格。表格会复用，只在首次需要时创建。
final class FileCellView: NSTableCellView {
    enum Style { case name, detail, number }

    init(identifier: NSUserInterfaceItemIdentifier, style: Style) {
        super.init(frame: .zero)
        self.identifier = identifier

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = style == .name ? .systemFont(ofSize: 13) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = style == .name ? .labelColor : .secondaryLabelColor
        // 文件名截中间，保留扩展名
        label.lineBreakMode = style == .name ? .byTruncatingMiddle : .byTruncatingTail
        label.alignment = style == .number ? .right : .left
        addSubview(label)
        textField = label

        var constraints = [
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if style == .name {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(icon)
            imageView = icon
            constraints += [
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            ]
        } else {
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// 列表图标：普通文件按类型缓存（几十种类型共享），目录按路径缓存（.app、特殊文件夹的图标各不相同）
@MainActor
final class IconProvider {
    static let shared = IconProvider()

    private var typeIcons: [String: NSImage] = [:]
    private let pathIcons = NSCache<NSString, NSImage>()

    private init() {
        pathIcons.countLimit = 2000
    }

    func icon(for item: FileItem, in directory: URL) -> NSImage {
        switch item.kind {
        case .directory:
            let path = item.url(in: directory).path(percentEncoded: false)
            if let hit = pathIcons.object(forKey: path as NSString) { return hit }
            let image = sized(NSWorkspace.shared.icon(forFile: path))
            pathIcons.setObject(image, forKey: path as NSString)
            return image
        case .symlink:
            return typeIcon(key: "symlink", type: .symbolicLink)
        case .file, .other:
            let ext = item.pathExtension.lowercased()
            return typeIcon(key: "f:" + ext, type: ext.isEmpty ? .data : UTType(filenameExtension: ext) ?? .data)
        }
    }

    private func typeIcon(key: String, type: UTType) -> NSImage {
        if let hit = typeIcons[key] { return hit }
        let image = sized(NSWorkspace.shared.icon(for: type))
        typeIcons[key] = image
        return image
    }

    private func sized(_ image: NSImage) -> NSImage {
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

@MainActor
enum Formatters {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        // 今天、昨天显示成相对日期
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 底部状态栏：左边条目数，右边可用空间
final class StatusBarView: NSView {
    private let left = NSTextField(labelWithString: "")
    private let right = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        let separator = NSBox()
        separator.boxType = .separator
        for label in [left, right] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        for subview in [separator, left, right] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(left: String, right: String) {
        self.left.stringValue = left
        self.right.stringValue = right
    }
}

/// 列表为空或读取失败时显示在中间的提示
final class PlaceholderView: NSStackView {
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var buttonAction: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        spacing = 10
        icon.symbolConfiguration = .init(pointSize: 36, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        button.bezelStyle = .push
        button.target = self
        button.action = #selector(buttonClicked)
        addArrangedSubview(icon)
        addArrangedSubview(label)
        addArrangedSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(symbol: String, message: String, buttonTitle: String? = nil, action: (() -> Void)? = nil) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        label.stringValue = message
        button.title = buttonTitle ?? ""
        button.isHidden = buttonTitle == nil
        buttonAction = action
        isHidden = false
    }

    func hide() {
        isHidden = true
    }

    @objc private func buttonClicked() {
        buttonAction?()
    }
}

/// 文件列表：回车开始重命名（和 Finder 一致），双栏时 Tab 切到另一栏
final class FileTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onFocus: (() -> Void)?
    /// 返回 false 时按系统默认处理
    var onTab: (() -> Bool)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        // 36 = Return，76 = 小键盘 Enter
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty, let onReturn {
            onReturn()
            return
        }
        // 48 = Tab，带不带 ⇧ 都切换（只有两栏）
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift, onTab?() == true {
            return
        }
        super.keyDown(with: event)
    }
}

/// 拷贝 / 移动 / 压缩的进度，可以取消。每个窗口一份，悬浮在浏览区底部（玻璃胶囊），双栏时也只有一个
@MainActor
final class OperationsBar: NSView {
    static let height: CGFloat = 46

    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let indicator = NSProgressIndicator()
    private let cancelButton = NSButton()
    private weak var activity: TransferActivity?

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.controlSize = .small
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "取消")
        cancelButton.isBordered = false
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.toolTip = "取消"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        for subview in [label, detail, indicator, cancelButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            detail.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            indicator.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            indicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 显示第一个已经跑了超过 0.3 秒的操作；没有就返回 false
    func update(with activities: [TransferActivity]) -> Bool {
        let now = ContinuousClock.now
        guard let current = activities.first(where: { now - $0.startedAt > .milliseconds(300) }) else {
            activity = nil
            return false
        }
        activity = current
        let others = activities.count - 1
        label.stringValue = current.title + (others > 0 ? "（另有 \(others) 个任务）" : "")
        let progress = current.progress
        indicator.doubleValue = progress.fraction
        if progress.totalBytes > 0 {
            detail.stringValue = "\(Formatters.size(progress.completedBytes)) / \(Formatters.size(progress.totalBytes))"
        } else {
            detail.stringValue = "\(progress.completedItems) / \(progress.totalItems)"
        }
        return true
    }

    @objc private func cancelClicked() {
        activity?.cancel()
    }

    /// 给调试脚本看
    var displayedTitle: String { label.stringValue }
}
