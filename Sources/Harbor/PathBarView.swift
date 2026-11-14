import AppKit

/// 地址栏：平时显示可点击的面包屑，⌘L / ⌘⇧G 或点空白处切换成输入框。
/// 输入框支持 ~、相对路径、Tab 补全，回车前往，Esc 取消。
@MainActor
final class PathBarView: NSView, NSTextFieldDelegate {
    var onNavigate: ((URL) -> Void)?
    /// 返回 false 表示路径无效，保留输入框继续编辑
    var onSubmit: ((String) -> Bool)?
    var completer: ((String) -> String?)?
    var onEndEditing: (() -> Void)?
    var onBeginEditing: (() -> Void)?
    var onCopyPath: (() -> Void)?

    var url = URL(filePath: "/") {
        didSet { pathControl.url = url }
    }

    private let pathControl = NSPathControl()
    private let field = NSTextField()

    init() {
        super.init(frame: .zero)
        pathControl.pathStyle = .standard
        pathControl.focusRingType = .none
        pathControl.backgroundColor = .clear
        pathControl.target = self
        pathControl.action = #selector(pathClicked)

        field.isHidden = true
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "输入路径，Tab 补全，回车前往"
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        field.delegate = self
        // 输入的撤销不要混进文件操作的撤销历史（窗口的撤销管理器是共用的）
        field.cell?.allowsUndo = false

        let separator = NSBox()
        separator.boxType = .separator

        // 右键：拷贝路径、编辑路径
        let contextMenu = NSMenu()
        let copyItem = NSMenuItem(title: "拷贝当前文件夹路径", action: #selector(copyPathClicked), keyEquivalent: "")
        copyItem.target = self
        let editItem = NSMenuItem(title: "编辑路径", action: #selector(editClicked), keyEquivalent: "")
        editItem.target = self
        contextMenu.addItem(copyItem)
        contextMenu.addItem(editItem)
        menu = contextMenu
        pathControl.menu = contextMenu

        for subview in [pathControl, field, separator] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            pathControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pathControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pathClicked() {
        if let target = pathControl.clickedPathItem?.url {
            onNavigate?(target)
        } else {
            beginEditing()
        }
    }

    override func mouseDown(with event: NSEvent) {
        beginEditing()
    }

    @objc private func copyPathClicked() {
        onCopyPath?()
    }

    @objc private func editClicked() {
        beginEditing()
    }

    func beginEditing() {
        // 末尾带 /，按 → 后可以直接接着输入子目录
        var text = (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        if !text.hasSuffix("/") { text += "/" }
        field.stringValue = text
        pathControl.isHidden = true
        field.isHidden = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        onBeginEditing?()
    }

    private func endEditing() {
        guard !field.isHidden else { return }
        // 先切回面包屑，再交出焦点，避免 controlTextDidEndEditing 重复处理
        field.isHidden = true
        pathControl.isHidden = false
        onEndEditing?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if onSubmit?(textView.string) == true {
                endEditing()
            } else {
                NSSound.beep()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            // 文本框里 Esc 默认触发 complete:
            endEditing()
            return true
        case #selector(NSResponder.insertTab(_:)):
            if let completed = completer?(textView.string) {
                textView.string = completed
                textView.setSelectedRange(NSRange(location: (completed as NSString).length, length: 0))
            } else {
                NSSound.beep()
            }
            return true
        default:
            return false
        }
    }

    /// 点到别处时退出编辑
    func controlTextDidEndEditing(_ notification: Notification) {
        guard !field.isHidden else { return }
        field.isHidden = true
        pathControl.isHidden = false
    }
}
