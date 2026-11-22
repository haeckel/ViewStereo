import AppKit
import Combine
import Foundation
import ImageIO
import SwiftUI

/// フォルダ選択パネル用：作業モード選択状態
final class WorkspacePanelModeSelection: ObservableObject {
    @Published var selectedMode: ViewStereoWorkspaceMode

    init(selectedMode: ViewStereoWorkspaceMode) {
        self.selectedMode = selectedMode
    }
}

/// NSOpenPanel の accessoryView として表示する作業モード選択ビュー
struct WorkspacePanelModeAccessoryView: View {
    @ObservedObject var selection: WorkspacePanelModeSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(LocalizedStringKey("Processing Mode"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                Picker("", selection: $selection.selectedMode) {
                    ForEach(ViewStereoWorkspaceMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            Text(LocalizedStringKey(
                selection.selectedMode == .stereoRestore
                    ? "mode_desc_stereo_restore"
                    : "mode_desc_2d_to_3d"
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 520, alignment: .leading)
        .preferredColorScheme(.dark)
    }
}

/// 起動時の作業フォルダ動作設定
enum StartupFolderAction: String, CaseIterable, Identifiable {
    case showSheet = "Ask for Workspace Folder"
    case reopenLastFolder = "Reopen Last Folder"
    case doNothing = "Show Welcome Screen"

    var id: String { rawValue }
}

/// ブラウザ表示モード
enum WorkspaceBrowserViewMode: String, CaseIterable, Identifiable {
    case compactList = "List"
    case largeThumbnail = "Thumbnails"

    var id: String { rawValue }
}

/// ファイルブラウザ上の各アイテム処理状態
enum WorkspaceItemStatus: Equatable {
    case idle
    case processing
    case completed
    case aiConverted(String)
    case warning(String)
    case failed(String)

    var isWarningOrError: Bool {
        switch self {
        case .warning, .failed: return true
        default: return false
        }
    }
}

/// 左ペイン・ツリー型ファイルブラウザのノード（NSOutlineView で安定参照できるよう参照型）
final class WorkspaceBrowserNode: NSObject, Identifiable {
    let id: String
    let url: URL
    let displayName: String
    let isDirectory: Bool
    let isOutputFolder: Bool
    let item: StereoBatchItem?

    init(
        id: String,
        url: URL,
        displayName: String,
        isDirectory: Bool,
        isOutputFolder: Bool,
        item: StereoBatchItem?
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.isOutputFolder = isOutputFolder
        self.item = item
        super.init()
    }

    override var hash: Int {
        id.hashValue
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? WorkspaceBrowserNode else { return false }
        return id == other.id
    }
}

/// 同時実行数制限付き・キャンセル対応・EXIF優先の高速サムネイルキャッシュ
final class WorkspaceThumbnailCache {
    static let shared = WorkspaceThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private let opQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "jp.p-media.ViewStereo.thumbQueue"
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()

    private init() {
        cache.countLimit = 500
    }

    private func cacheKey(url: URL, maxPixelSize: Int) -> NSString {
        let bucket = maxPixelSize <= 120 ? 120 : 280
        return "\(url.path)#\(bucket)" as NSString
    }

    func cachedThumbnail(for url: URL, maxPixelSize: Int = 120) -> NSImage? {
        cache.object(forKey: cacheKey(url: url, maxPixelSize: maxPixelSize))
    }

    @discardableResult
    func loadThumbnail(
        for url: URL,
        maxPixelSize: Int = 120,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) -> Operation? {
        let key = cacheKey(url: url, maxPixelSize: maxPixelSize)
        if let hit = cache.object(forKey: key) {
            Task { @MainActor in
                completion(hit)
            }
            return nil
        }

        let bucket = maxPixelSize <= 120 ? 120 : 280
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let op, !op.isCancelled else { return }
            let opts: [CFString: Any] = [
                kCGImageSourceShouldCache: false
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else {
                if !op.isCancelled {
                    Task { @MainActor in completion(nil) }
                }
                return
            }
            guard !op.isCancelled else { return }
            // 埋め込み EXIF サムネイルがあれば 0.5ms 程度で即時生成、なければ縮小デコード
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: bucket,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
                if !op.isCancelled {
                    Task { @MainActor in completion(nil) }
                }
                return
            }
            guard !op.isCancelled else { return }
            let nsImage = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
            self?.cache.setObject(nsImage, forKey: key)
            if !op.isCancelled {
                Task { @MainActor in
                    completion(nsImage)
                }
            }
        }
        opQueue.addOperation(op)
        return op
    }

    func invalidateAll() {
        opQueue.cancelAllOperations()
        cache.removeAllObjects()
    }
}

/// フォルダ走査・L/Rペア統合・バッチ対象解決ヘルパー（1パス I/O）
enum WorkspaceScanner {
    static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tif", "tiff", "bmp", "heic",
        "mpo", "webp",
        "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "pef", "srw", "raw"
    ]

    static func isOutputFolder(_ url: URL, customOutputFolder: URL?) -> Bool {
        let name = url.lastPathComponent
        if name == "ViewStereo_Output" { return true }
        if let custom = customOutputFolder, url.standardizedFileURL == custom.standardizedFileURL {
            return true
        }
        return false
    }

    /// 1 回の FileManager 列挙でサブフォルダとペア統合済み画像アイテムを同時に構築（2重 I/O を排除）
    static func scanDirectory(
        _ dir: URL,
        pairingMode: StereoBatchPairingMode,
        customOutputFolder: URL?
    ) -> [WorkspaceBrowserNode] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var dirNodes: [WorkspaceBrowserNode] = []
        var imageFiles: [URL] = []

        for url in contents {
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if vals?.isDirectory == true {
                let isOut = isOutputFolder(url, customOutputFolder: customOutputFolder)
                dirNodes.append(
                    WorkspaceBrowserNode(
                        id: "dir::" + url.standardizedFileURL.path,
                        url: url,
                        displayName: url.lastPathComponent,
                        isDirectory: true,
                        isOutputFolder: isOut,
                        item: nil
                    )
                )
            } else if vals?.isRegularFile == true,
                      supportedImageExtensions.contains(url.pathExtension.lowercased()) {
                imageFiles.append(url)
            }
        }

        dirNodes.sort {
            if $0.isOutputFolder != $1.isOutputFolder {
                return !$0.isOutputFolder
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        imageFiles.sort {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        let batchItems = pairImageFiles(imageFiles, mode: pairingMode)
        let fileNodes = batchItems.map { item in
            WorkspaceBrowserNode(
                id: "item::" + item.id,
                url: item.leftURL,
                displayName: item.displayLabel,
                isDirectory: false,
                isOutputFolder: false,
                item: item
            )
        }

        return dirNodes + fileNodes
    }

    static func pairImageFiles(_ files: [URL], mode: StereoBatchPairingMode) -> [StereoBatchItem] {
        switch mode {
        case .sbsOnly:
            return files.map { url in
                let stem = url.deletingPathExtension().lastPathComponent
                return StereoBatchItem(baseName: stem, displayLabel: url.lastPathComponent, leftURL: url, rightURL: nil)
            }

        case .consecutiveLR:
            var items: [StereoBatchItem] = []
            var i = 0
            while i + 1 < files.count {
                let l = files[i], r = files[i + 1]
                let stem = l.deletingPathExtension().lastPathComponent
                items.append(StereoBatchItem(baseName: stem, displayLabel: "\(l.lastPathComponent) + \(r.lastPathComponent)", leftURL: l, rightURL: r))
                i += 2
            }
            return items

        case .auto:
            let suffixPairs: [(String, String)] = [
                ("_L", "_R"), ("_l", "_r"),
                ("-L", "-R"), ("-l", "-r"),
                ("_left", "_right"), ("_LEFT", "_RIGHT"), ("_Left", "_Right"),
                ("Left", "Right")
            ]
            var byKey: [String: URL] = [:]
            for f in files {
                let key = "\(f.deletingPathExtension().lastPathComponent).\(f.pathExtension.lowercased())"
                byKey[key] = f
            }

            var used = Set<URL>()
            var items: [StereoBatchItem] = []

            for f in files {
                if used.contains(f) { continue }
                let stem = f.deletingPathExtension().lastPathComponent
                let ext = f.pathExtension.lowercased()
                var matchedRight: URL? = nil
                var cleanBase = stem

                for (lSuf, rSuf) in suffixPairs {
                    if stem.hasSuffix(lSuf) {
                        let base = String(stem.dropLast(lSuf.count))
                        let rKey = "\(base)\(rSuf).\(ext)"
                        if let rURL = byKey[rKey], !used.contains(rURL), rURL != f {
                            matchedRight = rURL
                            cleanBase = base.isEmpty ? stem : base
                            break
                        }
                    }
                }

                if let rURL = matchedRight {
                    used.insert(f)
                    used.insert(rURL)
                    items.append(StereoBatchItem(
                        baseName: cleanBase,
                        displayLabel: "\(f.lastPathComponent) + \(rURL.lastPathComponent)",
                        leftURL: f,
                        rightURL: rURL
                    ))
                }
            }

            for f in files where !used.contains(f) {
                let stem = f.deletingPathExtension().lastPathComponent
                items.append(StereoBatchItem(
                    baseName: stem,
                    displayLabel: f.lastPathComponent,
                    leftURL: f,
                    rightURL: nil
                ))
            }

            return items.sorted { $0.baseName.localizedStandardCompare($1.baseName) == .orderedAscending }
        }
    }

    /// バッチ対象アイテムを収集（選択ノード群・再帰オプション対応・ViewStereo_Output除外・重複排除）
    static func collectBatchItems(
        from selectedNodes: [WorkspaceBrowserNode],
        rootFolder: URL?,
        pairingMode: StereoBatchPairingMode,
        includeSubfolders: Bool,
        customOutputFolder: URL?
    ) -> [StereoBatchItem] {
        var collected: [StereoBatchItem] = []
        var seenIDs = Set<String>()

        func appendUnique(_ items: [StereoBatchItem]) {
            for item in items {
                if seenIDs.insert(item.id).inserted {
                    collected.append(item)
                }
            }
        }

        func scanFolder(_ folder: URL) {
            if isOutputFolder(folder, customOutputFolder: customOutputFolder) {
                return
            }
            let nodes = scanDirectory(folder, pairingMode: pairingMode, customOutputFolder: customOutputFolder)
            appendUnique(nodes.compactMap(\.item))

            if includeSubfolders {
                for node in nodes where node.isDirectory && !node.isOutputFolder {
                    scanFolder(node.url)
                }
            }
        }

        if selectedNodes.isEmpty {
            if let root = rootFolder {
                scanFolder(root)
            }
            return collected
        }

        for node in selectedNodes {
            if node.isDirectory {
                scanFolder(node.url)
            } else if let item = node.item {
                appendUnique([item])
            }
        }

        return collected
    }
}

/// 左ファイルブラウザ専用の状態ストア（ViewStereoViewModel から完全分離し、選択操作でアプリ全体を再描画させない）
@MainActor
final class WorkspaceBrowserStore: ObservableObject {
    @Published var rootFolder: URL? = nil
    @Published private(set) var isVirtualSelection: Bool = false
    @Published private(set) var virtualTitle: String? = nil

    var displayTitle: String? {
        if isVirtualSelection {
            return virtualTitle
        }
        return rootFolder?.lastPathComponent
    }
    @Published var viewMode: WorkspaceBrowserViewMode = .compactList
    @Published var searchText: String = "" {
        didSet {
            if oldValue != searchText {
                rebuildFilteredCacheIfNeeded()
            }
        }
    }
    @Published var showWarningsOnly: Bool = false {
        didSet {
            if oldValue != showWarningsOnly {
                rebuildFilteredCacheIfNeeded()
            }
        }
    }
    @Published var isScanning: Bool = false

    /// ツリー構造のバージョン（ディレクトリ再スキャン・展開時のみインクリメント）
    @Published private(set) var treeRevision: Int = 0
    /// 選択中ノード ID（選択変更はブラウザと小さな件数ボタンだけが購読）
    @Published var selectedNodeIDs: Set<String> = []
    /// 選択から即時計算されるバッチ対象件数
    @Published private(set) var selectedBatchCount: Int = 0
    /// 現在中央キャンバスで開いているアイテム ID
    @Published var activeItemID: String? = nil
    /// 各アイテムの処理ステータス
    @Published var itemStatuses: [String: WorkspaceItemStatus] = [:] {
        didSet {
            if showWarningsOnly && oldValue != itemStatuses {
                rebuildFilteredCacheIfNeeded()
            }
        }
    }
    /// 展開中フォルダ ID
    @Published var expandedFolderIDs: Set<String> = []

    /// ディレクトリパス -> 子ノード一覧（描画副作用を起こさないキャッシュ）
    private(set) var childrenCache: [String: [WorkspaceBrowserNode]] = [:]
    /// フィルタ有効時の事前計算済みキャッシュ（O(1) 参照用）
    private var filteredChildrenCache: [String: [WorkspaceBrowserNode]] = [:]
    /// ID -> ノード高速ルックアップ
    private var nodesByID: [String: WorkspaceBrowserNode] = [:]
    /// 非同期スキャン世代管理
    private var scanGeneration: Int = 0
    private var includeSubfolders: Bool = false
    private var currentPairingMode: StereoBatchPairingMode = .auto
    private var currentOutputFolder: URL? = nil
    private var virtualSourceURLs: [URL] = []
    private static let virtualRootURL = URL(fileURLWithPath: "/__viewstereo_virtual_selection__", isDirectory: true)

    func configureOptions(
        pairingMode: StereoBatchPairingMode,
        includeSubfolders: Bool,
        outputFolder: URL?
    ) {
        let pairingChanged = currentPairingMode != pairingMode
        let recursiveChanged = self.includeSubfolders != includeSubfolders
        currentPairingMode = pairingMode
        self.includeSubfolders = includeSubfolders
        currentOutputFolder = outputFolder

        if pairingChanged {
            refreshAsync()
        } else if recursiveChanged {
            recomputeSelectedBatchCount()
        }
    }

    func setRootFolder(_ folder: URL, pairingMode: StereoBatchPairingMode, outputFolder: URL?, includeSubfolders: Bool) {
        let stdFolder = folder.standardizedFileURL
        isVirtualSelection = false
        virtualTitle = nil
        virtualSourceURLs = []
        rootFolder = stdFolder
        currentPairingMode = pairingMode
        currentOutputFolder = outputFolder
        self.includeSubfolders = includeSubfolders
        selectedNodeIDs.removeAll()
        expandedFolderIDs.removeAll()
        childrenCache.removeAll()
        nodesByID.removeAll()
        selectedBatchCount = 0
        treeRevision += 1
        refreshAsync()
    }

    func setVirtualSelection(
        urls: [URL],
        pairingMode: StereoBatchPairingMode,
        outputFolder: URL?,
        includeSubfolders: Bool
    ) {
        scanGeneration += 1
        isVirtualSelection = true
        virtualSourceURLs = urls
        rootFolder = Self.virtualRootURL
        currentPairingMode = pairingMode
        currentOutputFolder = outputFolder
        self.includeSubfolders = includeSubfolders
        selectedNodeIDs.removeAll()
        expandedFolderIDs.removeAll()
        childrenCache.removeAll()
        nodesByID.removeAll()
        isScanning = false
        rebuildVirtualNodes()
    }

    private func rebuildVirtualNodes() {
        let existing = virtualSourceURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        let sortedFiles = existing.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let batchItems = WorkspaceScanner.pairImageFiles(sortedFiles, mode: currentPairingMode)
        let nodes = batchItems.map { item in
            WorkspaceBrowserNode(
                id: "item::" + item.id,
                url: item.leftURL,
                displayName: item.displayLabel,
                isDirectory: false,
                isOutputFolder: false,
                item: item
            )
        }
        let key = Self.virtualRootURL.standardizedFileURL.path
        childrenCache = [key: nodes]
        virtualTitle = String(format: String(localized: "Selected Photos (%lld)"), Int64(nodes.count))
        rebuildNodeIndex()
        treeRevision += 1
        recomputeSelectedBatchCount()
    }

    func refreshAsync() {
        guard let root = rootFolder else {
            childrenCache.removeAll()
            nodesByID.removeAll()
            selectedBatchCount = 0
            treeRevision += 1
            return
        }
        if isVirtualSelection {
            rebuildVirtualNodes()
            return
        }
        scanGeneration += 1
        let gen = scanGeneration
        let expanded = expandedFolderIDs
        let pairing = currentPairingMode
        let outDir = currentOutputFolder
        isScanning = true

        Task {
            let scanned = await Task.detached(priority: .userInitiated) { () -> [String: [WorkspaceBrowserNode]] in
                var map: [String: [WorkspaceBrowserNode]] = [:]
                map[root.standardizedFileURL.path] = WorkspaceScanner.scanDirectory(
                    root,
                    pairingMode: pairing,
                    customOutputFolder: outDir
                )
                for folderID in expanded where folderID.hasPrefix("dir::") {
                    let path = String(folderID.dropFirst("dir::".count))
                    let url = URL(fileURLWithPath: path, isDirectory: true)
                    map[path] = WorkspaceScanner.scanDirectory(
                        url,
                        pairingMode: pairing,
                        customOutputFolder: outDir
                    )
                }
                return map
            }.value

            guard gen == self.scanGeneration else { return }
            self.childrenCache = scanned
            self.rebuildNodeIndex()
            self.isScanning = false
            self.treeRevision += 1
            self.recomputeSelectedBatchCount()
        }
    }

    func loadChildrenIfNeeded(for folderNode: WorkspaceBrowserNode) {
        guard folderNode.isDirectory else { return }
        let path = folderNode.url.standardizedFileURL.path
        if childrenCache[path] != nil { return }
        let pairing = currentPairingMode
        let outDir = currentOutputFolder
        let gen = scanGeneration

        // 同期展開を軽く見せるためまず空キャッシュを入れて二重起動を防止し、非同期でロード
        childrenCache[path] = []
        Task {
            let nodes = await Task.detached(priority: .userInitiated) {
                WorkspaceScanner.scanDirectory(
                    folderNode.url,
                    pairingMode: pairing,
                    customOutputFolder: outDir
                )
            }.value
            guard gen == self.scanGeneration else { return }
            self.childrenCache[path] = nodes
            self.rebuildNodeIndex()
            self.treeRevision += 1
            self.recomputeSelectedBatchCount()
        }
    }

    private var isFilterActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || showWarningsOnly
    }

    private func rebuildNodeIndex() {
        var idx: [String: WorkspaceBrowserNode] = [:]
        for list in childrenCache.values {
            for n in list {
                idx[n.id] = n
            }
        }
        nodesByID = idx
        rebuildFilteredCacheIfNeeded()
    }

    private func rebuildFilteredCacheIfNeeded() {
        guard isFilterActive else {
            if !filteredChildrenCache.isEmpty {
                filteredChildrenCache.removeAll()
            }
            return
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let warnOnly = showWarningsOnly
        var next: [String: [WorkspaceBrowserNode]] = [:]
        next.reserveCapacity(childrenCache.count)
        for (path, nodes) in childrenCache {
            next[path] = filterNodes(nodes, query: query, warnOnly: warnOnly)
        }
        filteredChildrenCache = next
    }

    func rootNodes() -> [WorkspaceBrowserNode] {
        guard let root = rootFolder else { return [] }
        let path = root.standardizedFileURL.path
        if isFilterActive {
            return filteredChildrenCache[path] ?? []
        }
        return childrenCache[path] ?? []
    }

    func childNodes(of folderNode: WorkspaceBrowserNode) -> [WorkspaceBrowserNode] {
        guard folderNode.isDirectory else { return [] }
        let path = folderNode.url.standardizedFileURL.path
        if isFilterActive {
            return filteredChildrenCache[path] ?? []
        }
        return childrenCache[path] ?? []
    }

    private func filterNodes(_ nodes: [WorkspaceBrowserNode], query: String, warnOnly: Bool) -> [WorkspaceBrowserNode] {
        if query.isEmpty && !warnOnly {
            return nodes
        }
        return nodes.filter { node in
            if node.isDirectory {
                return true
            }
            if warnOnly {
                let st = node.item.flatMap { itemStatuses[$0.id] } ?? .idle
                if !st.isWarningOrError { return false }
            }
            if !query.isEmpty {
                let m1 = node.displayName.lowercased().contains(query)
                let m2 = node.item?.rightURL?.lastPathComponent.lowercased().contains(query) ?? false
                if !m1 && !m2 { return false }
            }
            return true
        }
    }

    func updateSelection(_ newSelection: Set<String>) {
        guard newSelection != selectedNodeIDs else { return }
        selectedNodeIDs = newSelection
        recomputeSelectedBatchCount()
    }

    func selectAllVisibleFiles() {
        guard rootFolder != nil else { return }
        var ids = Set<String>()
        func walk(_ nodes: [WorkspaceBrowserNode]) {
            for n in nodes {
                if n.isDirectory {
                    if expandedFolderIDs.contains(n.id) {
                        walk(childNodes(of: n))
                    }
                } else {
                    ids.insert(n.id)
                }
            }
        }
        walk(rootNodes())
        updateSelection(ids)
    }

    func deselectAll() {
        updateSelection([])
    }

    func selectedNodes() -> [WorkspaceBrowserNode] {
        selectedNodeIDs.compactMap { nodesByID[$0] }
    }

    func twoSelectedUnpairedFiles() -> (URL, URL)? {
        guard selectedNodeIDs.count == 2 else { return nil }
        let nodes = selectedNodes().filter { !$0.isDirectory && $0.item?.rightURL == nil }
        guard nodes.count == 2,
              let first = nodes[0].item?.leftURL,
              let second = nodes[1].item?.leftURL else {
            return nil
        }
        return (first, second)
    }

    func recomputeSelectedBatchCount() {
        let selected = selectedNodes()
        if !selected.isEmpty && selected.allSatisfy({ !$0.isDirectory }) {
            var seen = Set<String>()
            var c = 0
            for n in selected {
                if let item = n.item, seen.insert(item.id).inserted { c += 1 }
            }
            if selectedBatchCount != c { selectedBatchCount = c }
            return
        }
        if isVirtualSelection {
            let key = Self.virtualRootURL.standardizedFileURL.path
            let c = (childrenCache[key] ?? []).filter { $0.item != nil }.count
            if selectedBatchCount != c { selectedBatchCount = c }
            return
        }
        if !includeSubfolders {
            let dir: URL? = selected.first(where: { $0.isDirectory })?.url ?? rootFolder
            if selected.count <= 1, let dir {
                if WorkspaceScanner.isOutputFolder(dir, customOutputFolder: currentOutputFolder) {
                    if selectedBatchCount != 0 { selectedBatchCount = 0 }
                    return
                }
                if let cached = childrenCache[dir.standardizedFileURL.path] {
                    let c = cached.filter { !$0.isDirectory && $0.item != nil }.count
                    if selectedBatchCount != c { selectedBatchCount = c }
                    return
                }
            }
        }
        // 未キャッシュのフォルダや再帰ONのときだけ非同期カウント（メインスレッドをブロックしない）
        let root = rootFolder
        let pairing = currentPairingMode
        let rec = includeSubfolders
        let out = currentOutputFolder
        let snapshot = selectedNodeIDs
        Task {
            let count = await Task.detached(priority: .utility) {
                WorkspaceScanner.collectBatchItems(
                    from: selected,
                    rootFolder: root,
                    pairingMode: pairing,
                    includeSubfolders: rec,
                    customOutputFolder: out
                ).count
            }.value
            if self.selectedNodeIDs == snapshot && self.selectedBatchCount != count {
                self.selectedBatchCount = count
            }
        }
    }

    func resolveBatchItems() -> [StereoBatchItem] {
        if isVirtualSelection {
            let selected = selectedNodes().compactMap(\.item)
            if !selected.isEmpty {
                var seen = Set<String>()
                return selected.filter { seen.insert($0.id).inserted }
            }
            let key = Self.virtualRootURL.standardizedFileURL.path
            return (childrenCache[key] ?? []).compactMap(\.item)
        }
        return WorkspaceScanner.collectBatchItems(
            from: selectedNodes(),
            rootFolder: rootFolder,
            pairingMode: currentPairingMode,
            includeSubfolders: includeSubfolders,
            customOutputFolder: currentOutputFolder
        )
    }
}
