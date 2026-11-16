import AppKit
import HarborCore

extension NSPasteboard.PasteboardType {
    /// ⌘X 剪切的标记：粘贴时改为移动
    static let harborCut = NSPasteboard.PasteboardType("dev.lakes.harbor.cut")
}

/// 浏览区的文件操作：剪贴板、新建、重命名、废纸篓、拖拽、右键菜单
extension BrowserViewController: NSMenuItemValidation, NSMenuDelegate, NSTextFieldDelegate {
    func configureFileOperations() {
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .regular
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
    }

    var selectedURLs: [URL] {
        selectedItemIndexes.compactMap { $0 < items.count ? items[$0].url(in: currentURL) : nil }
    }

    // MARK: - 剪贴板（和 Finder 互通：写的是文件 URL）

    @objc func copy(_ sender: Any?) {
        writeToPasteboard(selectedURLs, cut: false)
    }

    @objc func cut(_ sender: Any?) {
        writeToPasteboard(selectedURLs, cut: true)
    }

    /// ⌘V：拷贝；如果之前是 ⌘X 剪切的，就移动
    @objc func paste(_ sender: Any?) {
        guard let urls = pasteboardURLs() else { return }
        let isCut = NSPasteboard.general.types?.contains(.harborCut) == true
        startTransfer(isCut ? .move : .copy, urls, to: currentURL)
        if isCut { NSPasteboard.general.clearContents() }
    }

    /// ⌥⌘V：移动到这里（Finder 的做法）
    @objc func pasteMove(_ sender: Any?) {
        guard let urls = pasteboardURLs() else { return }
        startTransfer(.move, urls, to: currentURL)
        NSPasteboard.general.clearContents()
    }

    /// ⌥⌘C：拷贝所选项目的路径，每行一个；没有选中项时拷贝当前文件夹的路径
    @objc func copyPath(_ sender: Any?) {
        let urls = selectedURLs
        writePaths(urls.isEmpty ? [currentURL] : urls)
    }

    /// ⌥⇧⌘C：拷贝当前文件夹的路径
    @objc func copyCurrentPath(_ sender: Any?) {
        guard !isVirtual else { return }
        writePaths([currentURL])
    }

    func writePaths(_ urls: [URL]) {
        let paths = urls.map(\.pathKey)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func writeToPasteboard(_ urls: [URL], cut: Bool) {
        guard !urls.isEmpty else { return }
        let entries = urls.enumerated().map { index, url in
            let entry = NSPasteboardItem()
            entry.setString(url.absoluteString, forType: .fileURL)
            if cut, index == 0 { entry.setData(Data(), forType: .harborCut) }
            return entry
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(entries)
    }

    private func pasteboardURLs() -> [URL]? {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }

    // MARK: - 操作

    @objc func openFromMenu(_ sender: Any?) {
        openSelection()
    }

    // MARK: - 压缩、解压

    @objc func compressZip(_ sender: Any?) { compressSelection(.zip) }
    @objc func compressTarGz(_ sender: Any?) { compressSelection(.tarGz) }
    @objc func compressTarXz(_ sender: Any?) { compressSelection(.tarXz) }
    @objc func compress7z(_ sender: Any?) { compressSelection(.sevenZip) }

    private func compressSelection(_ format: ArchiveFormat) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let directory = currentURL
        Task {
            switch await FileOperationCenter.shared.compress(urls, format: format, in: directory) {
            case .success(let archive):
                if directory.pathKey == currentURL.pathKey { reload(selecting: [archive.lastPathComponent], isNavigation: false) }
            case .failure(let error):
                presentArchiveError(error, url: urls[0], title: "无法压缩")
            }
        }
    }

    /// 所选的压缩包逐个解压到当前文件夹
    @objc func extractSelection(_ sender: Any?) {
        extract(selectedURLs.filter(Archives.isExtractable))
    }

    func extract(_ archives: [URL]) {
        guard !archives.isEmpty else { return }
        let directory = currentURL
        Task {
            var outputs: [String] = []
            for archive in archives {
                switch await FileOperationCenter.shared.extract(archive, into: directory, presenter: self) {
                case .success(let result):
                    outputs.append(result.output.lastPathComponent)
                    if !result.skipped.isEmpty {
                        let lines = result.skipped.prefix(5).joined(separator: "\n") + (result.skipped.count > 5 ? "\n……另有 \(result.skipped.count - 5) 项" : "")
                        presentErrors([FileOperationError(url: archive, message: "以下条目路径不安全或无法写入，已跳过：\n" + lines)],
                                      title: "「\(archive.lastPathComponent)」部分内容未解压")
                    }
                case .failure(.cancelled):
                    break
                case .failure(let error):
                    presentArchiveError(error, url: archive, title: "无法解压「\(archive.lastPathComponent)」")
                }
            }
            if !outputs.isEmpty, directory.pathKey == currentURL.pathKey {
                reload(selecting: outputs, isNavigation: false)
            }
        }
    }

    /// 压缩包用默认应用打开（双击默认是解压）
    @objc func openWithDefaultApp(_ sender: Any?) {
        selectedURLs.forEach { NSWorkspace.shared.open($0) }
    }

    private func presentArchiveError(_ error: ArchiveError, url: URL, title: String) {
        guard error != .cancelled else { return }
        presentErrors([FileOperationError(url: url, message: error.message)], title: title)
    }

    private var selectionHasArchive: Bool {
        selectedURLs.contains(where: Archives.isExtractable)
    }

    /// 所选的文件夹各开一个新标签页
    @objc func openInNewTab(_ sender: Any?) {
        open(rows: selectedItemIndexes, foldersInNewTabs: true)
    }

    private var selectionHasFolder: Bool {
        selectedItemIndexes.contains { $0 < items.count && folderTarget(for: items[$0]) != nil }
    }

    /// ⌘D：在原地生成副本
    @objc func duplicate(_ sender: Any?) {
        startTransfer(.copy, selectedURLs, to: currentURL)
    }

    @objc func moveToTrash(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let next = nameAfterSelection()
        Task {
            let errors = await FileOperationCenter.shared.trash(urls)
            reload(selecting: next.map { [$0] } ?? [], isNavigation: false)
            presentErrors(errors, title: "部分项目未能移到废纸篓")
        }
    }

    @objc func deleteImmediately(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = urls.count == 1 ? "要立即删除「\(urls[0].lastPathComponent)」吗？" : "要立即删除这 \(urls.count) 项吗？"
        alert.informativeText = "此操作无法撤销。"
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        let next = nameAfterSelection()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                let errors = await FileOperationCenter.shared.delete(urls)
                self?.reload(selecting: next.map { [$0] } ?? [], isNavigation: false)
                self?.presentErrors(errors, title: "部分项目未能删除")
            }
        }
    }

    @objc func newFolder(_ sender: Any?) {
        Task {
            switch await FileOperationCenter.shared.createFolder(in: currentURL, name: "未命名文件夹") {
            case .success(let folder):
                pendingRenameName = folder.lastPathComponent
                reload(selecting: [folder.lastPathComponent], isNavigation: false)
            case .failure(let error):
                presentErrors([error], title: "无法新建文件夹")
            }
        }
    }

    @objc func renameSelection(_ sender: Any?) {
        beginRename()
    }

    /// 删除后选中原选区后面的第一项，方便连续操作
    private func nameAfterSelection() -> String? {
        let selected = selectedItemIndexes
        guard let last = selected.last else { return nil }
        if let after = (last + 1..<items.count).first(where: { !selected.contains($0) }) { return items[after].name }
        if let before = (0..<last).reversed().first(where: { !selected.contains($0) }) { return items[before].name }
        return nil
    }

    /// completion 拿到成功落地的项目（双栏互拷时让另一栏选中它们）
    func startTransfer(_ mode: TransferMode, _ sources: [URL], to destination: URL, completion: (([URL]) -> Void)? = nil) {
        guard !sources.isEmpty else { return }
        Task {
            let result = await FileOperationCenter.shared.transfer(mode, sources: sources, to: destination, presenter: self)
            if destination.pathKey == currentURL.pathKey, !result.destinations.isEmpty {
                reload(selecting: result.destinations.map(\.lastPathComponent), isNavigation: false)
            }
            if !result.destinations.isEmpty { completion?(result.destinations) }
            presentErrors(result.errors, title: mode == .copy ? "部分项目未能拷贝" : "部分项目未能移动")
        }
    }

    func presentErrors(_ errors: [FileOperationError], title: String) {
        let shown = errors.filter { !$0.isCancellation }
        guard !shown.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = title
        var lines = shown.prefix(5).map(\.description)
        if shown.count > 5 { lines.append("……另有 \(shown.count - 5) 项") }
        alert.informativeText = lines.joined(separator: "\n")
        if let window = view.window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - 行内重命名

    /// 回车或「重命名」：在名称列里直接编辑，默认选中不含扩展名的部分
    func beginRename() {
        guard renamingItem == nil, selectedItemIndexes.count == 1,
              let index = selectedItemIndexes.first, index < items.count else { return }
        let field: NSTextField
        if viewMode == .icons {
            guard let gridField = gridNameField(at: index) else { return }
            field = gridField
        } else {
            let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.name.rawValue))
            guard column >= 0 else { return }
            let row = row(forItem: index)
            tableView.scrollRowToVisible(row)
            guard let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let cellField = cell.textField else { return }
            field = cellField
        }

        let item = items[index]
        renamingItem = item
        renamingField = field
        field.isEditable = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        // 编辑过程的输入撤销不要混进文件操作的撤销历史
        field.cell?.allowsUndo = false
        field.delegate = self
        view.window?.makeFirstResponder(field)

        let name = item.name as NSString
        let baseLength = item.isFolder ? name.length : (name.deletingPathExtension as NSString).length
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: baseLength > 0 ? baseLength : name.length)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === renamingField, let item = renamingItem else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.complete(_:)) {
            // Esc：恢复原名并结束编辑
            renamingField?.stringValue = item.name
            focusList()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === renamingField, let item = renamingItem else { return }
        let newName = field.stringValue
        field.isEditable = false
        field.drawsBackground = false
        field.delegate = nil
        renamingItem = nil
        renamingField = nil
        // 回车结束时焦点回到列表；点到别处结束时不抢焦点
        if (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue {
            focusList()
        }

        guard newName != item.name else {
            finishRename()
            return
        }
        if let problem = FileNaming.validationError(forNewName: newName) {
            field.stringValue = item.name
            presentErrors([FileOperationError(url: item.url(in: currentURL), message: problem)], title: "无法重命名")
            finishRename()
            return
        }
        let url = item.url(in: currentURL)
        Task {
            switch await FileOperationCenter.shared.rename(url, to: newName) {
            case .success(let renamed):
                reload(selecting: [renamed.lastPathComponent], isNavigation: false)
            case .failure(let error):
                field.stringValue = item.name
                presentErrors([error], title: "无法重命名")
                finishRename()
            }
        }
    }

    private func finishRename() {
        if refreshPending { reload(selecting: nil, isNavigation: false) }
    }

    // MARK: - 拖拽

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let index = itemIndex(forRow: row), renamingItem == nil else { return nil }
        return items[index].url(in: currentURL) as NSURL
    }


    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let target = dropTarget(row: row, dropOperation: dropOperation)
        if target.pathKey == currentURL.pathKey {
            // 不是落在文件夹上：整个列表作为目标
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return validatedDropOperation(info, target: target)
    }

    /// 列表和网格共用：拖进 target 时用什么操作，[] 表示不接受
    func validatedDropOperation(_ info: any NSDraggingInfo, target: URL) -> NSDragOperation {
        let sources = draggedURLs(info)
        guard !sources.isEmpty, !isVirtual else { return [] }
        if sources.contains(where: { $0.pathKey == target.pathKey }) { return [] }
        let operation = dragOperation(for: info, sources: sources, target: target)
        // 在同一个目录里拖来拖去不算移动
        if operation == .move, sources.allSatisfy({ $0.deletingLastPathComponent().pathKey == target.pathKey }) {
            return []
        }
        return operation
    }

    func performFileDrop(_ info: any NSDraggingInfo, target: URL) -> Bool {
        let sources = draggedURLs(info)
        let operation = validatedDropOperation(info, target: target)
        guard !sources.isEmpty, !operation.isEmpty else { return false }
        startTransfer(operation == .copy ? .copy : .move, sources, to: target)
        return true
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        performFileDrop(info, target: dropTarget(row: row, dropOperation: dropOperation))
    }

    private func dropTarget(row: Int, dropOperation: NSTableView.DropOperation) -> URL {
        if dropOperation == .on, let index = itemIndex(forRow: row), items[index].isFolder {
            return items[index].url(in: currentURL)
        }
        return currentURL
    }

    private func draggedURLs(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// 和 Finder 一样：同一卷默认移动，跨卷默认拷贝；按住 ⌥ 拷贝，按住 ⌘ 移动
    private func dragOperation(for info: any NSDraggingInfo, sources: [URL], target: URL) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        if mask == .copy { return .copy }
        if mask == .generic { return .move }
        let targetVolume = volumeIdentifier(target)
        let sameVolume = targetVolume != nil && sources.allSatisfy { volumeIdentifier($0)?.isEqual(targetVolume) == true }
        if sameVolume, mask.contains(.move) { return .move }
        if mask.contains(.copy) { return .copy }
        if mask.contains(.move) || mask.contains(.generic) { return .move }
        return []
    }

    private func volumeIdentifier(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    // MARK: - 右键菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // 右键点中的条目（items 下标），-1 表示空白处或组标题
        let row = (viewMode == .icons ? gridView.clickedIndexPath.flatMap(itemIndex(for:)) : itemIndex(forRow: tableView.clickedRow)) ?? -1
        // 右键点在未选中的行上：改为选中这一行；点在空白处：取消选择
        if row >= 0, !selectedItemIndexes.contains(row) {
            selectItems([row])
        } else if row < 0 {
            tableView.deselectAll(nil)
        }
        populateContextMenu(menu, row: row)
    }

    /// 右键菜单的内容。row < 0 表示点在空白处（拆出来方便调试脚本检查）
    func populateContextMenu(_ menu: NSMenu, row: Int) {
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if row >= 0 {
            add("打开", #selector(openFromMenu(_:)))
            let openWith = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
            openWith.submenu = makeOpenWithMenu(for: selectedURLs)
            menu.addItem(openWith)
            if selectionHasFolder { add("在新标签页中打开", #selector(openInNewTab(_:))) }
            if selectedItemIndexes.count == 1, selectionHasFolder {
                add(QuickAccessStore.shared.contains(selectedURLs[0]) ? "从快速访问移除" : "添加至快速访问", #selector(toggleQuickAccess(_:)))
            }
            if selectionHasArchive {
                add("解压", #selector(extractSelection(_:)))
                add("用默认应用打开", #selector(openWithDefaultApp(_:)))
            }
            menu.addItem(.separator())
            add("重命名", #selector(renameSelection(_:)))
            add("复制", #selector(duplicate(_:)))
            add("压缩为 ZIP", #selector(compressZip(_:)))
            add("拷贝", #selector(copy(_:)))
            add("剪切", #selector(cut(_:)))
            add("拷贝路径", #selector(copyPath(_:)))
            menu.addItem(.separator())
            add("移到废纸篓", #selector(moveToTrash(_:)))
        } else {
            add("新建文件夹", #selector(newFolder(_:)))
            add("新建智能分类…", #selector(newSmartCategory(_:)))
            add("粘贴", #selector(paste(_:)))
            menu.addItem(.separator())
            add("拷贝当前文件夹路径", #selector(copyCurrentPath(_:)))
        }
    }

    // MARK: - 菜单状态

    /// 正在输入文字（重命名框、地址栏、⌘K / ⌘P 面板）。这时作用于列表的菜单快捷键要禁用，
    /// 否则 ⌘⌫、⌘↓ 这类按键会先被菜单拿走，作用到文件上，而不是交给文本框
    var isEditingText: Bool {
        guard let window = view.window else { return true }
        if let key = NSApp.keyWindow, key !== window { return true }
        return Self.isTextInput(window.firstResponder)
    }

    /// 文本框的字段编辑器，或者内嵌终端
    static func isTextInput(_ responder: NSResponder?) -> Bool {
        responder is NSText || responder is HarborTerminalView
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let count = tableView.selectedRowIndexes.count
        // 预览开着时始终可用（用来关闭）。这时 key window 是预览面板，isEditingText 会误判成正在输入
        switch menuItem.action {
        case #selector(toggleQuickLook(_:)):
            return Self.isQuickLookVisible || (count > 0 && !isEditingText)
        case #selector(showAsIcons(_:)):
            menuItem.state = viewMode == .icons ? .on : .off
            return true
        case #selector(showAsList(_:)):
            menuItem.state = viewMode == .list ? .on : .off
            return true
        case #selector(newSmartCategory(_:)):
            return true
        case #selector(setGrouping(_:)):
            menuItem.state = FileGrouping.allCases.indices.contains(menuItem.tag) && FileGrouping.allCases[menuItem.tag] == grouping ? .on : .off
            return !isVirtual
        default:
            break
        }
        // 主页、分类等虚拟位置没有「当前文件夹」，文件操作都不可用（结果列表自己的拷贝等由它处理）
        if isVirtual { return false }
        if isEditingText {
            // 文本框自己处理拷贝、粘贴，到不了这里；终端没有「剪切」，会落到这里，也要禁用
            switch menuItem.action {
            case #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)), #selector(duplicate(_:)), #selector(moveToTrash(_:)), #selector(deleteImmediately(_:)),
                 #selector(openFromMenu(_:)), #selector(openInNewTab(_:)), #selector(renameSelection(_:)),
                 #selector(newFolder(_:)), #selector(pasteMove(_:)), #selector(copyPath(_:)), #selector(copyCurrentPath(_:)),
                 #selector(compressZip(_:)), #selector(compressTarGz(_:)), #selector(compressTarXz(_:)), #selector(compress7z(_:)),
                 #selector(extractSelection(_:)), #selector(openWithDefaultApp(_:)):
                return false
            default:
                break
            }
        }
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(duplicate(_:)), #selector(moveToTrash(_:)),
             #selector(deleteImmediately(_:)), #selector(openFromMenu(_:)), #selector(openWithDefaultApp(_:)),
             #selector(compressZip(_:)), #selector(compressTarGz(_:)), #selector(compressTarXz(_:)), #selector(compress7z(_:)):
            return count > 0
        case #selector(extractSelection(_:)):
            return selectionHasArchive
        case #selector(openInNewTab(_:)):
            return selectionHasFolder
        case #selector(renameSelection(_:)):
            return count == 1
        case #selector(toggleQuickAccess(_:)):
            if count == 1, selectionHasFolder {
                menuItem.title = QuickAccessStore.shared.contains(selectedURLs[0]) ? "从快速访问移除" : "添加至快速访问"
                return true
            }
            return false
        case #selector(paste(_:)), #selector(pasteMove(_:)):
            return pasteboardURLs() != nil
        default:
            return true
        }
    }

    // MARK: - 快速访问、智能分类

    @objc func toggleQuickAccess(_ sender: Any?) {
        guard selectedURLs.count == 1, let url = selectedURLs.first else { return }
        if QuickAccessStore.shared.contains(url) {
            QuickAccessStore.shared.remove(url)
        } else {
            QuickAccessStore.shared.add(url)
        }
    }

    /// 新建后直接打开这个分类
    @objc func newSmartCategory(_ sender: Any?) {
        guard let window = view.window else { return }
        SmartCategoryEditor.create(in: window) { [weak self] category in
            SmartCategoryStore.shared.save(category)
            self?.navigate(to: VirtualLocation.smart(category.id).url)
        }
    }
}
