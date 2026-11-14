import AppKit
import Quartz

/// 空格 / ⌘Y 快速查看（Quick Look）。
/// 预览面板沿 key window 的响应链找控制者：列表有焦点时就是这一栏，双栏时跟着活动栏走
extension BrowserViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    @objc func toggleQuickLook(_ sender: Any?) {
        if Self.isQuickLookVisible {
            QLPreviewPanel.shared()?.orderOut(nil)
        } else if tableView.selectedRow >= 0 {
            QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
        }
    }

    static var isQuickLookVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    /// 选中项变了（方向键、切换目录）时刷新正在显示的预览
    func refreshQuickLook() {
        guard Self.isQuickLookVisible, let panel = QLPreviewPanel.shared(),
              (panel.dataSource as AnyObject?) === self else { return }
        panel.reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: - 数据

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = selectedURLs
        return index < urls.count ? urls[index] as NSURL : nil
    }

    // MARK: - 交互

    /// 面板在前面时：方向键继续在列表里移动选中项，空格关闭。其余按键（Esc 等）交给面板自己；
    /// ⌘Y 走菜单（动作沿主窗口的响应链仍然落到这一栏）
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // 49 = 空格，123…126 = 方向键
        guard event.type == .keyDown, event.keyCode == 49 || (123...126).contains(event.keyCode) else { return false }
        tableView.keyDown(with: event)
        return true
    }

    /// 打开 / 关闭时的缩放动画从这一行的图标位置开始
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL, let window = view.window,
              let row = items.firstIndex(where: { $0.url(in: currentURL) == url }),
              let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(Column.name.rawValue)) else { return .zero }
        let cell = tableView.frameOfCell(atColumn: tableView.column(withIdentifier: column.identifier), row: row)
        let icon = NSRect(x: cell.minX, y: cell.minY, width: cell.height, height: cell.height)
        guard tableView.visibleRect.intersects(icon) else { return .zero }
        return window.convertToScreen(tableView.convert(icon, to: nil))
    }
}
