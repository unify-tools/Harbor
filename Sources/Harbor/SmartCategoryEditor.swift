import AppKit
import HarborCore

/// 新建 / 编辑智能分类：名称、文件名包含、类型、时间条件、智能更新
@MainActor
enum SmartCategoryEditor {
    static func create(in window: NSWindow, completion: @escaping (SmartCategory) -> Void) {
        present(SmartCategory(name: "", query: SmartQuery()), isNew: true, in: window, completion: completion)
    }

    static func edit(_ category: SmartCategory, in window: NSWindow, completion: @escaping (SmartCategory) -> Void) {
        present(category, isNew: false, in: window, completion: completion)
    }

    private static func present(_ category: SmartCategory, isNew: Bool, in window: NSWindow,
                                completion: @escaping (SmartCategory) -> Void) {
        let form = Form(category)
        let alert = NSAlert()
        alert.messageText = isNew ? "新建智能分类" : "编辑智能分类"
        alert.informativeText = "符合条件的文件会自动归到这个分类里（在主目录下的文件夹中查找）。"
        alert.accessoryView = form.view
        alert.addButton(withTitle: isNew ? "创建" : "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = form.name
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            completion(form.result)
        }
    }

    /// 表单。名称留空时按条件自动起名
    @MainActor
    final class Form {
        let name = NSTextField()
        let keyword = NSTextField()
        let kind = NSPopUpButton()
        let dateField = NSPopUpButton()
        let range = NSPopUpButton()
        let autoUpdate = NSButton(checkboxWithTitle: "智能更新（文件变化时自动刷新）", target: nil, action: nil)
        let view: NSView
        private let original: SmartCategory

        init(_ category: SmartCategory) {
            original = category
            name.placeholderString = "留空则按条件命名"
            name.stringValue = category.name
            keyword.placeholderString = "不限"
            keyword.stringValue = category.query.keyword
            kind.addItems(withTitles: ["任意类型"] + SmartQuery.Kind.allCases.map(\.title))
            if let first = category.query.kinds.first, let index = SmartQuery.Kind.allCases.firstIndex(of: first) {
                kind.selectItem(at: index + 1)
            }
            dateField.addItems(withTitles: SmartQuery.DateField.allCases.map(\.title))
            dateField.selectItem(at: SmartQuery.DateField.allCases.firstIndex(of: category.query.dateField) ?? 0)
            range.addItems(withTitles: SmartQuery.DateRange.allCases.map(\.title))
            range.selectItem(at: SmartQuery.DateRange.allCases.firstIndex(of: category.query.range) ?? 0)
            autoUpdate.state = category.autoUpdate ? .on : .off

            let dateRow = NSStackView(views: [dateField, range])
            let grid = NSGridView(views: [
                [Self.label("名称"), name],
                [Self.label("文件名包含"), keyword],
                [Self.label("类型"), kind],
                [Self.label("时间"), dateRow],
                [NSGridCell.emptyContentView, autoUpdate],
            ])
            grid.rowSpacing = 8
            grid.columnSpacing = 8
            grid.column(at: 0).xPlacement = .trailing
            grid.rowAlignment = .firstBaseline
            name.widthAnchor.constraint(equalToConstant: 240).isActive = true
            keyword.widthAnchor.constraint(equalToConstant: 240).isActive = true
            grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
            view = grid
        }

        var result: SmartCategory {
            let kinds = kind.indexOfSelectedItem > 0 ? [SmartQuery.Kind.allCases[kind.indexOfSelectedItem - 1]] : []
            let query = SmartQuery(keyword: keyword.stringValue, kinds: kinds, tag: original.query.tag,
                                   dateField: SmartQuery.DateField.allCases[max(0, dateField.indexOfSelectedItem)],
                                   range: SmartQuery.DateRange.allCases[max(0, range.indexOfSelectedItem)])
            var category = original
            category.query = query
            category.autoUpdate = autoUpdate.state == .on
            let typed = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            category.name = typed.isEmpty ? Self.automaticName(for: query) : typed
            return category
        }

        /// 「近 7 天修改的图片」「名称含“报告”的文档」
        static func automaticName(for query: SmartQuery) -> String {
            var parts: [String] = []
            if query.range != .any { parts.append(query.range.title + query.dateField.title.replacingOccurrences(of: "日期", with: "") + "的") }
            let keyword = query.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            if !keyword.isEmpty { parts.append("名称含“\(keyword)”的") }
            parts.append(query.kinds.first?.title ?? "文件")
            return parts.joined()
        }

        private static func label(_ text: String) -> NSTextField {
            NSTextField(labelWithString: text + "：")
        }
    }
}
