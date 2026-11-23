import AppKit
import Combine
import SwiftUI

/// Return/Enter でのファイルオープンを備えたネイティブ NSOutlineView
/// NOTE: AppKit は NSTableView サブクラスで mouseDown:/mouseDragged: をオーバーライドすると
/// テーブル選択用ジェスチャーレコグナイザを全無効化するため、絶対にマウス系メソッドをオーバーライドしないこと。
final class KeyHandlingOutlineView: NSOutlineView {
    var onReturnPressed: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturnPressed?()
            return
        }
        super.keyDown(with: event)
    }
}

/// ダークスタジオ UI に合わせた行ハイライト描画用 NSTableRowView
final class WorkspaceOutlineRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .emphasized }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 4, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor(calibratedRed: 0.22, green: 0.52, blue: 0.85, alpha: 0.34).setFill()
        path.fill()
        NSColor(calibratedRed: 0.40, green: 0.78, blue: 1.0, alpha: 0.65).setStroke()
        path.lineWidth = 1.0
        path.stroke()
    }
}

/// SwiftUI から左ペインに埋め込む高速ネイティブ NSOutlineView
struct WorkspaceOutlineView: NSViewRepresentable {
    let store: WorkspaceBrowserStore
    let isLargeText: Bool
    let currentWorkspaceMode: () -> ViewStereoWorkspaceMode
    let isBatchRunning: () -> Bool

    let onOpenItem: (StereoBatchItem) -> Void
    let onOpenForce2D: (URL) -> Void
    let onOpenForceStereo: (URL) -> Void
    let onOpenLRPair: (URL, URL) -> Void
    let onBatchSelection: () -> Void
    let onVerifySelection: () -> Void
    let onSetRootFolder: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let outline = KeyHandlingOutlineView()
        outline.headerView = nil
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .regular
        outline.indentationPerLevel = 14
        outline.floatsGroupRows = false
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.style = .plain
        outline.autoresizingMask = [.width]
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.minWidth = 100
        column.maxWidth = 2000
        column.width = 260
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu

        outline.onReturnPressed = { [weak coordinator = context.coordinator] in
            coordinator?.openFirstSelectedRow()
        }

        scrollView.documentView = outline
        context.coordinator.outlineView = outline
        context.coordinator.bindStore(store)
        context.coordinator.syncAll(forceReload: true)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let contentWidth = nsView.contentSize.width
        if contentWidth > 0,
           let col = context.coordinator.outlineView?.tableColumns.first,
           abs(col.width - contentWidth) > 1 {
            col.width = contentWidth
        }
        context.coordinator.syncFromSwiftUIProps()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: WorkspaceOutlineView
        weak var outlineView: KeyHandlingOutlineView?

        private var lastTreeRevision: Int = -1
        private var lastSearchText: String = ""
        private var lastShowWarningsOnly: Bool = false
        private var lastViewMode: WorkspaceBrowserViewMode = .compactList
        private var lastIsLargeText: Bool = false
        private var lastActiveItemID: String? = nil
        private var lastItemStatuses: [String: WorkspaceItemStatus] = [:]

        private var isSyncingSelectionFromOutline = false
        private var isSyncingSelectionFromStore = false
        private var isSyncingExpansion = false
        private var cancellables = Set<AnyCancellable>()

        init(parent: WorkspaceOutlineView) {
            self.parent = parent
        }

        func bindStore(_ store: WorkspaceBrowserStore) {
            cancellables.removeAll()

            Publishers.Merge4(
                store.$treeRevision.dropFirst().map { _ in () },
                store.$searchText.dropFirst().map { _ in () },
                store.$showWarningsOnly.dropFirst().map { _ in () },
                store.$viewMode.dropFirst().map { _ in () }
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.syncAll(forceReload: false)
            }
            .store(in: &cancellables)

            store.$selectedNodeIDs
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, !self.isSyncingSelectionFromOutline, let outline = self.outlineView else { return }
                    self.applyStoreSelection(to: outline)
                }
                .store(in: &cancellables)

            Publishers.Merge(
                store.$activeItemID.dropFirst().map { _ in () },
                store.$itemStatuses.dropFirst().map { _ in () }
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, let outline = self.outlineView else { return }
                let s = self.parent.store
                if self.lastActiveItemID != s.activeItemID || self.lastItemStatuses != s.itemStatuses {
                    self.lastActiveItemID = s.activeItemID
                    self.lastItemStatuses = s.itemStatuses
                    self.refreshVisibleRowStates(in: outline)
                }
            }
            .store(in: &cancellables)
        }

        func syncFromSwiftUIProps() {
            if lastIsLargeText != parent.isLargeText {
                syncAll(forceReload: false)
            }
        }

        func syncAll(forceReload: Bool) {
            guard let outline = outlineView else { return }
            let store = parent.store

            let needsReload = forceReload
                || lastTreeRevision != store.treeRevision
                || lastSearchText != store.searchText
                || lastShowWarningsOnly != store.showWarningsOnly
                || lastViewMode != store.viewMode
                || lastIsLargeText != parent.isLargeText

            if needsReload {
                lastTreeRevision = store.treeRevision
                lastSearchText = store.searchText
                lastShowWarningsOnly = store.showWarningsOnly
                lastViewMode = store.viewMode
                lastIsLargeText = parent.isLargeText
                lastActiveItemID = store.activeItemID
                lastItemStatuses = store.itemStatuses

                isSyncingExpansion = true
                outline.reloadData()
                restoreExpansion(in: outline, nodes: store.rootNodes())
                isSyncingExpansion = false

                applyStoreSelection(to: outline)
                return
            }

            if !isSyncingSelectionFromOutline {
                applyStoreSelection(to: outline)
            }

            if lastActiveItemID != store.activeItemID || lastItemStatuses != store.itemStatuses {
                lastActiveItemID = store.activeItemID
                lastItemStatuses = store.itemStatuses
                refreshVisibleRowStates(in: outline)
            }
        }

        private func restoreExpansion(in outline: NSOutlineView, nodes: [WorkspaceBrowserNode]) {
            let expanded = parent.store.expandedFolderIDs
            let filterActive = !parent.store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parent.store.showWarningsOnly
            for node in nodes where node.isDirectory {
                if expanded.contains(node.id) || (filterActive && !parent.store.childNodes(of: node).isEmpty) {
                    outline.expandItem(node)
                    restoreExpansion(in: outline, nodes: parent.store.childNodes(of: node))
                }
            }
        }

        private func applyStoreSelection(to outline: NSOutlineView) {
            let storeIDs = parent.store.selectedNodeIDs
            var currentIDs = Set<String>()
            outline.selectedRowIndexes.forEach { row in
                if let node = outline.item(atRow: row) as? WorkspaceBrowserNode {
                    currentIDs.insert(node.id)
                }
            }
            guard currentIDs != storeIDs else { return }

            isSyncingSelectionFromStore = true
            if storeIDs.isEmpty {
                outline.deselectAll(nil)
            } else {
                var indexes = IndexSet()
                for row in 0..<outline.numberOfRows {
                    if let node = outline.item(atRow: row) as? WorkspaceBrowserNode,
                       storeIDs.contains(node.id) {
                        indexes.insert(row)
                    }
                }
                outline.selectRowIndexes(indexes, byExtendingSelection: false)
            }
            isSyncingSelectionFromStore = false
        }

        private func refreshVisibleRowStates(in outline: NSOutlineView) {
            let visibleRange = outline.rows(in: outline.visibleRect)
            guard visibleRange.length > 0 else { return }
            let store = parent.store
            for row in visibleRange.location..<(visibleRange.location + visibleRange.length) {
                guard let node = outline.item(atRow: row) as? WorkspaceBrowserNode,
                      let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkspaceOutlineCellView else {
                    continue
                }
                let isActive = node.item.map { $0.id == store.activeItemID } ?? false
                let status = node.item.flatMap { store.itemStatuses[$0.id] } ?? .idle
                cell.updateVisualState(isActive: isActive, status: status)
            }
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let outline = outlineView else { return }
            let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
            guard row >= 0, let node = outline.item(atRow: row) as? WorkspaceBrowserNode else { return }
            activateNode(node, in: outline)
        }

        func openFirstSelectedRow() {
            guard let outline = outlineView else { return }
            let row = outline.selectedRow
            guard row >= 0, let node = outline.item(atRow: row) as? WorkspaceBrowserNode else { return }
            activateNode(node, in: outline)
        }

        private func activateNode(_ node: WorkspaceBrowserNode, in outline: NSOutlineView) {
            if node.isDirectory {
                if outline.isItemExpanded(node) {
                    outline.collapseItem(node)
                } else {
                    parent.store.loadChildrenIfNeeded(for: node)
                    outline.expandItem(node)
                }
            } else if let item = node.item, !parent.isBatchRunning() {
                parent.onOpenItem(item)
            }
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil {
                return parent.store.rootNodes().count
            }
            guard let node = item as? WorkspaceBrowserNode, node.isDirectory else { return 0 }
            return parent.store.childNodes(of: node).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                let roots = parent.store.rootNodes()
                return roots[index]
            }
            guard let node = item as? WorkspaceBrowserNode else { return NSObject() }
            return parent.store.childNodes(of: node)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? WorkspaceBrowserNode else { return false }
            return node.isDirectory
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            true
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            WorkspaceOutlineRowView()
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let node = item as? WorkspaceBrowserNode else { return 30 }
            let scale: CGFloat = parent.isLargeText ? 1.15 : 1.0
            if node.isDirectory {
                return 28 * scale
            }
            if parent.store.viewMode == .largeThumbnail {
                return 108 * scale
            }
            return 38 * scale
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let node = item as? WorkspaceBrowserNode, node.isDirectory else { return false }
            if !isSyncingExpansion {
                parent.store.expandedFolderIDs.insert(node.id)
                parent.store.loadChildrenIfNeeded(for: node)
            }
            return true
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isSyncingExpansion,
                  let node = notification.userInfo?["NSObject"] as? WorkspaceBrowserNode else { return }
            parent.store.expandedFolderIDs.insert(node.id)
            parent.store.loadChildrenIfNeeded(for: node)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSyncingExpansion,
                  let node = notification.userInfo?["NSObject"] as? WorkspaceBrowserNode else { return }
            parent.store.expandedFolderIDs.remove(node.id)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelectionFromStore, let outline = outlineView else { return }
            var selectedIDs = Set<String>()
            outline.selectedRowIndexes.forEach { row in
                if let node = outline.item(atRow: row) as? WorkspaceBrowserNode {
                    selectedIDs.insert(node.id)
                }
            }
            isSyncingSelectionFromOutline = true
            parent.store.updateSelection(selectedIDs)
            isSyncingSelectionFromOutline = false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? WorkspaceBrowserNode else { return nil }
            let isLargeThumb = !node.isDirectory && parent.store.viewMode == .largeThumbnail
            let identifier = NSUserInterfaceItemIdentifier(
                node.isDirectory ? "FolderCell" : (isLargeThumb ? "LargeThumbFileCell" : "CompactFileCell")
            )
            let cell: WorkspaceOutlineCellView
            if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? WorkspaceOutlineCellView {
                cell = reused
            } else {
                cell = WorkspaceOutlineCellView(mode: node.isDirectory ? .folder : (isLargeThumb ? .largeThumbnail : .compact))
                cell.identifier = identifier
            }

            let isActive = node.item.map { $0.id == parent.store.activeItemID } ?? false
            let status = node.item.flatMap { parent.store.itemStatuses[$0.id] } ?? .idle
            cell.configure(
                node: node,
                isActive: isActive,
                status: status,
                isLargeText: parent.isLargeText
            )
            return cell
        }

        // MARK: - NSMenuDelegate (右クリックメニュー)

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline = outlineView else { return }
            let clickedRow = outline.clickedRow
            guard clickedRow >= 0,
                  let node = outline.item(atRow: clickedRow) as? WorkspaceBrowserNode else {
                return
            }

            if !outline.selectedRowIndexes.contains(clickedRow) {
                outline.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }

            let mode = parent.currentWorkspaceMode()
            let batchBusy = parent.isBatchRunning()

            if node.isDirectory {
                if !node.isOutputFolder {
                    let batchTitle = mode == .convert2DTo3D
                        ? String(localized: "Batch 2D→3D This Folder")
                        : String(localized: "Batch Process This Folder")
                    let batchItem = NSMenuItem(title: batchTitle, action: #selector(ctxBatchSelection), keyEquivalent: "")
                    batchItem.target = self
                    batchItem.isEnabled = !batchBusy
                    menu.addItem(batchItem)

                    let rootItem = NSMenuItem(title: String(localized: "Set as Workspace Root"), action: #selector(ctxSetRoot(_:)), keyEquivalent: "")
                    rootItem.target = self
                    rootItem.representedObject = node.url
                    rootItem.isEnabled = !batchBusy
                    menu.addItem(rootItem)
                    menu.addItem(.separator())
                }

                let revealItem = NSMenuItem(title: String(localized: "Reveal in Finder"), action: #selector(ctxReveal(_:)), keyEquivalent: "")
                revealItem.target = self
                revealItem.representedObject = [node.url]
                menu.addItem(revealItem)
                return
            }

            guard let item = node.item else { return }

            let openItem = NSMenuItem(title: String(localized: "Open & Align"), action: #selector(ctxOpenItem(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = item
            openItem.isEnabled = !batchBusy
            menu.addItem(openItem)

            if mode == .stereoRestore && item.rightURL == nil {
                let open2D = NSMenuItem(title: String(localized: "Open as 2D → 3D"), action: #selector(ctxOpenForce2D(_:)), keyEquivalent: "")
                open2D.target = self
                open2D.representedObject = item.leftURL
                open2D.isEnabled = !batchBusy
                menu.addItem(open2D)

                let openStereo = NSMenuItem(title: String(localized: "Open as Stereo (SBS / Card)"), action: #selector(ctxOpenForceStereo(_:)), keyEquivalent: "")
                openStereo.target = self
                openStereo.representedObject = item.leftURL
                openStereo.isEnabled = !batchBusy
                menu.addItem(openStereo)
            }

            if mode == .stereoRestore, let (l, r) = parent.store.twoSelectedUnpairedFiles() {
                let lrItem = NSMenuItem(title: String(localized: "Open Selected 2 Files as L/R Pair"), action: #selector(ctxOpenLRPair(_:)), keyEquivalent: "")
                lrItem.target = self
                lrItem.representedObject = [l, r]
                lrItem.isEnabled = !batchBusy
                menu.addItem(lrItem)
            }

            menu.addItem(.separator())

            if mode == .stereoRestore {
                let verifyItem = NSMenuItem(title: String(localized: "Verify Stereo Selection"), action: #selector(ctxVerifySelection), keyEquivalent: "")
                verifyItem.target = self
                verifyItem.isEnabled = !batchBusy
                menu.addItem(verifyItem)
            }

            let batchItem = NSMenuItem(title: String(localized: "Batch Process Selection"), action: #selector(ctxBatchSelection), keyEquivalent: "")
            batchItem.target = self
            batchItem.isEnabled = !batchBusy
            menu.addItem(batchItem)

            menu.addItem(.separator())

            var urls = [item.leftURL]
            if let r = item.rightURL { urls.append(r) }
            let revealItem = NSMenuItem(title: String(localized: "Reveal in Finder"), action: #selector(ctxReveal(_:)), keyEquivalent: "")
            revealItem.target = self
            revealItem.representedObject = urls
            menu.addItem(revealItem)
        }

        @objc private func ctxOpenItem(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? StereoBatchItem else { return }
            parent.onOpenItem(item)
        }

        @objc private func ctxOpenForce2D(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            parent.onOpenForce2D(url)
        }

        @objc private func ctxOpenForceStereo(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            parent.onOpenForceStereo(url)
        }

        @objc private func ctxOpenLRPair(_ sender: NSMenuItem) {
            guard let urls = sender.representedObject as? [URL], urls.count == 2 else { return }
            parent.onOpenLRPair(urls[0], urls[1])
        }

        @objc private func ctxBatchSelection() {
            parent.onBatchSelection()
        }

        @objc private func ctxVerifySelection() {
            parent.onVerifySelection()
        }

        @objc private func ctxSetRoot(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            parent.onSetRootFolder(url)
        }

        @objc private func ctxReveal(_ sender: NSMenuItem) {
            guard let urls = sender.representedObject as? [URL] else { return }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}

// MARK: - Pure AppKit Cell & Badges

private final class PillBadgeView: NSView {
    private let dotView = NSView()
    private let label = NSTextField(labelWithString: "")
    private var dotWidthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 2.5
        dotView.translatesAutoresizingMaskIntoConstraints = false

        label.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dotView)
        addSubview(label)

        let dw = dotView.widthAnchor.constraint(equalToConstant: 5)
        dotWidthConstraint = dw
        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dw,
            dotView.heightAnchor.constraint(equalToConstant: 5),

            label.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, color: NSColor, showDot: Bool) {
        label.stringValue = text
        label.textColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        dotView.isHidden = !showDot
        dotView.layer?.backgroundColor = color.cgColor
        dotWidthConstraint?.constant = showDot ? 5 : 0
    }
}

/// ホバー時に独立した NSPopover で警告・エラー詳細を表示するビュー
private final class WarningBadgeHoverView: NSView {
    private let iconView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var hoverWorkItem: DispatchWorkItem?
    private var popover: NSPopover?

    private var badgeTitle: String = ""
    private var badgeMessage: String = ""
    private var badgeColor: NSColor = .systemOrange
    private var badgeSymbolName: String = "exclamationmark.triangle.fill"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(symbolName: String, color: NSColor, title: String, message: String) {
        badgeSymbolName = symbolName
        badgeColor = color
        badgeTitle = title
        badgeMessage = message

        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)
            iconView.image = img.withSymbolConfiguration(cfg)
            iconView.contentTintColor = color
        }
    }

    func resetHover() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        popover?.close()
        popover = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.presentPopover()
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        resetHover()
    }

    private func presentPopover() {
        guard window != nil, !isHidden else { return }
        popover?.close()

        let vc = NSViewController()
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.spacing = 6
        headerStack.alignment = .centerY
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let popIcon = NSImageView()
        if let img = NSImage(systemSymbolName: badgeSymbolName, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            popIcon.image = img.withSymbolConfiguration(cfg)
            popIcon.contentTintColor = badgeColor
        }

        let titleField = NSTextField(labelWithString: badgeTitle)
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleField.textColor = .white

        headerStack.addArrangedSubview(popIcon)
        headerStack.addArrangedSubview(titleField)

        let bodyField = NSTextField(wrappingLabelWithString: badgeMessage)
        bodyField.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        bodyField.textColor = NSColor.white.withAlphaComponent(0.92)
        bodyField.preferredMaxLayoutWidth = 280
        bodyField.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(headerStack)
        container.addSubview(bodyField)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),

            bodyField.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 6),
            bodyField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            bodyField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            bodyField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        ])

        vc.view = container

        let pop = NSPopover()
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.behavior = .transient
        pop.contentViewController = vc
        pop.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
        popover = pop
    }
}

final class WorkspaceOutlineCellView: NSTableCellView {
    enum CellMode {
        case folder
        case compact
        case largeThumbnail
    }

    private let mode: CellMode
    private let activeBar = NSView()
    private let thumbView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let lrBadge = PillBadgeView()
    private let outputBadge = PillBadgeView()
    private let statusPill = PillBadgeView()
    private let spinner = NSProgressIndicator()
    private let warningHoverView = WarningBadgeHoverView()

    private var currentURL: URL?
    private var thumbnailOp: Operation?

    init(mode: CellMode) {
        self.mode = mode
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailOp?.cancel()
        thumbnailOp = nil
        currentURL = nil
        thumbView.image = nil
        warningHoverView.resetHover()
    }

    private func setupViews() {
        wantsLayer = true

        activeBar.wantsLayer = true
        activeBar.layer?.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.66, blue: 0.18, alpha: 1.0).cgColor
        activeBar.layer?.cornerRadius = 1.5
        activeBar.isHidden = true
        activeBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activeBar)

        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 4
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbView)

        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        subtitleField.lineBreakMode = .byTruncatingMiddle
        subtitleField.maximumNumberOfLines = 1
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        lrBadge.configure(text: "L+R", color: NSColor(calibratedRed: 0.4, green: 0.8, blue: 1.0, alpha: 1.0), showDot: false)
        outputBadge.configure(text: "Output", color: NSColor(calibratedRed: 0.0, green: 0.8, blue: 0.4, alpha: 1.0), showDot: false)

        NSLayoutConstraint.activate([
            activeBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            activeBar.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            activeBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            activeBar.widthAnchor.constraint(equalToConstant: 3)
        ])

        switch mode {
        case .folder:
            thumbView.imageScaling = .scaleProportionallyDown
            addSubview(outputBadge)
            NSLayoutConstraint.activate([
                thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
                thumbView.widthAnchor.constraint(equalToConstant: 16),
                thumbView.heightAnchor.constraint(equalToConstant: 16),

                titleField.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 6),
                titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleField.trailingAnchor.constraint(lessThanOrEqualTo: outputBadge.leadingAnchor, constant: -6),

                outputBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                outputBadge.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            thumbView.layer?.backgroundColor = NSColor.clear.cgColor

        case .compact:
            thumbView.imageScaling = .scaleProportionallyUpOrDown
            addSubview(subtitleField)
            addSubview(lrBadge)
            addSubview(statusPill)
            addSubview(spinner)
            addSubview(warningHoverView)

            let textStack = NSStackView(views: [titleField, subtitleField])
            textStack.orientation = .vertical
            textStack.alignment = .leading
            textStack.spacing = 1
            textStack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(textStack)

            let rightAccessoryStack = NSStackView(views: [lrBadge, statusPill, spinner, warningHoverView])
            rightAccessoryStack.orientation = .horizontal
            rightAccessoryStack.spacing = 4
            rightAccessoryStack.alignment = .centerY
            rightAccessoryStack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rightAccessoryStack)

            textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            rightAccessoryStack.setContentHuggingPriority(.required, for: .horizontal)
            rightAccessoryStack.setContentCompressionResistancePriority(.required, for: .horizontal)

            NSLayoutConstraint.activate([
                thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
                thumbView.widthAnchor.constraint(equalToConstant: 38),
                thumbView.heightAnchor.constraint(equalToConstant: 26),

                textStack.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 8),
                textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
                textStack.trailingAnchor.constraint(lessThanOrEqualTo: rightAccessoryStack.leadingAnchor, constant: -6),

                rightAccessoryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                rightAccessoryStack.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])

        case .largeThumbnail:
            thumbView.imageScaling = .scaleProportionallyUpOrDown
            addSubview(lrBadge)
            addSubview(statusPill)
            addSubview(spinner)
            addSubview(warningHoverView)

            let overlayBadges = NSStackView(views: [lrBadge, statusPill, spinner, warningHoverView])
            overlayBadges.orientation = .horizontal
            overlayBadges.spacing = 4
            overlayBadges.alignment = .centerY
            overlayBadges.translatesAutoresizingMaskIntoConstraints = false
            addSubview(overlayBadges)

            NSLayoutConstraint.activate([
                thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                thumbView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                thumbView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                thumbView.heightAnchor.constraint(equalToConstant: 78),

                overlayBadges.topAnchor.constraint(equalTo: thumbView.topAnchor, constant: 5),
                overlayBadges.trailingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: -5),

                titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                titleField.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 4)
            ])
        }
    }

    func configure(node: WorkspaceBrowserNode, isActive: Bool, status: WorkspaceItemStatus, isLargeText: Bool) {
        let fontScale: CGFloat = isLargeText ? 1.2 : 1.0
        titleField.stringValue = node.displayName

        if mode == .folder {
            titleField.font = NSFont.systemFont(ofSize: 12 * fontScale, weight: .semibold)
            let folderColor = node.isOutputFolder
                ? NSColor(calibratedRed: 0.0, green: 0.8, blue: 0.4, alpha: 1.0)
                : NSColor(calibratedRed: 0.96, green: 0.66, blue: 0.18, alpha: 1.0)
            titleField.textColor = node.isOutputFolder ? folderColor : .white
            if let img = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)
                thumbView.image = img.withSymbolConfiguration(cfg)
                thumbView.contentTintColor = folderColor
            }
            outputBadge.isHidden = !node.isOutputFolder
            activeBar.isHidden = true
            return
        }

        titleField.font = NSFont.systemFont(ofSize: (mode == .largeThumbnail ? 11 : 11.5) * fontScale, weight: isActive ? .bold : .medium)
        titleField.textColor = .white

        if mode == .compact {
            if let item = node.item, let rURL = item.rightURL {
                subtitleField.stringValue = "\(item.leftURL.lastPathComponent) + \(rURL.lastPathComponent)"
                subtitleField.font = NSFont.monospacedSystemFont(ofSize: 9.5 * fontScale, weight: .regular)
                subtitleField.isHidden = false
            } else {
                subtitleField.isHidden = true
            }
        }

        if let item = node.item, item.isVideo {
            lrBadge.configure(text: "VIDEO", color: NSColor(calibratedRed: 0.75, green: 0.65, blue: 1.0, alpha: 1.0), showDot: false)
            lrBadge.isHidden = false
        } else if node.item?.rightURL != nil {
            lrBadge.configure(text: "L+R", color: NSColor(calibratedRed: 0.4, green: 0.8, blue: 1.0, alpha: 1.0), showDot: false)
            lrBadge.isHidden = false
        } else {
            lrBadge.isHidden = true
        }
        updateVisualState(isActive: isActive, status: status)

        if currentURL != node.url {
            thumbnailOp?.cancel()
            thumbnailOp = nil
            currentURL = node.url
            let maxPx = mode == .largeThumbnail ? 280 : 120
            if let cached = WorkspaceThumbnailCache.shared.cachedThumbnail(for: node.url, maxPixelSize: maxPx) {
                thumbView.image = cached
                thumbView.contentTintColor = nil
            } else {
                thumbView.image = nil
                let targetURL = node.url
                thumbnailOp = WorkspaceThumbnailCache.shared.loadThumbnail(for: targetURL, maxPixelSize: maxPx) { [weak self] img in
                    guard let self, self.currentURL == targetURL, let img else { return }
                    self.thumbView.image = img
                    self.thumbView.contentTintColor = nil
                }
            }
        }
    }

    func updateVisualState(isActive: Bool, status: WorkspaceItemStatus) {
        activeBar.isHidden = !isActive
        layer?.backgroundColor = isActive
            ? NSColor(calibratedRed: 0.96, green: 0.66, blue: 0.18, alpha: 0.14).cgColor
            : NSColor.clear.cgColor
        layer?.cornerRadius = 6

        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusPill.isHidden = true
        warningHoverView.isHidden = true
        warningHoverView.resetHover()

        switch status {
        case .idle:
            break
        case .processing:
            spinner.isHidden = false
            spinner.startAnimation(nil)
        case .completed:
            statusPill.isHidden = false
            statusPill.configure(
                text: "OK",
                color: NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.42, alpha: 1.0),
                showDot: true
            )
        case .aiConverted(let tag):
            statusPill.isHidden = false
            statusPill.configure(
                text: tag,
                color: NSColor(calibratedRed: 0.75, green: 0.65, blue: 1.0, alpha: 1.0),
                showDot: false
            )
        case .warning(let msg):
            warningHoverView.isHidden = false
            warningHoverView.configure(
                symbolName: "exclamationmark.triangle.fill",
                color: NSColor(calibratedRed: 0.96, green: 0.66, blue: 0.18, alpha: 1.0),
                title: String(localized: "Stereo Warning"),
                message: msg
            )
        case .failed(let msg):
            warningHoverView.isHidden = false
            warningHoverView.configure(
                symbolName: "xmark.octagon.fill",
                color: NSColor(calibratedRed: 0.90, green: 0.22, blue: 0.26, alpha: 1.0),
                title: String(localized: "Processing Failed"),
                message: msg
            )
        }
    }
}
