import AppKit
import Combine
import Foundation
import StereoStudioCore
import SwiftUI

// MARK: - Workbench Enums & Models

enum WorkbenchLayoutMode: String, CaseIterable, Identifiable {
    case split = "Split"
    case cardOnly = "Card Only"
    case windowOnly = "Window Only"

    var id: String { rawValue }
    var iconName: String {
        switch self {
        case .split: return "rectangle.split.2x1"
        case .cardOnly: return "photo.artframe"
        case .windowOnly: return "eyeglasses"
        }
    }
}

enum WorkbenchStereoPreviewMode: String, CaseIterable, Identifiable {
    case anaglyph = "Anaglyph"
    case sbs = "SBS"

    var id: String { rawValue }
    var iconName: String {
        switch self {
        case .anaglyph: return "eyeglasses"
        case .sbs: return "rectangle.split.2x1"
        }
    }
}

enum WorkbenchGuideHandle: Equatable {
    case top(side: CardPrintSide)
    case bottom(side: CardPrintSide)
    case leftOuter
    case leftInner
    case rightInner
    case rightOuter

    var isHorizontal: Bool {
        switch self {
        case .top, .bottom: return true
        default: return false
        }
    }
}

struct WorkbenchSnapshot {
    let points: [InteractivePromptPoint]
    let baseAnchorBoxL: InteractivePromptBox
    let baseAnchorBoxR: InteractivePromptBox
    let effectiveBoxL: InteractivePromptBox?
    let effectiveBoxR: InteractivePromptBox?
    let hasCustomBoxL: Bool
    let hasCustomBoxR: Bool
    let maskL: [Bool]
    let probL: [Float]
    let maskR: [Bool]
    let probR: [Float]
    let guideTopArchRatio: Double
    let guideBotRoundRatio: Double
    let isDirectGuideMaskActive: Bool
    let windowShiftX: Double
    let isSwapped: Bool
}

// MARK: - StereoWorkbenchSession

@MainActor
final class StereoWorkbenchSession: ObservableObject {
    let vm: ViewStereoViewModel
    let saveQueue = StereoWorkbenchSaveQueue.shared

    // MARK: - Layout & Navigation
    @Published var layoutMode: WorkbenchLayoutMode = .split
    @Published var currentItemIndex: Int = 0
    @Published var totalItemCount: Int = 0
    @Published var currentFileName: String = ""
    @Published var isDirty: Bool = false
    @Published var isLoadingCard: Bool = false
    @Published var statusBanner: (text: String, isError: Bool)? = nil

    // MARK: - Card & Mask State
    @Published var activeSide: CardPrintSide = .left
    @Published var toolMode: MaskEditorToolMode = .adjustGuides
    @Published var previewStyle: MaskEditorPreviewStyle = .overlay
    @Published var useBoxAnchor: Bool = true
    @Published var lockEqualGuideWidth: Bool = true

    @Published var baseAnchorBoxL = InteractivePromptBox(normMinX: 0.04, normMinY: 0.08, normMaxX: 0.48, normMaxY: 0.92)
    @Published var baseAnchorBoxR = InteractivePromptBox(normMinX: 0.52, normMinY: 0.08, normMaxX: 0.96, normMaxY: 0.92)
    @Published var effectiveBoxL: InteractivePromptBox? = nil
    @Published var effectiveBoxR: InteractivePromptBox? = nil
    @Published var hasCustomBoxL: Bool = false
    @Published var hasCustomBoxR: Bool = false

    @Published var guideTopArchRatio: Double = 0.0
    @Published var guideBotRoundRatio: Double = 0.0
    @Published var isDirectGuideMaskActive: Bool = true

    @Published var points: [InteractivePromptPoint] = []
    @Published var isPreparingEmbedding: Bool = false
    @Published var isInferring: Bool = false
    @Published var cacheStatusText: String = ""
    @Published var lastElapsedMs: Double? = nil

    @Published var renderedCardImage: NSImage? = nil

    // Guide Dragging State
    var hoveredGuide: WorkbenchGuideHandle? = nil
    var draggingGuide: WorkbenchGuideHandle? = nil
    var draggingGuideIndependent: Bool = false
    var pendingDragSnapshot: WorkbenchSnapshot? = nil

    // MARK: - Stereo Window State
    @Published var stereoPreviewMode: WorkbenchStereoPreviewMode = .anaglyph
    @Published var windowShiftX: Double = 0.0
    @Published var autoOptimalShiftX: Double = 0.0
    @Published var isSwapped: Bool = false
    @Published var nearParallaxPercent: Double = 0.0
    @Published var farParallaxPercent: Double = 0.0
    @Published var hasWindowViolationRisk: Bool = false
    @Published var renderedStereoImage: NSImage? = nil

    // MARK: - Internal Buffers
    private var initialAnchorBoxL = InteractivePromptBox(normMinX: 0.04, normMinY: 0.08, normMaxX: 0.48, normMaxY: 0.92)
    private var initialAnchorBoxR = InteractivePromptBox(normMinX: 0.52, normMinY: 0.08, normMaxX: 0.96, normMaxY: 0.92)
    private var maskW: Int = 256
    private var maskH: Int = 128
    private var currentMaskL: [Bool] = []
    private var currentProbL: [Float] = []
    private var currentMaskR: [Bool] = []
    private var currentProbR: [Float] = []

    private var previewBaseRGB: [UInt8] = []
    private var previewBaseW: Int = 0
    private var previewBaseH: Int = 0

    private var embeddingCache: SAMImageEmbeddingCache? = nil
    private var undoStack: [WorkbenchSnapshot] = []
    private var inferenceTask: Task<Void, Never>? = nil
    private var stereoRenderTask: Task<Void, Never>? = nil

    private var currentLoadedItem: StereoBatchItem? = nil
    private var cancellables = Set<AnyCancellable>()

    init(vm: ViewStereoViewModel) {
        self.vm = vm
        bindViewModel()
    }

    private func bindViewModel() {
        // 1. currentMountContext の変化を購読（非同期ロード完了時に自動反映）
        vm.$currentMountContext
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newCtx in
                guard let self else { return }
                if newCtx != nil {
                    self.isLoadingCard = false
                    self.statusBanner = nil
                    Task {
                        await self.loadCurrentVMState()
                    }
                } else if !self.vm.isProcessing && self.vm.leftURL != nil {
                    self.isLoadingCard = false
                    self.statusBanner = (String(localized: "No stereoview card mount detected."), true)
                }
            }
            .store(in: &cancellables)

        // 2. isProcessing の監視（ロード中状態の追従）
        vm.$isProcessing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] processing in
                guard let self else { return }
                if processing {
                    if self.vm.currentMountContext == nil {
                        self.isLoadingCard = true
                        self.statusBanner = nil
                    }
                } else {
                    self.isLoadingCard = false
                    if self.vm.currentMountContext != nil && self.renderedCardImage == nil {
                        Task {
                            await self.loadCurrentVMState()
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // 3. leftURL の変化（ファイル名表示の即時同期 & 未保存ガード）
        vm.$leftURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newURL in
                guard let self else { return }
                if let url = newURL {
                    if self.isDirty && !self.currentFileName.isEmpty && self.currentFileName != url.lastPathComponent {
                        self.saveCurrentChangesToQueue()
                    }
                    self.currentFileName = url.lastPathComponent
                }
                self.updateNavigationMetadata()
            }
            .store(in: &cancellables)
    }

    // MARK: - Session Setup & Loading

    func loadCurrentVMState() async {
        updateNavigationMetadata()

        guard let ctx = vm.currentMountContext else {
            if vm.isProcessing {
                isLoadingCard = true
                statusBanner = nil
            } else {
                isLoadingCard = false
                statusBanner = (String(localized: "No stereoview card mount detected."), true)
            }
            return
        }

        isLoadingCard = false

        isPreparingEmbedding = true
        let cardW = max(1, ctx.cardWidth)
        let cardH = max(1, ctx.cardHeight)

        // フォルダ保存済みオーバーライドがあれば優先適用、なければ初期自動推定枠
        if let ov = vm.currentMaskGuideOverride {
            baseAnchorBoxL = ov.boxL
            baseAnchorBoxR = ov.boxR
            guideTopArchRatio = ov.topArchRatio
            guideBotRoundRatio = ov.botRoundRatio
            hasCustomBoxL = true
            hasCustomBoxR = true
            isDirectGuideMaskActive = true
        } else {
            baseAnchorBoxL = InteractivePromptBox(
                normMinX: Double(ctx.leftBox.x0) / Double(cardW),
                normMinY: Double(ctx.leftBox.y0) / Double(cardH),
                normMaxX: Double(ctx.leftBox.x1) / Double(cardW),
                normMaxY: Double(ctx.leftBox.y1) / Double(cardH)
            )
            baseAnchorBoxR = InteractivePromptBox(
                normMinX: Double(ctx.rightBox.x0) / Double(cardW),
                normMinY: Double(ctx.rightBox.y0) / Double(cardH),
                normMaxX: Double(ctx.rightBox.x1) / Double(cardW),
                normMaxY: Double(ctx.rightBox.y1) / Double(cardH)
            )
            guideTopArchRatio = ctx.archParams.topRyRatio
            guideBotRoundRatio = ctx.archParams.botRyRatio
            hasCustomBoxL = false
            hasCustomBoxR = false
            isDirectGuideMaskActive = true
        }

        initialAnchorBoxL = baseAnchorBoxL
        initialAnchorBoxR = baseAnchorBoxR
        effectiveBoxL = baseAnchorBoxL
        effectiveBoxR = baseAnchorBoxR

        windowShiftX = vm.windowShiftX
        autoOptimalShiftX = vm.autoOptimalShiftX
        isSwapped = vm.isSwapped
        nearParallaxPercent = vm.nearParallaxPercent
        farParallaxPercent = vm.farParallaxPercent
        hasWindowViolationRisk = vm.hasWindowViolationRisk
        isDirty = false
        undoStack.removeAll()

        updateNavigationMetadata()

        // プレビュー用カードRGB
        let (prevRGB, pw, ph) = ViewStereoViewModel.downsampleForPreview(ctx.cardRGB, width: cardW, height: cardH, maxDim: 1400)
        previewBaseRGB = prevRGB
        previewBaseW = pw
        previewBaseH = ph

        // SAM 2.1 キャッシュ取得
        let cache = await Task.detached(priority: .userInitiated) { () -> SAMImageEmbeddingCache? in
            StereoCardSegmenter.shared.prepareInteractiveEmbedding(
                cardRGB: ctx.cardRGB,
                width: ctx.cardWidth,
                height: ctx.cardHeight
            )
        }.value

        isPreparingEmbedding = false
        embeddingCache = cache
        if cache != nil {
            cacheStatusText = "SAM 2.1 Ready"
        } else {
            cacheStatusText = "SAM 2.1 Off"
        }

        let targetW = cache?.validW ?? max(64, ctx.maskWidth)
        let targetH = cache?.validH ?? max(32, ctx.maskHeight)
        maskW = targetW
        maskH = targetH

        if isDirectGuideMaskActive {
            applyDirectGuideMask(recordUndo: false)
        } else {
            let initial = StereoCardSegmenter.makeInitialInteractiveMasks(
                from: ctx,
                targetW: targetW,
                targetH: targetH
            )
            currentMaskL = initial.maskL
            currentProbL = initial.probL
            currentMaskR = initial.maskR
            currentProbR = initial.probR
            rebuildCardPreview()
        }

        updateStereoPreview()
        isDirty = false
    }

    private func updateNavigationMetadata() {
        let items = vm.browserStore.allFlattenedItems()
        totalItemCount = items.count
        if let currentURL = vm.leftURL {
            currentFileName = currentURL.lastPathComponent
            if let idx = items.firstIndex(where: { $0.leftURL == currentURL }) {
                currentItemIndex = idx
                currentLoadedItem = items[idx]
            }
        }
    }

    // MARK: - Navigation: Prev / Next / Save & Next

    func navigatePrevious() {
        guard !isPreparingEmbedding else { return }
        if isDirty {
            saveCurrentChangesToQueue()
        }
        let items = vm.browserStore.allFlattenedItems()
        guard !items.isEmpty else { return }
        let nextIdx = (currentItemIndex > 0) ? currentItemIndex - 1 : items.count - 1
        loadItemAtIndex(nextIdx, items: items)
    }

    func navigateNext() {
        guard !isPreparingEmbedding else { return }
        if isDirty {
            saveCurrentChangesToQueue()
        }
        let items = vm.browserStore.allFlattenedItems()
        guard !items.isEmpty else { return }
        let nextIdx = (currentItemIndex + 1 < items.count) ? currentItemIndex + 1 : 0
        loadItemAtIndex(nextIdx, items: items)
    }

    func saveAndNext() {
        guard !isPreparingEmbedding else { return }
        saveCurrentChangesToQueue()
        let items = vm.browserStore.allFlattenedItems()
        guard !items.isEmpty else { return }
        let nextIdx = (currentItemIndex + 1 < items.count) ? currentItemIndex + 1 : 0
        loadItemAtIndex(nextIdx, items: items)
    }

    func saveCurrentChangesToQueue() {
        guard let ctx = vm.currentMountContext, let url = vm.leftURL else { return }
        let overrides = currentDirectOverrides()
        let baseSet = vm.snapshotCurrentItemSettings()

        let job = StereoWorkbenchSaveQueue.SaveJob(
            id: UUID(),
            itemURL: url,
            sourceFileName: url.lastPathComponent,
            mountContext: ctx,
            maskL: currentMaskL,
            softProbL: currentProbL,
            maskR: currentMaskR,
            softProbR: currentProbR,
            maskW: maskW,
            maskH: maskH,
            points: points,
            overrideArchParams: overrides.arch,
            overrideBoxes: overrides.boxes,
            windowShiftX: windowShiftX,
            isSwapped: isSwapped,
            exportTrainingData: vm.autoExportTrainingDatasetOnMaskApply,
            trainingDatasetDirectoryPath: vm.trainingDatasetDirectoryPath,
            rootFolderURL: vm.currentFolderRootURL(),
            baseSettings: baseSet
        )

        saveQueue.enqueue(job: job)
        isDirty = false
        statusBanner = (String(format: String(localized: "Enqueued save for %@"), url.lastPathComponent), false)
    }

    private func loadItemAtIndex(_ idx: Int, items: [StereoBatchItem]) {
        guard idx >= 0 && idx < items.count else { return }
        let item = items[idx]
        currentItemIndex = idx
        currentLoadedItem = item
        vm.openBrowserItem(item)
        Task {
            // ロード完了待ち
            try? await Task.sleep(nanoseconds: 300_000_000)
            await loadCurrentVMState()
        }
    }

    // MARK: - Direct Guide Mask & Arch Generation

    func applyDirectGuideMask(recordUndo: Bool = true) {
        if recordUndo {
            pushCurrentSnapshot()
        }
        guard maskW > 0, maskH > 0 else { return }
        let arch = StereoCardSegmenter.makeGuideArchParams(
            topRyRatio: guideTopArchRatio,
            botRyRatio: guideBotRoundRatio
        )
        let direct = StereoCardSegmenter.buildGuideDirectMasks(
            boxL: baseAnchorBoxL,
            boxR: baseAnchorBoxR,
            archParams: arch,
            maskW: maskW,
            maskH: maskH
        )
        currentMaskL = direct.maskL
        currentProbL = direct.probL
        currentMaskR = direct.maskR
        currentProbR = direct.probR
        effectiveBoxL = baseAnchorBoxL
        effectiveBoxR = baseAnchorBoxR
        hasCustomBoxL = true
        hasCustomBoxR = true
        isDirectGuideMaskActive = true
        isDirty = true
        rebuildCardPreview()
        updateStereoPreview()
    }

    func toggleDirectGuideMask() {
        pushCurrentSnapshot()
        isDirectGuideMaskActive.toggle()
        isDirty = true
        if isDirectGuideMaskActive {
            applyDirectGuideMask(recordUndo: false)
        } else {
            rerunBothSidesInference()
        }
    }

    func addPromptPoint(normX: Double, normY: Double, isPositive: Bool, side: CardPrintSide) {
        pushCurrentSnapshot()
        isDirectGuideMaskActive = false
        isDirty = true
        let newPoint = InteractivePromptPoint(
            side: side,
            normX: min(1.0, max(0.0, normX)),
            normY: min(1.0, max(0.0, normY)),
            isPositive: isPositive
        )
        points.append(newPoint)
        rerunInference(for: side, forceIfNoPoints: (side == .left) ? hasCustomBoxL : hasCustomBoxR)
    }

    func removeNearestPoint(normX: Double, normY: Double, threshold: Double = 0.035) {
        var bestIdx: Int? = nil
        var bestDist = Double.infinity
        for (i, pt) in points.enumerated() {
            let d = hypot(pt.normX - normX, pt.normY - normY)
            if d <= threshold && d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        if let idx = bestIdx {
            pushCurrentSnapshot()
            isDirectGuideMaskActive = false
            isDirty = true
            let side = points[idx].side
            points.remove(at: idx)
            rerunInference(for: side, forceIfNoPoints: (side == .left) ? hasCustomBoxL : hasCustomBoxR)
        }
    }

    private func resolvedOtherCenter(for side: CardPrintSide) -> (normX: Double, normY: Double)? {
        let otherSide: CardPrintSide = (side == .left) ? .right : .left
        let otherMask = (otherSide == .left) ? currentMaskL : currentMaskR
        if let centroid = StereoCardSegmenter.computeMaskCentroid(mask: otherMask, width: maskW, height: maskH) {
            return centroid
        }
        return (otherSide == .left)
            ? (effectiveBoxL ?? baseAnchorBoxL).centerNorm
            : (effectiveBoxR ?? baseAnchorBoxR).centerNorm
    }

    func rerunInference(for side: CardPrintSide, forceIfNoPoints: Bool) {
        guard let cache = embeddingCache else { return }

        let anchorBox = (side == .left) ? baseAnchorBoxL : baseAnchorBoxR
        let otherCenter = resolvedOtherCenter(for: side)
        let allPoints = points

        inferenceTask?.cancel()
        isInferring = true
        inferenceTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                StereoCardSegmenter.shared.predictInteractiveMask(
                    cache: cache,
                    side: side,
                    points: allPoints,
                    anchorBox: anchorBox,
                    otherBoxCenter: otherCenter,
                    useBoxAnchor: true
                )
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.isInferring = false
                guard let res = result else { return }
                if side == .left {
                    self.currentMaskL = res.mask
                    self.currentProbL = res.softProb
                    self.effectiveBoxL = res.effectiveBox
                } else {
                    self.currentMaskR = res.mask
                    self.currentProbR = res.softProb
                    self.effectiveBoxR = res.effectiveBox
                }
                self.lastElapsedMs = res.elapsedMs
                self.rebuildCardPreview()
                self.updateStereoPreview()
            }
        }
    }

    func rerunBothSidesInference() {
        guard let cache = embeddingCache else { return }
        let boxL = baseAnchorBoxL
        let boxR = baseAnchorBoxR
        let allPoints = points
        let otherForL = resolvedOtherCenter(for: .left)

        inferenceTask?.cancel()
        isInferring = true
        inferenceTask = Task {
            let pairRes = await Task.detached(priority: .userInitiated) { () -> (InteractiveMaskResult?, InteractiveMaskResult?) in
                let resL = StereoCardSegmenter.shared.predictInteractiveMask(
                    cache: cache,
                    side: .left,
                    points: allPoints,
                    anchorBox: boxL,
                    otherBoxCenter: otherForL,
                    useBoxAnchor: true
                )
                var otherForR: (normX: Double, normY: Double)? = nil
                if let rL = resL, let cL = StereoCardSegmenter.computeMaskCentroid(mask: rL.mask, width: cache.validW, height: cache.validH) {
                    otherForR = cL
                } else {
                    otherForR = boxL.centerNorm
                }
                let resR = StereoCardSegmenter.shared.predictInteractiveMask(
                    cache: cache,
                    side: .right,
                    points: allPoints,
                    anchorBox: boxR,
                    otherBoxCenter: otherForR,
                    useBoxAnchor: true
                )
                return (resL, resR)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.isInferring = false
                if let l = pairRes.0 {
                    self.currentMaskL = l.mask
                    self.currentProbL = l.softProb
                    self.effectiveBoxL = l.effectiveBox
                }
                if let r = pairRes.1 {
                    self.currentMaskR = r.mask
                    self.currentProbR = r.softProb
                    self.effectiveBoxR = r.effectiveBox
                }
                self.rebuildCardPreview()
                self.updateStereoPreview()
            }
        }
    }

    func currentDirectOverrides() -> (arch: StereoCardSegmenter.ArchShapeParams?, boxes: (left: InteractivePromptBox, right: InteractivePromptBox)?) {
        guard isDirectGuideMaskActive || hasCustomBoxL || hasCustomBoxR else { return (nil, nil) }
        let arch = StereoCardSegmenter.makeGuideArchParams(
            topRyRatio: guideTopArchRatio,
            botRyRatio: guideBotRoundRatio
        )
        return (arch, (left: baseAnchorBoxL, right: baseAnchorBoxR))
    }

    // MARK: - Stereo Window Operations

    func adjustWindowShift(delta: Double) {
        pushCurrentSnapshot()
        windowShiftX = max(-300.0, min(300.0, windowShiftX + delta))
        isDirty = true
        updateStereoPreview()
    }

    func resetWindowShiftToAuto() {
        pushCurrentSnapshot()
        windowShiftX = autoOptimalShiftX
        isDirty = true
        updateStereoPreview()
    }

    func toggleSwap() {
        pushCurrentSnapshot()
        isSwapped.toggle()
        isDirty = true
        updateStereoPreview()
    }

    // MARK: - Preview Rendering (Card & Stereo)

    private func rebuildCardPreview() {
        let w = previewBaseW
        let h = previewBaseH
        guard w > 0, h > 0, previewBaseRGB.count >= w * h * 3,
              maskW > 0, maskH > 0,
              currentProbL.count >= maskW * maskH,
              currentProbR.count >= maskW * maskH else {
            return
        }

        var outRGB = previewBaseRGB
        let style = previewStyle
        let mw = maskW
        let mh = maskH

        for y in 0..<h {
            let fy = (Double(y) + 0.5) / Double(h) * Double(mh) - 0.5
            let y0 = max(0, min(mh - 1, Int(floor(fy))))
            let y1 = max(0, min(mh - 1, y0 + 1))
            let ay = Float(max(0.0, min(1.0, fy - Double(y0))))
            let row0 = y0 * mw
            let row1 = y1 * mw
            let dRow = y * w * 3

            for x in 0..<w {
                let fx = (Double(x) + 0.5) / Double(w) * Double(mw) - 0.5
                let x0 = max(0, min(mw - 1, Int(floor(fx))))
                let x1 = max(0, min(mw - 1, x0 + 1))
                let ax = Float(max(0.0, min(1.0, fx - Double(x0))))

                let w00 = (1 - ax) * (1 - ay)
                let w10 = ax * (1 - ay)
                let w01 = (1 - ax) * ay
                let w11 = ax * ay

                let p00 = row0 + x0, p10 = row0 + x1, p01 = row1 + x0, p11 = row1 + x1
                let pL = currentProbL[p00] * w00 + currentProbL[p10] * w10 + currentProbL[p01] * w01 + currentProbL[p11] * w11
                let pR = currentProbR[p00] * w00 + currentProbR[p10] * w10 + currentProbR[p01] * w01 + currentProbR[p11] * w11

                let idx = dRow + x * 3
                let r = Float(outRGB[idx])
                let g = Float(outRGB[idx + 1])
                let b = Float(outRGB[idx + 2])

                switch style {
                case .overlay:
                    let alpha = max(pL, pR)
                    let dim: Float = 0.45 + 0.55 * min(Float(1.0), max(Float(0.0), (alpha - 0.35) / 0.30))
                    outRGB[idx]     = UInt8(min(255, max(0, Int((r * dim).rounded()))))
                    outRGB[idx + 1] = UInt8(min(255, max(0, Int((g * dim).rounded()))))
                    outRGB[idx + 2] = UInt8(min(255, max(0, Int((b * dim).rounded()))))

                case .whiteCutout:
                    let alpha = max(pL, pR)
                    let softA = min(Float(1.0), max(Float(0.0), (alpha - 0.35) / 0.30))
                    outRGB[idx]     = UInt8(min(255, max(0, Int((r * softA + 255.0 * (1.0 - softA)).rounded()))))
                    outRGB[idx + 1] = UInt8(min(255, max(0, Int((g * softA + 255.0 * (1.0 - softA)).rounded()))))
                    outRGB[idx + 2] = UInt8(min(255, max(0, Int((b * softA + 255.0 * (1.0 - softA)).rounded()))))
                }
            }
        }

        if let cgImg = StereoCardSegmenter.shared.makeCGImage(from: outRGB, width: w, height: h) {
            renderedCardImage = NSImage(cgImage: cgImg, size: NSSize(width: w, height: h))
        }
    }

    func updateStereoPreview() {
        stereoRenderTask?.cancel()
        stereoRenderTask = Task {
            guard previewBaseW > 0, previewBaseH > 0, !previewBaseRGB.isEmpty else { return }

            let cardRGB = previewBaseRGB
            let cw = previewBaseW
            let ch = previewBaseH
            let boxL = baseAnchorBoxL
            let boxR = baseAnchorBoxR
            let shift = windowShiftX
            let swapped = isSwapped
            let mode = stereoPreviewMode

            let result = await Task.detached(priority: .userInitiated) { () -> (NSImage?, Double, Double, Bool)? in
                // 1. ガイド枠から左右写真を簡易クロップ
                let lx0 = max(0, min(cw - 2, Int(boxL.normMinX * Double(cw))))
                let ly0 = max(0, min(ch - 2, Int(boxL.normMinY * Double(ch))))
                let lx1 = max(lx0 + 2, min(cw, Int(boxL.normMaxX * Double(cw))))
                let ly1 = max(ly0 + 2, min(ch, Int(boxL.normMaxY * Double(ch))))
                let lw = lx1 - lx0, lh = ly1 - ly0

                let rx0 = max(0, min(cw - 2, Int(boxR.normMinX * Double(cw))))
                let ry0 = max(0, min(ch - 2, Int(boxR.normMinY * Double(ch))))
                let rx1 = max(rx0 + 2, min(cw, Int(boxR.normMaxX * Double(cw))))
                let ry1 = max(ry0 + 2, min(ch, Int(boxR.normMaxY * Double(ch))))
                let rw = rx1 - rx0, rh = ry1 - ry0

                let targetW = min(lw, rw)
                let targetH = min(lh, rh)
                guard targetW > 8, targetH > 8 else { return nil }

                // 左右RGBクロップ
                var cropL = [UInt8](repeating: 0, count: targetW * targetH * 3)
                var cropR = [UInt8](repeating: 0, count: targetW * targetH * 3)

                for y in 0..<targetH {
                    let srcRowL = (ly0 + y) * cw * 3
                    let srcRowR = (ry0 + y) * cw * 3
                    let dstRow = y * targetW * 3
                    for x in 0..<targetW {
                        let siL = srcRowL + (lx0 + x) * 3
                        let siR = srcRowR + (rx0 + x) * 3
                        let di = dstRow + x * 3
                        cropL[di] = cardRGB[siL]; cropL[di+1] = cardRGB[siL+1]; cropL[di+2] = cardRGB[siL+2]
                        cropR[di] = cardRGB[siR]; cropR[di+1] = cardRGB[siR+1]; cropR[di+2] = cardRGB[siR+2]
                    }
                }

                let effL = swapped ? cropR : cropL
                let effR = swapped ? cropL : cropR

                // 2. windowShiftX の適用 (水平シフト)
                let shiftPx = Int(shift.rounded())
                var shiftedL = effL
                var shiftedR = effR
                if shiftPx != 0 {
                    let absS = min(targetW / 4, abs(shiftPx))
                    let validW = targetW - absS
                    if validW > 16 {
                        var nL = [UInt8](repeating: 0, count: validW * targetH * 3)
                        var nR = [UInt8](repeating: 0, count: validW * targetH * 3)
                        for y in 0..<targetH {
                            let sRow = y * targetW * 3
                            let dRow = y * validW * 3
                            for x in 0..<validW {
                                let siL = sRow + (shiftPx > 0 ? (x + absS) : x) * 3
                                let siR = sRow + (shiftPx > 0 ? x : (x + absS)) * 3
                                let di = dRow + x * 3
                                nL[di] = effL[siL]; nL[di+1] = effL[siL+1]; nL[di+2] = effL[siL+2]
                                nR[di] = effR[siR]; nR[di+1] = effR[siR+1]; nR[di+2] = effR[siR+2]
                            }
                        }
                        shiftedL = nL
                        shiftedR = nR
                    }
                }

                let finalW = shiftedL.count / (targetH * 3)
                guard finalW > 16 else { return nil }

                // 3. アナグリフまたはSBS合成
                let nsImg: NSImage?
                switch mode {
                case .anaglyph:
                    // Color Anaglyph: L(Red), R(Cyan)
                    var ana = [UInt8](repeating: 0, count: finalW * targetH * 3)
                    for i in 0..<(finalW * targetH) {
                        let idx = i * 3
                        ana[idx]     = shiftedL[idx]     // Red: Left
                        ana[idx + 1] = shiftedR[idx + 1] // Green: Right
                        ana[idx + 2] = shiftedR[idx + 2] // Blue: Right
                    }
                    if let cg = StereoCardSegmenter.shared.makeCGImage(from: ana, width: finalW, height: targetH) {
                        nsImg = NSImage(cgImage: cg, size: NSSize(width: finalW, height: targetH))
                    } else { nsImg = nil }

                case .sbs:
                    let sbs = Self.combineSBS(left: shiftedL, right: shiftedR, width: finalW, height: targetH)
                    if let cg = StereoCardSegmenter.shared.makeCGImage(from: sbs, width: finalW * 2, height: targetH) {
                        nsImg = NSImage(cgImage: cg, size: NSSize(width: finalW * 2, height: targetH))
                    } else { nsImg = nil }
                }

                // 4. 視差パーセントの概算（簡易版）
                let nearP = -Double(shiftPx) / Double(finalW) * 100.0
                let farP = nearP + 2.5
                let hasViolation = nearP < -0.8

                return (nsImg, nearP, farP, hasViolation)
            }.value

            guard !Task.isCancelled, let res = result else { return }
            renderedStereoImage = res.0
            nearParallaxPercent = res.1
            farParallaxPercent = res.2
            hasWindowViolationRisk = res.3
        }
    }

    nonisolated private static func combineSBS(left: [UInt8], right: [UInt8], width: Int, height: Int) -> [UInt8] {
        var sbs = [UInt8](repeating: 0, count: width * 2 * height * 3)
        let sbsRowStride = width * 2 * 3
        let srcRowStride = width * 3

        for y in 0..<height {
            let srcOffset = y * srcRowStride
            let dstOffset = y * sbsRowStride
            sbs.replaceSubrange(dstOffset..<(dstOffset + srcRowStride), with: left[srcOffset..<(srcOffset + srcRowStride)])
            sbs.replaceSubrange((dstOffset + srcRowStride)..<(dstOffset + sbsRowStride), with: right[srcOffset..<(srcOffset + srcRowStride)])
        }
        return sbs
    }

    // MARK: - Undo & Snapshots

    func pushCurrentSnapshot() {
        let snap = captureSnapshot()
        undoStack.append(snap)
        if undoStack.count > 30 {
            undoStack.removeFirst()
        }
    }

    func pushSnapshot(_ snap: WorkbenchSnapshot) {
        undoStack.append(snap)
        if undoStack.count > 30 {
            undoStack.removeFirst()
        }
    }

    func captureSnapshot() -> WorkbenchSnapshot {
        WorkbenchSnapshot(
            points: points,
            baseAnchorBoxL: baseAnchorBoxL,
            baseAnchorBoxR: baseAnchorBoxR,
            effectiveBoxL: effectiveBoxL,
            effectiveBoxR: effectiveBoxR,
            hasCustomBoxL: hasCustomBoxL,
            hasCustomBoxR: hasCustomBoxR,
            maskL: currentMaskL,
            probL: currentProbL,
            maskR: currentMaskR,
            probR: currentProbR,
            guideTopArchRatio: guideTopArchRatio,
            guideBotRoundRatio: guideBotRoundRatio,
            isDirectGuideMaskActive: isDirectGuideMaskActive,
            windowShiftX: windowShiftX,
            isSwapped: isSwapped
        )
    }

    func undoLastAction() {
        guard let snap = undoStack.popLast() else { return }
        points = snap.points
        baseAnchorBoxL = snap.baseAnchorBoxL
        baseAnchorBoxR = snap.baseAnchorBoxR
        effectiveBoxL = snap.effectiveBoxL
        effectiveBoxR = snap.effectiveBoxR
        hasCustomBoxL = snap.hasCustomBoxL
        hasCustomBoxR = snap.hasCustomBoxR
        currentMaskL = snap.maskL
        currentProbL = snap.probL
        currentMaskR = snap.maskR
        currentProbR = snap.probR
        guideTopArchRatio = snap.guideTopArchRatio
        guideBotRoundRatio = snap.guideBotRoundRatio
        isDirectGuideMaskActive = snap.isDirectGuideMaskActive
        windowShiftX = snap.windowShiftX
        isSwapped = snap.isSwapped
        isDirty = true
        rebuildCardPreview()
        updateStereoPreview()
        isDirty = false
    }
}
