import AppKit
import HarborCore

/// ⌘K 命令面板：命令直接取自主菜单，菜单里加了什么这里就有什么。
/// 打开时先按当前焦点校验一遍菜单，只列出可用的项目。支持拼音全拼和首字母。
@MainActor
enum CommandPalette {
    private struct Command {
        let item: NSMenuItem
        let title: String
        let menuTitle: String
        let shortcut: String?
    }

    static func show(in window: NSWindow) {
        // 已经开着面板时它是 key window，菜单会按面板校验；先关掉，焦点回到主窗口再收集
        QuickPanel.current?.close()
        let commands = collect(NSApp.mainMenu, in: window)
        QuickPanel.show(in: window, placeholder: "输入命令（支持拼音首字母，如 xjwjj）", footer: "↩ 执行　　esc 关闭") { query in
            rank(commands, query).map { command, positions in
                QuickPanelItem(
                    title: command.title,
                    highlights: positions,
                    subtitle: nil,
                    detail: [command.item.state == .on ? "✓" : nil, command.menuTitle, command.shortcut]
                        .compactMap { $0 }.joined(separator: "　"),
                    icon: NSImage(systemSymbolName: "command", accessibilityDescription: nil)
                ) { _ in
                    ResponderChain.send(command.item.action!, to: command.item.target, from: command.item, in: window)
                }
            }
        }
    }

    /// 按 window 的响应链校验每个菜单项，不依赖当前哪个窗口是 key（菜单自己的校验只看 key window）
    private static func collect(_ menu: NSMenu?, under menuTitle: String = "", in window: NSWindow) -> [Command] {
        guard let menu else { return [] }
        var commands: [Command] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let submenu = item.submenu {
                commands += collect(submenu, under: menuTitle.isEmpty ? item.title : menuTitle, in: window)
                continue
            }
            guard let action = item.action, action != #selector(MainWindowController.showCommandPalette(_:)),
                  ResponderChain.validate(item, in: window) else { continue }
            commands.append(Command(item: item, title: item.title, menuTitle: menuTitle, shortcut: shortcut(of: item)))
        }
        return commands
    }

    /// 标题命中优先；拼音命中不高亮（位置对不上原文）
    private static func rank(_ commands: [Command], _ query: String) -> [(Command, [Int])] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return commands.map { ($0, []) } }
        var scored: [(command: Command, score: Int, positions: [Int], order: Int)] = []
        for (order, command) in commands.enumerated() {
            var best: (Int, [Int])?
            if let match = FuzzyMatcher.match(query, in: command.title) {
                best = (match.score + 10, match.positions)
            }
            if let keys = PinyinKeys.make(command.title) {
                for key in [keys.initials, keys.full] {
                    if let match = FuzzyMatcher.match(query, in: key), match.score > (best?.0 ?? .min) {
                        best = (match.score, [])
                    }
                }
            }
            if best == nil, let match = FuzzyMatcher.match(query, in: command.menuTitle + " " + command.title) {
                best = (match.score - 10, [])
            }
            if let best { scored.append((command, best.0, best.1, order)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.map { ($0.command, $0.positions) }
    }

    /// 菜单快捷键的显示文字，例如 ⌥⌘C、F5、⌘⌫
    static func shortcut(of item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard let scalar = key.unicodeScalars.first else { return nil }
        var modifiers = item.keyEquivalentModifierMask
        let symbol: String
        switch Int(scalar.value) {
        case 0x08, 0x7F: symbol = "⌫"
        case 0x09: symbol = "⇥"
        case 0x0D: symbol = "↩"
        case 0x1B: symbol = "⎋"
        case NSUpArrowFunctionKey: symbol = "↑"
        case NSDownArrowFunctionKey: symbol = "↓"
        case NSLeftArrowFunctionKey: symbol = "←"
        case NSRightArrowFunctionKey: symbol = "→"
        case NSF1FunctionKey...NSF35FunctionKey: symbol = "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
        default:
            // 大写字母和 { } 这类符号本身就隐含了 ⇧
            let shifted: [String: String] = ["{": "[", "}": "]", "|": "\\"]
            if let base = shifted[key] {
                modifiers.insert(.shift)
                symbol = base
            } else {
                if key != key.lowercased() { modifiers.insert(.shift) }
                symbol = key.uppercased()
            }
        }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + symbol
    }
}

/// ⌘P 快速跳转：在访问过的目录里模糊查找，按访问频率和最近程度排序
@MainActor
enum QuickJump {
    static func show(for controller: MainWindowController) {
        guard let window = controller.window else { return }
        QuickPanel.current?.close()
        let current = controller.activeBrowser.currentURL.pathKey
        QuickPanel.show(in: window, placeholder: "跳转到访问过的文件夹", footer: "↩ 前往　　⌘↩ 在新标签页打开　　esc 关闭") { query in
            var missing: [String] = []
            var items: [QuickPanelItem] = []
            for result in JumpRanking.rank(query, in: RecentPlaces.shared.store, limit: 60) where result.path != current {
                guard AppDelegate.isDirectory(URL(filePath: result.path)) else {
                    missing.append(result.path)
                    continue
                }
                let url = URL(filePath: result.path, directoryHint: .isDirectory)
                let name = result.path == "/" ? "/" : (result.path as NSString).lastPathComponent
                let parent = (url.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
                let icon = NSWorkspace.shared.icon(forFile: result.path)
                icon.size = NSSize(width: 22, height: 22)
                items.append(QuickPanelItem(title: name, highlights: result.namePositions,
                                            subtitle: result.path == "/" ? nil : parent, icon: icon) { [weak controller] alternate in
                    guard let controller else { return }
                    if alternate {
                        controller.openTab(url, select: true)
                    } else {
                        controller.activeBrowser.navigate(to: url)
                        controller.activeBrowser.focusList()
                    }
                })
                if items.count == 30 { break }
            }
            // 父目录还在、自己没了，才算真删掉了；外接盘、网络盘没挂上时只是暂不显示
            let deleted = missing.filter { AppDelegate.isDirectory(URL(filePath: $0).deletingLastPathComponent()) }
            if !deleted.isEmpty {
                Task { @MainActor in deleted.forEach(RecentPlaces.shared.forget) }
            }
            return items
        }
    }
}

/// 把动作发给窗口的响应链。窗口是 key 时走 NSApp.sendAction；
/// 不是 key 时（调试脚本从后台启动、系统不让它成为前台）按 AppKit 的规则手动走一遍，含 supplementalTarget。
@MainActor
enum ResponderChain {
    @discardableResult
    static func send(_ action: Selector, to target: Any? = nil, from sender: Any? = nil, in window: NSWindow) -> Bool {
        if target != nil || NSApp.keyWindow === window {
            return NSApp.sendAction(action, to: target, from: sender)
        }
        guard let resolved = self.target(for: action, in: window) else { return false }
        _ = resolved.perform(action, with: sender)
        return true
    }

    /// 按 AppKit 的顺序找动作的接收者：第一响应者沿 nextResponder 往上（含 supplementalTarget），
    /// 走到窗口和窗口控制器；再是窗口的 delegate、NSApp、NSApp 的 delegate
    static func target(for action: Selector, in window: NSWindow) -> NSObject? {
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            if let supplemental = current.supplementalTarget(forAction: action, sender: nil) as? NSObject,
               supplemental.responds(to: action) {
                return supplemental
            }
            responder = current.nextResponder
        }
        for candidate in [window.delegate as? NSObject, NSApp, NSApp.delegate as? NSObject] {
            if let candidate, candidate.responds(to: action) { return candidate }
        }
        return nil
    }

    /// 菜单项在 window 里是否可用（顺便更新勾选状态），等同于 window 是 key window 时菜单自己的校验
    static func validate(_ item: NSMenuItem, in window: NSWindow) -> Bool {
        guard let action = item.action else { return false }
        let resolved: NSObject?
        if let explicit = item.target as? NSObject {
            resolved = explicit.responds(to: action) ? explicit : nil
        } else {
            resolved = target(for: action, in: window)
        }
        guard let resolved else { return false }
        if let validator = resolved as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = resolved as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }
}
