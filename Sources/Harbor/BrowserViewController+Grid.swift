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
        gridView.onDoubleClick = { [weak self] index in
            guard let self else { return }
            let inNewTabs = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            let selection = tableView.selectedRowIndexes
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

    /// 列表 → 网格（列表的选中变化、重新加载之后）
    func syncGridFromTable(scroll: Bool) {
        let paths = Set(tableView.selectedRowIndexes.filter { $0 < gridView.numberOfItems(inSection: 0) }.map { IndexPath(item: $0, section: 0) })
        if gridView.selectionIndexPaths != paths { gridView.selectionIndexPaths = paths }
        if scroll, let first = paths.min() {
            gridView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
        }
    }

    /// 网格 → 列表（用户在网格里点选、框选、方向键）
    private func syncTableFromGrid() {
        guard !isSyncingSelection else { return }
        isSyncingSelection = true
        tableView.selectRowIndexes(IndexSet(gridView.selectionIndexPaths.map(\.item)), byExtendingSelection: false)
        isSyncingSelection = false
    }

    // MARK: - 数据

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: FileGridItem.identifier, for: indexPath)
        if let cell = cell as? FileGridItem, indexPath.item < items.count {
            cell.configure(item: items[indexPath.item], in: currentURL)
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
        let path = IndexPath(item: index, section: 0)
        gridView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        gridView.layoutSubtreeIfNeeded()
        return (gridView.item(at: path) as? FileGridItem)?.nameField
    }

    // MARK: - 拖拽

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        renamingItem == nil
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        indexPath.item < items.count ? items[indexPath.item].url(in: currentURL) as NSURL : nil
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let index = proposedDropIndexPath.pointee.item
        // 不是落在文件夹上：当作放进当前文件夹（不在两项之间画插入线）
        if proposedDropOperation.pointee != .on || index >= items.count || !items[index].isFolder {
            proposedDropOperation.pointee = .before
        }
        return validatedDropOperation(draggingInfo, target: gridDropTarget(index: index, operation: proposedDropOperation.pointee))
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        performFileDrop(draggingInfo, target: gridDropTarget(index: indexPath.item, operation: dropOperation))
    }

    private func gridDropTarget(index: Int, operation: NSCollectionView.DropOperation) -> URL {
        if operation == .on, index < items.count, items[index].isFolder {
            return items[index].url(in: currentURL)
        }
        return currentURL
    }
}
