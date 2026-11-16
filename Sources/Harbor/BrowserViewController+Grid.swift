import AppKit
import HarborCore

/// 图标视图。选中状态以列表（tableView）为准：网格的选中同步到列表，
/// 所以拷贝、删除、压缩、快速查看、打开方式这些读列表选中项的功能在网格里照常工作
extension BrowserViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func configureGrid() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = FileGridItem.size
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        gridView.collectionViewLayout = layout
        gridView.register(FileGridItem.self, forItemWithIdentifier: FileGridItem.identifier)
        gridView.register(GridGroupHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                          withIdentifier: GridGroupHeader.identifier)
        layout.sectionHeadersPinToVisibleBounds = true
        gridView.isSelectable = true
        gridView.allowsMultipleSelection = true
        gridView.allowsEmptySelection = true
        gridView.backgroundColors = [.clear]
        gridView.dataSource = self
        gridView.delegate = self
        gridView.registerForDraggedTypes([.fileURL])
        gridView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        gridView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        gridView.menu = tableView.menu
        gridView.onReturn = { [weak self] in self?.beginRename() }
        gridView.onSpace = { [weak self] in self?.toggleQuickLook(nil) }
        gridView.onFocus = { [weak self] in
            guard let self else { return }
            delegate?.browserDidBecomeActive(self)
        }
        gridView.onTab = { [weak self] in
            guard let self else { return false }
            return delegate?.browserRequestsPaneSwitch(self) ?? false
        }
        gridView.onDoubleClick = { [weak self] indexPath in
            guard let self, let index = itemIndex(for: indexPath) else { return }
            let inNewTabs = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            let selection = selectedItemIndexes
            open(rows: selection.contains(index) ? selection : [index], foldersInNewTabs: inNewTabs)
        }
        gridScroll.documentView = gridView
        gridScroll.hasVerticalScroller = true
        gridScroll.autohidesScrollers = true
        gridScroll.drawsBackground = false
        gridScroll.isHidden = true
    }

    @objc func showAsIcons(_ sender: Any?) { Preferences.viewMode = .icons }
    @objc func showAsList(_ sender: Any?) { Preferences.viewMode = .list }

    /// 「分组方式」菜单项：tag 是 FileGrouping.allCases 的下标
    @objc func setGrouping(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, FileGrouping.allCases.indices.contains(tag) else { return }
        Preferences.grouping = FileGrouping.allCases[tag]
    }

    static func groupingMenuItems() -> [NSMenuItem] {
        FileGrouping.allCases.enumerated().flatMap { index, grouping -> [NSMenuItem] in
            let item = NSMenuItem(title: grouping.title, action: #selector(setGrouping(_:)), keyEquivalent: "")
            item.tag = index
            // 和 Finder 一样，「无」和其余选项之间隔开
            return grouping == .none ? [item, .separator()] : [item]
        }
    }

    // MARK: - 分组：每组一个分区

    /// 网格位置 → items 下标
    func itemIndex(for indexPath: IndexPath) -> Int? {
        let index = groups.isEmpty ? indexPath.item
            : indexPath.section < groups.count ? groups[indexPath.section].range.lowerBound + indexPath.item : items.count
        return index < items.count ? index : nil
    }

    /// items 下标 → 网格位置
    func indexPath(forItem index: Int) -> IndexPath {
        guard !groups.isEmpty, let section = groups.firstIndex(where: { $0.range.contains(index) }) else {
            return IndexPath(item: index, section: 0)
        }
        return IndexPath(item: index - groups[section].range.lowerBound, section: section)
    }

    /// 分组时显示组标题，不分组时不留空白
    func updateGridHeaders() {
        (gridView.collectionViewLayout as? NSCollectionViewFlowLayout)?.headerReferenceSize =
            groups.isEmpty ? .zero : NSSize(width: 0, height: GridGroupHeader.height)
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        max(1, groups.count)
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GridGroupHeader.identifier, for: indexPath)
        (header as? GridGroupHeader)?.title = indexPath.section < groups.count ? groups[indexPath.section].title : ""
        return header
    }

    /// 列表 → 网格（列表的选中变化、重新加载之后）
    func syncGridFromTable(scroll: Bool) {
        let paths = Set(selectedItemIndexes.map(indexPath(forItem:)))
        if gridView.selectionIndexPaths != paths { gridView.selectionIndexPaths = paths }
        if scroll, let first = paths.min() {
            gridView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
        }
    }

    /// 网格 → 列表（用户在网格里点选、框选、方向键）
    private func syncTableFromGrid() {
        guard !isSyncingSelection else { return }
        isSyncingSelection = true
        selectItems(IndexSet(gridView.selectionIndexPaths.compactMap(itemIndex(for:))))
        isSyncingSelection = false
    }

    // MARK: - 数据

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        groups.isEmpty ? items.count : section < groups.count ? groups[section].range.count : 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: FileGridItem.identifier, for: indexPath)
        if let cell = cell as? FileGridItem, let index = itemIndex(for: indexPath) {
            cell.configure(item: items[index], in: currentURL)
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        syncTableFromGrid()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        syncTableFromGrid()
    }

    /// 重命名时用：网格里这一项的文件名标签
    func gridNameField(at index: Int) -> NSTextField? {
        let path = indexPath(forItem: index)
        gridView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        gridView.layoutSubtreeIfNeeded()
        return (gridView.item(at: path) as? FileGridItem)?.nameField
    }

    // MARK: - 拖拽

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        renamingItem == nil
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        itemIndex(for: indexPath).map { items[$0].url(in: currentURL) as NSURL }
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let index = itemIndex(for: proposedDropIndexPath.pointee as IndexPath)
        // 不是落在文件夹上：当作放进当前文件夹（不在两项之间画插入线）
        if proposedDropOperation.pointee != .on || index.map({ !items[$0].isFolder }) ?? true {
            proposedDropOperation.pointee = .before
        }
        return validatedDropOperation(draggingInfo, target: gridDropTarget(index: index, operation: proposedDropOperation.pointee))
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        performFileDrop(draggingInfo, target: gridDropTarget(index: itemIndex(for: indexPath), operation: dropOperation))
    }

    private func gridDropTarget(index: Int?, operation: NSCollectionView.DropOperation) -> URL {
        if operation == .on, let index, items[index].isFolder {
            return items[index].url(in: currentURL)
        }
        return currentURL
    }
}
