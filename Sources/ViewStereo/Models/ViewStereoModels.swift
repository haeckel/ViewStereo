import AppKit
import Combine
import CoreGraphics
import ImageIO
import StereoCore
import StereoStudioCore
import SwiftUI
import UniformTypeIdentifiers
import simd

/// アナグリフ合成方式
enum AnaglyphType: Sendable {
    case dubois
    case color
    case gray
}

/// プレビュー表示モード（Trilogy 立体視方式準拠）
enum StereoDisplayMode: Int, CaseIterable, Identifiable {
    case stereoviewCard = 0
    case sbs
    case lrrl
    case dubois
    case colorAnaglyph
    case grayAnaglyph
    case polarized
    case twoD

    var id: Int { rawValue }

    static var stereoModes: [StereoDisplayMode] {
        allCases
    }

    var label: String {
        switch self {
        case .stereoviewCard: return "StereoView"
        case .sbs: return "SBS"
        case .lrrl: return "LR/RL"
        case .dubois: return "Dubois"
        case .colorAnaglyph: return "Color Anaglyph"
        case .grayAnaglyph: return "Gray Anaglyph"
        case .polarized: return "Polarized"
        case .twoD: return "2D"
        }
    }

    var iconName: String {
        switch self {
        case .stereoviewCard: return "photo.artframe"
        case .sbs: return "rectangle.split.2x1"
        case .lrrl: return "square.grid.2x2"
        case .dubois, .colorAnaglyph, .grayAnaglyph: return "eyeglasses"
        case .polarized: return "polarized.glasses"
        case .twoD: return "square"
        }
    }

    var correspondingExportLayout: StereoExportLayout? {
        switch self {
        case .stereoviewCard: return .stereoviewCard
        case .sbs: return .sbs
        case .lrrl: return .lrrl
        case .dubois: return .dubois
        case .colorAnaglyph: return .colorAnaglyph
        case .grayAnaglyph: return .grayAnaglyph
        case .polarized: return .polarized
        case .twoD: return .twoD
        }
    }
}

/// 書き出し立体視方式
enum StereoExportLayout: String, CaseIterable, Identifiable {
    case stereoviewCard = "Stereoview Card"
    case sbs = "SBS"
    case lrrl = "LR/RL (4-Way)"
    case dubois = "Dubois"
    case colorAnaglyph = "Color Anaglyph"
    case grayAnaglyph = "Gray Anaglyph"
    case polarized = "Polarized"
    case twoD = "2D"
    case separateLR = "Separate L/R"
    case spatialPhoto = "Spatial Photo (HEIC)"
    case mpo = "MPO (3D Camera)"

    var id: String { rawValue }

    var supportsCustomImageFormat: Bool {
        switch self {
        case .spatialPhoto, .mpo: return false
        default: return true
        }
    }

    var fixedFormatLabel: String {
        switch self {
        case .spatialPhoto: return "HEIC (MV-HEVC)"
        case .mpo: return "MPO"
        default: return ""
        }
    }

    var correspondingDisplayMode: StereoDisplayMode? {
        switch self {
        case .twoD: return .twoD
        case .sbs: return .sbs
        case .lrrl: return .lrrl
        case .dubois: return .dubois
        case .colorAnaglyph: return .colorAnaglyph
        case .grayAnaglyph: return .grayAnaglyph
        case .polarized: return .polarized
        case .stereoviewCard: return .stereoviewCard
        case .separateLR, .spatialPhoto, .mpo: return nil
        }
    }
}

/// 書き出し画像フォーマット
enum StereoExportImageFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case png = "PNG"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        }
    }
}

/// 自動カラーマッチング設定
enum StereoAutoColorMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case left = "Match to Left"
    case right = "Match to Right"

    var id: String { rawValue }
}

/// バッチ処理のペアリング方式
enum StereoBatchPairingMode: String, CaseIterable, Identifiable {
    case auto = "Auto (L/R Pairs + SBS)"
    case sbsOnly = "SBS Images Only"
    case consecutiveLR = "Consecutive L/R Pairs"

    var id: String { rawValue }
}

/// ステレオカード自動切り出しモード
enum StereoCardMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case cropInner = "Crop Inner"
    case keepArchBlack = "Keep Arch (Black)"

    var id: String { rawValue }
}

/// 現代写真向けの角丸・アーチ枠スタイル
enum StereoFrameStyle: String, CaseIterable, Identifiable {
    case off = "Off"
    case rounded = "Rounded"
    case arch = "Arch"

    var id: String { rawValue }
}

/// バッチ処理完了サマリー
struct BatchCompletionSummary: Equatable {
    let succeeded: Int
    let failed: Int
    let total: Int
    let wasCancelled: Bool
    let outputDirectory: URL
}

/// バッチ処理対象アイテム
struct StereoBatchItem: Sendable {
    let baseName: String
    let displayLabel: String
    let leftURL: URL
    let rightURL: URL? // nil の場合は SBS 単体画像
}

/// アプリ設定（UI大文字モード等）
final class ViewStereoSettings: ObservableObject {
    static let shared = ViewStereoSettings()

    @Published var useLargeTextMode: Bool = false {
        didSet {
            StudioAccessibilityState.shared.useLargeTextMode = useLargeTextMode
        }
    }

    private init() {}
}

/// ViewStereo メイン ViewModel
@MainActor
final class ViewStereoViewModel: ObservableObject {
    // 画像データ
    @Published var displayImage: NSImage? = nil
    @Published var isProcessing: Bool = false
    @Published var statusMessage: String = ""
    @Published var isRestoringPreview: Bool = false
    @Published var restorationProgress: Double = 0.0
    @Published var restorationProgressMessage: String = ""

    // プレビュー・UI状態
    @Published var isBatchSectionExpanded: Bool = true
    @Published var isSwapped: Bool = false {
        didSet {
            if oldValue != isSwapped {
                renderDisplayPreview()
            }
        }
    }
    private var isSyncingLayoutAndMode = false
    @Published var displayMode: StereoDisplayMode = .stereoviewCard {
        didSet {
            if displayMode == .stereoviewCard {
                isCardMountSectionExpanded = true
            }
            if !isSyncingLayoutAndMode, let layout = displayMode.correspondingExportLayout, exportLayout != layout {
                isSyncingLayoutAndMode = true
                exportLayout = layout
                isSyncingLayoutAndMode = false
            }
            renderDisplayPreview()
        }
    }

    // ステレオカード（台紙）再構築・書き出し設定
    @Published var isCardMountSectionExpanded: Bool = true
    @Published var cardMountPreset: StereoCardMountPreset = .originalRemount {
        didSet {
            UserDefaults.standard.set(cardMountPreset.rawValue, forKey: "VS.cardMountPreset")
            renderDisplayPreview()
        }
    }
    @Published var cardSizeSpec: StereoCardSizeSpec = .standard {
        didSet {
            UserDefaults.standard.set(cardSizeSpec.rawValue, forKey: "VS.cardSizeSpec")
            renderDisplayPreview()
        }
    }
    @Published var cardPrintCutStyle: StereoCardPrintCutStyle = .autoFromPreset {
        didSet {
            UserDefaults.standard.set(cardPrintCutStyle.rawValue, forKey: "VS.cardPrintCutStyle")
            renderDisplayPreview()
        }
    }
    @Published var cardCenterGapStyle: StereoCardCenterGapStyle = .autoFromPreset {
        didSet {
            UserDefaults.standard.set(cardCenterGapStyle.rawValue, forKey: "VS.cardCenterGapStyle")
            renderDisplayPreview()
        }
    }
    @Published var cardTextMode: StereoCardTextMode = .ocrAuto {
        didSet {
            UserDefaults.standard.set(cardTextMode.rawValue, forKey: "VS.cardTextMode")
            if cardTextMode == .ocrAuto, oldValue != .ocrAuto, currentMountContext != nil {
                extractTextsFromOriginalCardMount()
            }
            renderDisplayPreview()
        }
    }
    @Published var cardBottomCaption: String = "" {
        didSet { renderDisplayPreview() }
    }
    @Published var cardTopCenterText: String = "" {
        didSet { renderDisplayPreview() }
    }
    @Published var cardLeftMarginText: String = "" {
        didSet { renderDisplayPreview() }
    }
    @Published var cardRightMarginText: String = "" {
        didSet { renderDisplayPreview() }
    }
    @Published var cardUseFilenameAsCaption: Bool = false {
        didSet {
            UserDefaults.standard.set(cardUseFilenameAsCaption, forKey: "VS.cardUseFilenameAsCaption")
            renderDisplayPreview()
        }
    }
    @Published var isRunningCardOCR: Bool = false
    @Published var currentMountContext: StereoCardSegmenter.OriginalCardMountContext? = nil
    private var ocrGeneration: Int = 0

    var hasOriginalCardMount: Bool {
        currentMountContext != nil
    }

    func makeCardMountConfig(filename: String? = nil, preservedArch: Bool? = nil) -> StereoCardMountConfig {
        StereoCardMountConfig(
            preset: cardMountPreset,
            sizeSpec: cardSizeSpec,
            printCutStyle: cardPrintCutStyle,
            centerGapStyle: cardCenterGapStyle,
            textMode: cardTextMode,
            topCenterText: cardTopCenterText,
            bottomCaption: cardBottomCaption,
            leftMarginText: cardLeftMarginText,
            rightMarginText: cardRightMarginText,
            useFilenameAsCaption: cardUseFilenameAsCaption,
            sourceFilename: filename ?? (leftURL?.lastPathComponent ?? ""),
            preservedArchFromAI: preservedArch ?? hasPreservedArch
        )
    }

    func clearCardMountTexts() {
        ocrGeneration += 1
        isRunningCardOCR = false
        cardBottomCaption = ""
        cardTopCenterText = ""
        cardLeftMarginText = ""
        cardRightMarginText = ""
    }

    func extractTextsFromOriginalCardMount() {
        guard let ctx = currentMountContext else { return }
        ocrGeneration += 1
        let gen = ocrGeneration
        isRunningCardOCR = true
        statusMessage = "Recognizing text on original stereoview mount (Vision OCR)..."
        Task {
            let recognized = await StereoCardMountRenderer.recognizeTextsFromOriginalMount(ctx: ctx)
            guard gen == self.ocrGeneration else { return }
            isRunningCardOCR = false
            cardBottomCaption = recognized.bottomCaption
            cardTopCenterText = recognized.topCenter
            cardLeftMarginText = recognized.leftMargin
            cardRightMarginText = recognized.rightMargin
            let foundCount = [recognized.bottomCaption, recognized.topCenter, recognized.leftMargin, recognized.rightMargin].filter { !$0.isEmpty }.count
            statusMessage = foundCount > 0
                ? "OCR extracted \(foundCount) text zone(s) from card mount."
                : "No readable text detected on card mount."
            renderDisplayPreview()
        }
    }

    // 位置合わせ・基本設定（自動実行 & 永続化）
    @Published var autoAlignOnLoad: Bool = true {
        didSet { UserDefaults.standard.set(autoAlignOnLoad, forKey: "VS.autoAlignOnLoad") }
    }
    @Published var autoColorMode: StereoAutoColorMode = .left {
        didSet { UserDefaults.standard.set(autoColorMode.rawValue, forKey: "VS.autoColorMode") }
    }
    @Published var keepOriginalAspectRatio: Bool = false {
        didSet { UserDefaults.standard.set(keepOriginalAspectRatio, forKey: "VS.keepOriginalAspectRatio") }
    }
    @Published var usePersonMotionMask: Bool = true {
        didSet { UserDefaults.standard.set(usePersonMotionMask, forKey: "VS.usePersonMotionMask") }
    }
    @Published var useAttentionSaliency: Bool = true {
        didSet { UserDefaults.standard.set(useAttentionSaliency, forKey: "VS.useAttentionSaliency") }
    }
    @Published var removeUnilateralNoise: Bool = true {
        didSet {
            UserDefaults.standard.set(removeUnilateralNoise, forKey: "VS.removeUnilateralNoise")
            if oldValue != removeUnilateralNoise {
                applyUnilateralNoiseToggle()
            }
        }
    }
    @Published var stereoCardMode: StereoCardMode = .cropInner {
        didSet {
            UserDefaults.standard.set(stereoCardMode.rawValue, forKey: "VS.stereoCardMode")
            if oldValue != stereoCardMode { reloadCurrentSBSIfNeeded() }
        }
    }
    @Published var useCoreMLCardSegmentation: Bool = true {
        didSet {
            UserDefaults.standard.set(useCoreMLCardSegmentation, forKey: "VS.useCoreMLCardSegmentation")
            if oldValue != useCoreMLCardSegmentation { reloadCurrentSBSIfNeeded() }
        }
    }
    @Published var coreMLRefinerModel: CoreMLRefinerModel = .mobileSAM {
        didSet {
            UserDefaults.standard.set(coreMLRefinerModel.rawValue, forKey: "VS.coreMLRefinerModel")
            if oldValue != coreMLRefinerModel { reloadCurrentSBSIfNeeded() }
        }
    }
    @Published var frameStyle: StereoFrameStyle = .off {
        didSet {
            UserDefaults.standard.set(frameStyle.rawValue, forKey: "VS.frameStyle")
            renderDisplayPreview()
        }
    }

    // 19世紀古写真・退色＆階調復元設定（画像ごとにリセットされる非破壊ポストプロセス）
    @Published var isRestorationSectionExpanded: Bool = true
    private var isApplyingRestorationBatch: Bool = false
    @Published var restorationPrintTone: VintagePrintTone = .original {
        didSet {
            if !isApplyingRestorationBatch { renderDisplayPreview() }
        }
    }
    @Published var restorationAutoLevel: Double = 0.0 {
        didSet {
            if !isApplyingRestorationBatch { renderDisplayPreview() }
        }
    }
    @Published var restorationLocalContrast: Double = 0.0 {
        didSet {
            if !isApplyingRestorationBatch { renderDisplayPreview() }
        }
    }
    @Published var restorationDeblurStrength: Double = 0.0 {
        didSet {
            if !isApplyingRestorationBatch { renderDisplayPreview() }
        }
    }
    @Published var restorationTextureProtection: Double = 60.0 {
        didSet {
            if !isApplyingRestorationBatch { renderDisplayPreview() }
        }
    }
    @Published var isShowingBeforeRestoration: Bool = false {
        didSet {
            if oldValue != isShowingBeforeRestoration && !isApplyingRestorationBatch {
                renderDisplayPreview()
            }
        }
    }

    var isCoreMLDeblurAvailable: Bool {
        Self.resolveDeblurModelURL() != nil
    }

    var hasActiveVintageRestoration: Bool {
        !makeVintageRestorationOptions(ignorePreviewToggle: true).isIdentity
            || !makeDetailRestorationOptions(ignorePreviewToggle: true).isIdentity
    }

    func makeVintageRestorationOptions(ignorePreviewToggle: Bool = false) -> VintageRestorationOptions {
        if !ignorePreviewToggle && isShowingBeforeRestoration {
            return VintageRestorationOptions()
        }
        return VintageRestorationOptions(
            autoLevelStrength: min(1.0, max(0.0, restorationAutoLevel / 100.0)),
            localContrastStrength: min(1.0, max(0.0, restorationLocalContrast / 100.0)),
            printTone: restorationPrintTone
        )
    }

    func makeDetailRestorationOptions(ignorePreviewToggle: Bool = false) -> StereoDetailRestorationOptions {
        if !ignorePreviewToggle && isShowingBeforeRestoration {
            return StereoDetailRestorationOptions(deblurStrength: 0.0, textureProtection: restorationTextureProtection / 100.0)
        }
        return StereoDetailRestorationOptions(
            deblurStrength: min(1.0, max(0.0, restorationDeblurStrength / 100.0)),
            textureProtection: min(1.0, max(0.0, restorationTextureProtection / 100.0))
        )
    }

    nonisolated private static func resolveDeblurModelURL() -> URL? {
        if let u = Bundle.main.url(forResource: "NAFNetDeblur", withExtension: "mlmodelc") { return u }
        if let u = Bundle.main.url(forResource: "NAFNetDeblur", withExtension: "mlpackage") { return u }
        #if SWIFT_PACKAGE
        if let u = Bundle.module.url(forResource: "NAFNetDeblur", withExtension: "mlmodelc") { return u }
        if let u = Bundle.module.url(forResource: "NAFNetDeblur", withExtension: "mlpackage") { return u }
        #endif
        return nil
    }

    nonisolated private static func applyVintagePipeline(
        left: [UInt8],
        right: [UInt8],
        width: Int,
        height: Int,
        toneOptions: VintageRestorationOptions,
        detailOptions: StereoDetailRestorationOptions,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> (left: [UInt8], right: [UInt8]) {
        var curL = left
        var curR = right
        if !detailOptions.isIdentity {
            let detailed = StereoDetailRestorer.restorePair(
                leftRGB: curL,
                rightRGB: curR,
                width: width,
                height: height,
                options: detailOptions,
                modelURL: resolveDeblurModelURL(),
                progress: { p in
                    progress?(toneOptions.isIdentity ? p : p * 0.85)
                }
            )
            curL = detailed.left
            curR = detailed.right
        }
        if !toneOptions.isIdentity {
            let toned = VintageToneRestorer.restorePair(leftRGB: curL, rightRGB: curR, width: width, height: height, options: toneOptions)
            curL = toned.left
            curR = toned.right
            progress?(1.0)
        }
        return (curL, curR)
    }

    func applyVintage19thCenturyPreset() {
        isApplyingRestorationBatch = true
        isShowingBeforeRestoration = false
        restorationPrintTone = .albumenSepia
        restorationAutoLevel = 80.0
        restorationLocalContrast = 45.0
        restorationDeblurStrength = 35.0
        restorationTextureProtection = 65.0
        isApplyingRestorationBatch = false
        statusMessage = "Applied 19th-Century Albumen preset."
        renderDisplayPreview()
    }

    func resetVintageRestoration(renderPreview: Bool = true) {
        isApplyingRestorationBatch = true
        isShowingBeforeRestoration = false
        restorationPrintTone = .original
        restorationAutoLevel = 0.0
        restorationLocalContrast = 0.0
        restorationDeblurStrength = 0.0
        restorationTextureProtection = 60.0
        isApplyingRestorationBatch = false
        if renderPreview {
            statusMessage = "Reset vintage restoration settings."
            renderDisplayPreview()
        }
    }

    // ステレオウィンドウ設定（px単位）
    @Published var windowShiftX: Double = 0.0
    @Published var autoOptimalShiftX: Double = 0.0
    @Published var hasWindowViolationRisk: Bool = false
    @Published var requiresFloatingWindow: Bool = false
    @Published var maxDisparityPercent: Double = 0.0

    // テレメトリー
    @Published var processingTimeMs: Double = 0.0
    @Published var verticalRMSE: Double = 0.0
    @Published var matchCount: Int = 0
    @Published var inlierCount: Int = 0
    @Published var imageWidth: Int = 0
    @Published var imageHeight: Int = 0
    @Published var croppedWidth: Int = 0
    @Published var croppedHeight: Int = 0
    @Published var isAligned: Bool = false

    // 書き出し設定（立体視方式 × 画像フォーマット）
    @Published var exportLayout: StereoExportLayout = .stereoviewCard {
        didSet {
            UserDefaults.standard.set(exportLayout.rawValue, forKey: "VS.exportLayout")
            if !isSyncingLayoutAndMode, let mode = exportLayout.correspondingDisplayMode, displayMode != mode {
                isSyncingLayoutAndMode = true
                displayMode = mode
                isSyncingLayoutAndMode = false
            }
        }
    }
    @Published var exportImageFormat: StereoExportImageFormat = .jpeg {
        didSet { UserDefaults.standard.set(exportImageFormat.rawValue, forKey: "VS.exportImageFormat") }
    }

    // バッチ処理状態
    @Published var batchInputFolder: URL? = nil
    @Published var batchOutputFolder: URL? = nil
    @Published var batchPairingMode: StereoBatchPairingMode = .auto
    @Published var batchSaveReport: Bool = false
    @Published var isBatchRunning: Bool = false
    @Published var batchProgress: Double = 0.0
    @Published var batchTotalCount: Int = 0
    @Published var batchCompletedCount: Int = 0
    @Published var batchFailedCount: Int = 0
    @Published var batchCurrentFile: String = ""
    @Published var batchCompletionSummary: BatchCompletionSummary? = nil
    private var batchTask: Task<Void, Never>? = nil

    // 内部バッファ（元画像・補正後画像）
    private var rawLeftRGB: [UInt8]? = nil
    private var rawRightRGB: [UInt8]? = nil
    private var alignedLeftRGB: [UInt8]? = nil
    private var alignedRightRGB: [UInt8]? = nil

    // プレビュー用軽量バッファ（長辺最大 1440px）
    nonisolated private static let previewMaxDimension = 1440
    nonisolated private static let realtimeDragMaxDimension = 1024
    private var previewRawLeftRGB: [UInt8]? = nil
    private var previewRawRightRGB: [UInt8]? = nil
    private var previewAlignedLeftRGB: [UInt8]? = nil
    private var previewAlignedRightRGB: [UInt8]? = nil
    private var previewWidth: Int = 0
    private var previewHeight: Int = 0
    private var previewCroppedWidth: Int = 0
    private var previewCroppedHeight: Int = 0

    // ドラッグ中 60fps 追従用の平行化済み（tx=0）軽量バッファ
    private var rectifiedPreviewLeftRGB: [UInt8]? = nil
    private var rectifiedPreviewRightRGB: [UInt8]? = nil
    private var rectifiedPreviewWidth: Int = 0
    private var rectifiedPreviewHeight: Int = 0

    // リアルタイムプレビュー用コアレッシング制御
    private var isPreviewWarping: Bool = false
    private var needsAnotherPreviewWarp: Bool = false
    private var previewRenderGeneration: Int = 0
    private var lastFullResShiftX: Double = 0.0
    private var lastFullResRemoveNoise: Bool = true
    private var hasPreservedArch: Bool = false

    private var lastMatches: [StereoMatchPoint] = []
    private var lastRectResult: RectificationResult? = nil
    private var lastCommonPolygon: [SIMD2<Double>] = []
    private var lastDisparitySamples: [DisparitySample] = []
    private var lastRawSaliencyMap: NormalizedFloatMap? = nil

    var leftURL: URL? = nil
    var rightURL: URL? = nil
    var isSingleSBSInput: Bool = false

    private let metalRenderer: MetalWarpRenderer?

    init() {
        self.metalRenderer = try? MetalWarpRenderer()
        let ud = UserDefaults.standard
        if ud.object(forKey: "VS.autoAlignOnLoad") != nil {
            self.autoAlignOnLoad = ud.bool(forKey: "VS.autoAlignOnLoad")
        }
        if let cm = ud.string(forKey: "VS.autoColorMode"), let mode = StereoAutoColorMode(rawValue: cm) {
            self.autoColorMode = mode
        }
        if ud.object(forKey: "VS.keepOriginalAspectRatio") != nil {
            self.keepOriginalAspectRatio = ud.bool(forKey: "VS.keepOriginalAspectRatio")
        }
        if ud.object(forKey: "VS.usePersonMotionMask") != nil {
            self.usePersonMotionMask = ud.bool(forKey: "VS.usePersonMotionMask")
        }
        if ud.object(forKey: "VS.useAttentionSaliency") != nil {
            self.useAttentionSaliency = ud.bool(forKey: "VS.useAttentionSaliency")
        }
        if ud.object(forKey: "VS.removeUnilateralNoise") != nil {
            self.removeUnilateralNoise = ud.bool(forKey: "VS.removeUnilateralNoise")
        }
        if let cm = ud.string(forKey: "VS.stereoCardMode"), let cardMode = StereoCardMode(rawValue: cm) {
            self.stereoCardMode = cardMode
        }
        if ud.object(forKey: "VS.useCoreMLCardSegmentation") != nil {
            self.useCoreMLCardSegmentation = ud.bool(forKey: "VS.useCoreMLCardSegmentation")
        }
        if let rm = ud.string(forKey: "VS.coreMLRefinerModel"), let refiner = CoreMLRefinerModel(rawValue: rm) {
            self.coreMLRefinerModel = refiner
        }
        if let fs = ud.string(forKey: "VS.frameStyle"), let style = StereoFrameStyle(rawValue: fs) {
            self.frameStyle = style
        }
        if let el = ud.string(forKey: "VS.exportLayout"), let layout = StereoExportLayout(rawValue: el) {
            self.isSyncingLayoutAndMode = true
            self.exportLayout = layout
            if let mode = layout.correspondingDisplayMode {
                self.displayMode = mode
            }
            self.isSyncingLayoutAndMode = false
        } else if let legacy = ud.string(forKey: "VS.exportFormat") {
            self.isSyncingLayoutAndMode = true
            switch legacy {
            case "SBS (JPEG)":
                self.exportLayout = .sbs; self.exportImageFormat = .jpeg
            case "SBS (PNG)":
                self.exportLayout = .sbs; self.exportImageFormat = .png
            case "Separate L/R (PNG)":
                self.exportLayout = .separateLR; self.exportImageFormat = .png
            case "Anaglyph (PNG)":
                self.exportLayout = .grayAnaglyph; self.exportImageFormat = .png
            case "Spatial Photo (HEIC)":
                self.exportLayout = .spatialPhoto
            case "MPO (3D Camera)":
                self.exportLayout = .mpo
            default:
                break
            }
            if let mode = self.exportLayout.correspondingDisplayMode {
                self.displayMode = mode
            }
            self.isSyncingLayoutAndMode = false
        }
        if let eif = ud.string(forKey: "VS.exportImageFormat"), let imgFmt = StereoExportImageFormat(rawValue: eif) {
            self.exportImageFormat = imgFmt
        }
        if let cmp = ud.string(forKey: "VS.cardMountPreset"), let preset = StereoCardMountPreset(rawValue: cmp) {
            self.cardMountPreset = preset
        }
        if let css = ud.string(forKey: "VS.cardSizeSpec"), let sizeSpec = StereoCardSizeSpec(rawValue: css) {
            self.cardSizeSpec = sizeSpec
        }
        if let cpc = ud.string(forKey: "VS.cardPrintCutStyle"), let cut = StereoCardPrintCutStyle(rawValue: cpc) {
            self.cardPrintCutStyle = cut
        }
        if let ccg = ud.string(forKey: "VS.cardCenterGapStyle"), let gap = StereoCardCenterGapStyle(rawValue: ccg) {
            self.cardCenterGapStyle = gap
        }
        if let ctm = ud.string(forKey: "VS.cardTextMode") {
            if let tm = StereoCardTextMode(rawValue: ctm) {
                self.cardTextMode = tm
            } else {
                self.cardTextMode = .ocrAuto
            }
        }
        if ud.object(forKey: "VS.cardUseFilenameAsCaption") != nil {
            self.cardUseFilenameAsCaption = ud.bool(forKey: "VS.cardUseFilenameAsCaption")
        }
        if self.displayMode != .stereoviewCard {
            self.isCardMountSectionExpanded = false
        }
    }

    var currentSourceName: String {
        if let l = leftURL {
            if let r = rightURL, r != l {
                return "\(l.lastPathComponent) + \(r.lastPathComponent)"
            }
            return l.lastPathComponent
        }
        return ""
    }

    var hasLoadedImages: Bool {
        rawLeftRGB != nil && rawRightRGB != nil
    }

    var activeLeftRGB: [UInt8]? { alignedLeftRGB ?? rawLeftRGB }
    var activeRightRGB: [UInt8]? { alignedRightRGB ?? rawRightRGB }
    var activeWidth: Int { isAligned ? croppedWidth : imageWidth }
    var activeHeight: Int { isAligned ? croppedHeight : imageHeight }

    private var activePreviewLeftRGB: [UInt8]? { previewAlignedLeftRGB ?? previewRawLeftRGB }
    private var activePreviewRightRGB: [UInt8]? { previewAlignedRightRGB ?? previewRawRightRGB }
    private var activePreviewWidth: Int { isAligned ? previewCroppedWidth : previewWidth }
    private var activePreviewHeight: Int { isAligned ? previewCroppedHeight : previewHeight }

    // MARK: - Image Loading (EXIF Orientation Normalized)

    nonisolated private static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tif", "tiff", "bmp", "heic",
        "mpo", "webp",
        "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "pef", "srw", "raw"
    ]

    func openImagesPanel() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.jpeg, .png, .tiff, .bmp, .heic, .webP, .rawImage]
        if let mpoType = UTType(filenameExtension: "mpo") {
            types.append(mpoType)
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            handleDroppedURLs(panel.urls)
        }
    }

    func handleDroppedURLs(_ urls: [URL]) {
        if let dir = urls.first(where: { $0.hasDirectoryPath }) {
            batchInputFolder = dir
            batchOutputFolder = dir.appendingPathComponent("ViewStereo_Output", isDirectory: true)
            isBatchSectionExpanded = true
            startBatchProcessing(inputDir: dir)
            return
        }
        let filtered = urls.filter { Self.supportedImageExtensions.contains($0.pathExtension.lowercased()) }
        if filtered.count >= 2 {
            loadSeparateImages(left: filtered[0], right: filtered[1])
        } else if let single = filtered.first {
            loadSingleSBSImage(url: single)
        }
    }

    func reloadCurrentSBSIfNeeded() {
        guard !isProcessing, isSingleSBSInput, let url = leftURL else { return }
        loadSingleSBSImage(url: url, resetRestoration: false)
    }

    func loadSingleSBSImage(url: URL, resetRestoration: Bool = true) {
        batchCompletionSummary = nil
        if resetRestoration {
            resetVintageRestoration(renderPreview: false)
        }
        if cardTextMode != .manualTypeset {
            clearCardMountTexts()
        }
        leftURL = url
        rightURL = url
        isSingleSBSInput = true
        isProcessing = true
        let cardMode = stereoCardMode
        let useCoreML = useCoreMLCardSegmentation
        let refiner = coreMLRefinerModel
        statusMessage = "Loading image..."

        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> ([UInt8], [UInt8], Int, Int, [UInt8], [UInt8], Int, Int, Bool, Bool, StereoCardSegmenter.OriginalCardMountContext?)? in
                // 1. MPO / Apple 空間写真 HEIC のマルチフレームステレオコンテナを優先判定
                if let (lPair, rPair, pw0, ph0) = Self.loadStereoPairFromContainer(url: url) {
                    let (pL, pw, ph) = Self.downsampleForPreview(lPair, width: pw0, height: ph0, maxDim: Self.previewMaxDimension)
                    let (pR, _, _) = Self.downsampleForPreview(rPair, width: pw0, height: ph0, maxDim: Self.previewMaxDimension)
                    return (lPair, rPair, pw0, ph0, pL, pR, pw, ph, true, false, nil)
                }

                // 2. 通常の単一画像（ステレオカード処理または SBS 分割）
                guard let (rgb, fw, fh) = Self.loadNormalizedRGB(url: url), fw >= 64 else {
                    return nil
                }
                let l: [UInt8]
                let r: [UInt8]
                let w: Int
                let h: Int
                var preservedArch = false
                var mountCtx: StereoCardSegmenter.OriginalCardMountContext? = nil
                let extMode: StereoCardCropper.ExtractionMode = (cardMode == .keepArchBlack) ? .keepArchBlack : .cropInner
                if cardMode != .off,
                   let card = (useCoreML ? StereoCardSegmenter.shared.extractPhotoPair(from: rgb, width: fw, height: fh, mode: extMode, refiner: refiner) : nil)
                           ?? StereoCardCropper.extractPhotoPair(from: rgb, width: fw, height: fh, mode: extMode) {
                    l = card.leftRGB
                    r = card.rightRGB
                    w = card.width
                    h = card.height
                    preservedArch = card.preservedArch
                    mountCtx = StereoCardSegmenter.shared.currentMountContext
                } else {
                    w = fw / 2
                    h = fh
                    var tmpL = [UInt8](repeating: 0, count: w * fh * 3)
                    var tmpR = [UInt8](repeating: 0, count: w * fh * 3)
                    for y in 0..<fh {
                        let srcRow = y * fw * 3
                        let dstRow = y * w * 3
                        tmpL[dstRow..<(dstRow + w * 3)] = rgb[srcRow..<(srcRow + w * 3)]
                        tmpR[dstRow..<(dstRow + w * 3)] = rgb[(srcRow + w * 3)..<(srcRow + w * 6)]
                    }
                    l = tmpL
                    r = tmpR
                }
                let (pL, pw, ph) = Self.downsampleForPreview(l, width: w, height: h, maxDim: Self.previewMaxDimension)
                let (pR, _, _) = Self.downsampleForPreview(r, width: w, height: h, maxDim: Self.previewMaxDimension)
                return (l, r, w, h, pL, pR, pw, ph, false, preservedArch, mountCtx)
            }.value

            guard let (l, r, w, fh, pL, pR, pw, ph, isContainerStereo, preservedArch, mountCtx) = loaded else {
                isProcessing = false
                statusMessage = "Failed to load image."
                return
            }

            isSingleSBSInput = !isContainerStereo
            hasPreservedArch = preservedArch
            currentMountContext = mountCtx
            if cardTextMode == .ocrAuto {
                clearCardMountTexts()
            }
            rawLeftRGB = l
            rawRightRGB = r
            alignedLeftRGB = nil
            alignedRightRGB = nil
            previewRawLeftRGB = pL
            previewRawRightRGB = pR
            previewAlignedLeftRGB = nil
            previewAlignedRightRGB = nil
            rectifiedPreviewLeftRGB = nil
            rectifiedPreviewRightRGB = nil
            previewWidth = pw
            previewHeight = ph
            previewCroppedWidth = pw
            previewCroppedHeight = ph
            imageWidth = w
            imageHeight = fh
            croppedWidth = w
            croppedHeight = fh
            isAligned = false
            lastMatches = []
            lastRectResult = nil
            lastDisparitySamples = []
            lastRawSaliencyMap = nil
            windowShiftX = 0
            autoOptimalShiftX = 0
            lastFullResShiftX = 0
            isProcessing = false
            statusMessage = isContainerStereo ? "Loaded Stereo Container (\(w)×\(fh))" : "Loaded SBS (\(w)×\(fh))"
            if cardTextMode == .ocrAuto, mountCtx != nil {
                extractTextsFromOriginalCardMount()
            }
            if autoAlignOnLoad {
                runAutoAlignment()
            } else {
                renderDisplayPreview()
            }
        }
    }

    func loadSeparateImages(left: URL, right: URL) {
        batchCompletionSummary = nil
        resetVintageRestoration(renderPreview: false)
        if cardTextMode != .manualTypeset {
            clearCardMountTexts()
        }
        leftURL = left
        rightURL = right
        isSingleSBSInput = false
        isProcessing = true
        statusMessage = "Loading L/R images..."

        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> ([UInt8], [UInt8], Int, Int, [UInt8], [UInt8], Int, Int)? in
                guard let (lRGB, lw, lh) = Self.loadNormalizedRGB(url: left),
                      let (rRGBRaw, rw, rh) = Self.loadNormalizedRGB(url: right) else {
                    return nil
                }
                let rRGB = (lw == rw && lh == rh) ? rRGBRaw : Self.resizeBilinearRGB(rRGBRaw, sw: rw, sh: rh, dw: lw, dh: lh)
                let (pL, pw, ph) = Self.downsampleForPreview(lRGB, width: lw, height: lh, maxDim: Self.previewMaxDimension)
                let (pR, _, _) = Self.downsampleForPreview(rRGB, width: lw, height: lh, maxDim: Self.previewMaxDimension)
                return (lRGB, rRGB, lw, lh, pL, pR, pw, ph)
            }.value

            guard let (lRGB, rRGB, lw, lh, pL, pR, pw, ph) = loaded else {
                isProcessing = false
                statusMessage = "Failed to load images."
                return
            }

            rawLeftRGB = lRGB
            rawRightRGB = rRGB
            hasPreservedArch = false
            currentMountContext = nil
            if cardTextMode == .ocrAuto {
                clearCardMountTexts()
            }
            alignedLeftRGB = nil
            alignedRightRGB = nil
            previewRawLeftRGB = pL
            previewRawRightRGB = pR
            previewAlignedLeftRGB = nil
            previewAlignedRightRGB = nil
            rectifiedPreviewLeftRGB = nil
            rectifiedPreviewRightRGB = nil
            previewWidth = pw
            previewHeight = ph
            previewCroppedWidth = pw
            previewCroppedHeight = ph
            imageWidth = lw
            imageHeight = lh
            croppedWidth = lw
            croppedHeight = lh
            isAligned = false
            lastMatches = []
            lastRectResult = nil
            lastDisparitySamples = []
            lastRawSaliencyMap = nil
            windowShiftX = 0
            autoOptimalShiftX = 0
            lastFullResShiftX = 0
            isProcessing = false
            statusMessage = "Loaded L/R (\(lw)×\(lh))"
            if autoAlignOnLoad {
                runAutoAlignment()
            } else {
                renderDisplayPreview()
            }
        }
    }

    func swapLeftRight() {
        guard !isProcessing else { return }
        isSwapped.toggle()
        statusMessage = isSwapped ? "Swapped Left/Right" : "Restored Original Left/Right"
    }

    func resetAlignment() {
        alignedLeftRGB = nil
        alignedRightRGB = nil
        previewAlignedLeftRGB = nil
        previewAlignedRightRGB = nil
        rectifiedPreviewLeftRGB = nil
        rectifiedPreviewRightRGB = nil
        previewCroppedWidth = previewWidth
        previewCroppedHeight = previewHeight
        croppedWidth = imageWidth
        croppedHeight = imageHeight
        isAligned = false
        lastRectResult = nil
        lastDisparitySamples = []
        lastRawSaliencyMap = nil
        windowShiftX = 0
        autoOptimalShiftX = 0
        lastFullResShiftX = 0
        hasWindowViolationRisk = false
        requiresFloatingWindow = false
        maxDisparityPercent = 0
        verticalRMSE = 0
        inlierCount = 0
        statusMessage = "Reset to original images."
        renderDisplayPreview()
    }

    // MARK: - Auto Alignment + Intelligent Window Pipeline

    private struct AlignmentPipelineOutput: Sendable {
        let warpedL: [UInt8]
        let warpedR: [UInt8]
        let cw: Int
        let ch: Int
        let prevWarpedL: [UInt8]
        let prevWarpedR: [UInt8]
        let prevCW: Int
        let prevCH: Int
        let rectPrevL: [UInt8]
        let rectPrevR: [UInt8]
        let rectPrevW: Int
        let rectPrevH: Int
        let matches: [StereoMatchPoint]
        let rectRes: RectificationResult
        let commonPoly: [SIMD2<Double>]
        let samples: [DisparitySample]
        let saliencyMap: NormalizedFloatMap?
        let windowDecision: StereoWindowDecision
        let elapsedMs: Double
        let dispRangePct: Double
    }

    private enum AlignmentPipelineError: Error {
        case notEnoughMatches(Int)
        case rectificationFailed
        case projectionFailed
        case noValidInteriorRect
        case metalWarpFailed
    }

    func runAutoAlignment() {
        guard let lRGB = rawLeftRGB, let rRGB = rawRightRGB else { return }
        let w = imageWidth, h = imageHeight
        let useMask = usePersonMotionMask
        let useSaliency = useAttentionSaliency
        let keepAR = keepOriginalAspectRatio
        let colorMode = autoColorMode
        let removeNoise = removeUnilateralNoise
        let preserveArch = hasPreservedArch
        let renderer = metalRenderer

        isProcessing = true
        statusMessage = "Aligning & analyzing stereo window..."

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.executeAlignmentPipeline(
                    lRGB: lRGB,
                    rRGB: rRGB,
                    width: w,
                    height: h,
                    useMask: useMask,
                    useSaliency: useSaliency,
                    keepAR: keepAR,
                    colorMode: colorMode,
                    removeNoise: removeNoise,
                    preserveArch: preserveArch,
                    renderer: renderer
                )
            }.value

            switch result {
            case .failure(let err):
                isProcessing = false
                switch err {
                case .notEnoughMatches(let count):
                    statusMessage = "Not enough feature matches (\(count))."
                case .rectificationFailed:
                    statusMessage = "Rectification failed to converge."
                case .projectionFailed:
                    statusMessage = "Failed to project bounding corners."
                case .noValidInteriorRect:
                    statusMessage = "No valid interior rectangle found."
                case .metalWarpFailed:
                    statusMessage = "Metal warp failed."
                }
            case .success(let out):
                applyAlignmentOutput(out)
            }
        }
    }

    private func applyAlignmentOutput(_ out: AlignmentPipelineOutput) {
        alignedLeftRGB = out.warpedL
        alignedRightRGB = out.warpedR
        croppedWidth = out.cw
        croppedHeight = out.ch
        previewAlignedLeftRGB = out.prevWarpedL
        previewAlignedRightRGB = out.prevWarpedR
        previewCroppedWidth = out.prevCW
        previewCroppedHeight = out.prevCH
        rectifiedPreviewLeftRGB = out.rectPrevL
        rectifiedPreviewRightRGB = out.rectPrevR
        rectifiedPreviewWidth = out.rectPrevW
        rectifiedPreviewHeight = out.rectPrevH
        isAligned = true
        lastMatches = out.matches
        lastRectResult = out.rectRes
        lastCommonPolygon = out.commonPoly
        lastDisparitySamples = out.samples
        lastRawSaliencyMap = out.saliencyMap
        matchCount = out.matches.count
        inlierCount = out.rectRes.inlierCount
        verticalRMSE = out.rectRes.verticalRMSEPixels
        processingTimeMs = out.elapsedMs
        autoOptimalShiftX = out.windowDecision.optimalShiftX
        windowShiftX = out.windowDecision.optimalShiftX
        lastFullResShiftX = out.windowDecision.optimalShiftX
        lastFullResRemoveNoise = removeUnilateralNoise
        hasWindowViolationRisk = out.windowDecision.hasWindowViolationRisk
        requiresFloatingWindow = out.windowDecision.requiresFloatingWindow
        maxDisparityPercent = out.dispRangePct
        isProcessing = false
        statusMessage = String(format: "Aligned in %.1f ms | vRMSE: %.3f px", out.elapsedMs, out.rectRes.verticalRMSEPixels)
        renderDisplayPreview()
    }

    nonisolated private static func executeAlignmentPipeline(
        lRGB: [UInt8],
        rRGB: [UInt8],
        width w: Int,
        height h: Int,
        useMask: Bool,
        useSaliency: Bool,
        keepAR: Bool,
        colorMode: StereoAutoColorMode,
        removeNoise: Bool,
        preserveArch: Bool,
        renderer: MetalWarpRenderer?
    ) -> Result<AlignmentPipelineOutput, AlignmentPipelineError> {
        let startTime = CFAbsoluteTimeGetCurrent()

        // 1 & 2. SIFT 特徴点抽出・マッチングと Vision 推論（動体マスク L/R・Saliency）を同時並列実行
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        var matches: [StereoMatchPoint] = []
        var maskL: NormalizedFloatMap? = nil
        var maskR: NormalizedFloatMap? = nil
        var saliencyMap: NormalizedFloatMap? = nil

        group.enter()
        queue.async {
            matches = SiftFeatureMatcher.detectAndMatch(leftRGB: lRGB, rightRGB: rRGB, width: w, height: h)
            group.leave()
        }

        // Vision は内部で低解像度リサイズするため、長辺最大 1024px で生成してメモリ転送を 1/15 に削減
        let (vL, vw, vh) = downsampleForPreview(lRGB, width: w, height: h, maxDim: realtimeDragMaxDimension)
        let (vR, _, _) = downsampleForPreview(rRGB, width: w, height: h, maxDim: realtimeDragMaxDimension)

        if let cgL = makeCGImage(from: vL, width: vw, height: vh),
           let cgR = makeCGImage(from: vR, width: vw, height: vh) {
            if useMask {
                group.enter()
                queue.async {
                    maskL = try? VisionAnalyzer.extractPersonMask(from: cgL)
                    group.leave()
                }
                group.enter()
                queue.async {
                    maskR = try? VisionAnalyzer.extractPersonMask(from: cgR)
                    group.leave()
                }
            }
            group.enter()
            queue.async {
                saliencyMap = try? VisionAnalyzer.extractAttentionSaliency(from: cgL)
                group.leave()
            }
        }

        group.wait()

        guard matches.count >= 4 else {
            return .failure(.notEnoughMatches(matches.count))
        }

        // アーチ角丸保持時は最外周 2.5% および黒マスク境界（半径 10px 以内に純黒マスク画素がある位置）の特徴点を除外
        if preserveArch {
            let ex0 = Double(w) * 0.025, ex1 = Double(w) * 0.975
            let ey0 = Double(h) * 0.025, ey1 = Double(h) * 0.975
            func isNearBlackMask(_ rgb: [UInt8], px: Double, py: Double) -> Bool {
                let cx = Int(px.rounded())
                let cy = Int(py.rounded())
                for dy in stride(from: -10, through: 10, by: 5) {
                    let y = min(h - 1, max(0, cy + dy))
                    for dx in stride(from: -10, through: 10, by: 5) {
                        let x = min(w - 1, max(0, cx + dx))
                        let idx = (y * w + x) * 3
                        if rgb[idx] == 0 && rgb[idx + 1] == 0 && rgb[idx + 2] == 0 {
                            return true
                        }
                    }
                }
                return false
            }
            let interior = matches.filter { m in
                m.x1 > ex0 && m.x1 < ex1 && m.y1 > ey0 && m.y1 < ey1
                && m.x2 > ex0 && m.x2 < ex1 && m.y2 > ey0 && m.y2 < ey1
                && !isNearBlackMask(lRGB, px: m.x1, py: m.y1)
                && !isNearBlackMask(rRGB, px: m.x2, py: m.y2)
            }
            if interior.count >= 10 {
                matches = interior
            }
        }

        // 事前 2D 並進コンセンサスフィルタ（天体写真など類似点が多い画像での SIFT 誤マッチ暴走を防止）
        let dyTol = max(20.0, Double(h) * 0.05)
        let dxTol = max(48.0, Double(w) * (preserveArch ? 0.14 : 0.25))
        if matches.count >= 8 {
            let binSize = max(8.0, Double(h) * 0.015)
            var dyBins: [Int: [StereoMatchPoint]] = [:]
            for m in matches {
                let dy = m.y2 - m.y1
                let b = Int((dy / binSize).rounded())
                dyBins[b, default: []].append(m)
            }
            if let bestBin = dyBins.max(by: { $0.value.count < $1.value.count }) {
                let bestKey = bestBin.key
                let nearDy = matches.filter { abs(Int((($0.y2 - $0.y1) / binSize).rounded()) - bestKey) <= 2 }
                if nearDy.count >= 6 {
                    let sortedDy = nearDy.map { $0.y2 - $0.y1 }.sorted()
                    let medDy = sortedDy[sortedDy.count / 2]
                    let sortedDx = nearDy.map { $0.x2 - $0.x1 }.sorted()
                    let medDx = sortedDx[sortedDx.count / 2]
                    let consensus = nearDy.filter {
                        abs(($0.y2 - $0.y1) - medDy) <= dyTol && abs(($0.x2 - $0.x1) - medDx) <= dxTol
                    }
                    if consensus.count >= 6 {
                        matches = consensus
                    }
                }
            }
        }

        if let maskL, let maskR {
            for i in 0..<matches.count {
                let mL = maskL.sample(atPixelX: matches[i].x1, pixelY: matches[i].y1, imageWidth: Double(w), imageHeight: Double(h))
                let mR = maskR.sample(atPixelX: matches[i].x2, pixelY: matches[i].y2, imageWidth: Double(w), imageHeight: Double(h))
                if max(mL, mR) > 0.5 {
                    matches[i].weight = 0.05
                }
            }
        }

        // 3. 7自由度対称ホモグラフィ最適化 (LAPACK dposv_ + IRLS) + 破綻防止サニティチェック
        func isSaneRectification(_ res: RectificationResult) -> Bool {
            let maxRMSE = max(18.0, Double(h) * 0.025)
            return res.verticalRMSEPixels.isFinite
                && res.verticalRMSEPixels <= maxRMSE
                && abs(res.params.rollL) <= 0.18
                && abs(res.params.rollR) <= 0.18
                && abs(res.params.logScale) <= 0.15
                && abs(res.params.keystoneXL) <= 0.15
                && abs(res.params.keystoneXR) <= 0.15
                && abs(res.params.keystoneY) <= 0.15
        }

        var rectRes: RectificationResult? = StereoRectifier.solve(matches: matches, width: w, height: h, tikhonovGamma: 1e-2)
        if let r = rectRes, !isSaneRectification(r) {
            rectRes = StereoRectifier.solve(matches: matches, width: w, height: h, tikhonovGamma: 2.0)
        }
        if rectRes == nil || !isSaneRectification(rectRes!) {
            rectRes = RectificationResult(
                params: RectificationParams(),
                homographyLeftPixel: matrix_identity_double3x3,
                homographyRightPixel: matrix_identity_double3x3,
                verticalRMSEPixels: 0.0,
                inlierCount: matches.count,
                weights: [Double](repeating: 1.0, count: matches.count),
                iterations: 0
            )
        }
        guard let rectRes else {
            return .failure(.rectificationFailed)
        }

        // IRLS インライヤー判定を matches に反映
        for i in 0..<matches.count {
            matches[i].isInlier = (i < rectRes.weights.count && rectRes.weights[i] > 0)
        }

        // 4. 平行化後の水平視差サンプルを構築し、インテリジェント・ウィンドウ最適化
        var samples: [DisparitySample] = []
        samples.reserveCapacity(rectRes.inlierCount)
        for m in matches where m.isInlier {
            if let qL = HomographyGeometry.project(SIMD2(m.x1, m.y1), by: rectRes.homographyLeftPixel),
               let qR = HomographyGeometry.project(SIMD2(m.x2, m.y2), by: rectRes.homographyRightPixel) {
                let parallax = qR.x - qL.x
                let rawSal = saliencyMap?.sample(atPixelX: m.x1, pixelY: m.y1, imageWidth: Double(w), imageHeight: Double(h)) ?? 0.5
                let sal = useSaliency ? max(0.05, rawSal) : 0.5
                samples.append(DisparitySample(x: qL.x, y: qL.y, parallax: parallax, saliency: sal, foregroundWeight: 0.7))
            }
        }

        if samples.count >= 8 {
            let sortedP = samples.map { $0.parallax }.sorted()
            let medP = sortedP[sortedP.count / 2]
            let maxDev = Double(w) * (preserveArch ? 0.045 : 0.12)
            let filtered = samples.filter { abs($0.parallax - medP) <= maxDev }
            if filtered.count >= 6 {
                samples = filtered
            }
        }

        let winOpts = makeWindowOptimizationOptions(preserveArch: preserveArch)
        let rawWindowDecision = IntelligentStereoWindow.solveOptimalHorizontalShift(samples: samples, imageWidth: Double(w), imageHeight: Double(h), options: winOpts)
        // ステレオカード（preserveArch）は当時すでに職人により立体窓の奥に適正マウントされているため、
        // 過大なシフトで写真が枠外へ飛び出したり被写体が切断・巨大ズームされるのを防ぐため、最大シフト幅を 2%（±16px程度）に制限
        let maxArchShift = Double(w) * 0.020
        let tx = preserveArch ? min(maxArchShift, max(-maxArchShift, rawWindowDecision.optimalShiftX)) : rawWindowDecision.optimalShiftX
        let windowDecision = StereoWindowDecision(
            optimalShiftX: tx,
            minShiftedParallax: rawWindowDecision.minShiftedParallax,
            farShiftedParallax: rawWindowDecision.farShiftedParallax,
            hasWindowViolationRisk: rawWindowDecision.hasWindowViolationRisk,
            requiresFloatingWindow: rawWindowDecision.requiresFloatingWindow
        )

        // 5. 対称水平シフトを適用した最終行列と MAAIR 内接矩形算出
        let shiftL = HomographyGeometry.translation(dx: -0.5 * tx, dy: 0) * rectRes.homographyLeftPixel
        let shiftR = HomographyGeometry.translation(dx: +0.5 * tx, dy: 0) * rectRes.homographyRightPixel

        let corners = [
            SIMD2<Double>(0, 0),
            SIMD2<Double>(Double(w), 0),
            SIMD2<Double>(Double(w), Double(h)),
            SIMD2<Double>(0, Double(h))
        ]
        guard let quadL = try? corners.map({ p -> SIMD2<Double> in
            guard let q = HomographyGeometry.project(p, by: shiftL) else { throw NSError() }
            return q
        }),
              let quadR = try? corners.map({ p -> SIMD2<Double> in
                  guard let q = HomographyGeometry.project(p, by: shiftR) else { throw NSError() }
                  return q
              }) else {
            return .failure(.projectionFailed)
        }

        let commonPoly = ConvexPolygonRect.intersectConvexPolygons(quadL, quadR)
        let cropOrigin: SIMD2<Double>
        let rawCW: Int
        let rawCH: Int
        if preserveArch {
            // 左右の視差シフト (tx) や回転・垂直ズレで生じる外周の黒い隙間（未定義領域）を除去するため、
            // quadL と quadR の共通有効矩形にフィットさせて余計な黒枠の発生を防ぐ
            let minCommonX = max(quadL.map { $0.x }.min() ?? 0.0, quadR.map { $0.x }.min() ?? 0.0)
            let maxCommonX = min(quadL.map { $0.x }.max() ?? Double(w), quadR.map { $0.x }.max() ?? Double(w))
            let minCommonY = max(quadL.map { $0.y }.min() ?? 0.0, quadR.map { $0.y }.min() ?? 0.0)

            let originX = ceil(max(0.0, minCommonX))
            let originY = ceil(max(0.0, minCommonY))
            let endX = floor(min(Double(w), maxCommonX))
            // 下端（endY）は足先や車輪底の被写体を切断しないよう下端フルハイト（Double(h)）を最大限確保
            let endY = floor(Double(h))

            cropOrigin = SIMD2<Double>(originX, originY)
            rawCW = max(16, Int(endX - originX))
            rawCH = max(16, Int(endY - originY))
        } else {
            let aspect: Double? = keepAR ? (Double(w) / Double(h)) : nil
            guard let maair = ConvexPolygonRect.largestAxisParallelInscribedRectangle(in: commonPoly, aspectRatio: aspect) else {
                return .failure(.noValidInteriorRect)
            }
            // Lanczos-3 境界誤差（3px）を避けるため、十分大きければ各辺 4px 内側へ安全インセット
            let inset = (maair.maxX - maair.minX > 48 && maair.maxY - maair.minY > 48) ? 4.0 : 0.0
            cropOrigin = SIMD2<Double>(ceil(maair.minX + inset), ceil(maair.minY + inset))
            rawCW = max(16, Int(floor(maair.maxX - inset) - cropOrigin.x))
            rawCH = max(16, Int(floor(maair.maxY - inset) - cropOrigin.y))
        }

        // 6. Metal 1パス Lanczos-3 ワープ実行（左右並列）
        guard let renderer else {
            return .failure(.metalWarpFailed)
        }
        var rawWarpedL: [UInt8]? = nil
        var rawWarpedR: [UInt8]? = nil
        DispatchQueue.concurrentPerform(iterations: 2) { side in
            if side == 0 {
                rawWarpedL = try? renderer.warpRGB8(rgbData: lRGB, srcWidth: w, srcHeight: h, forwardHomography: shiftL, cropOrigin: cropOrigin, dstWidth: rawCW, dstHeight: rawCH)
            } else {
                rawWarpedR = try? renderer.warpRGB8(rgbData: rRGB, srcWidth: w, srcHeight: h, forwardHomography: shiftR, cropOrigin: cropOrigin, dstWidth: rawCW, dstHeight: rawCH)
            }
        }
        guard let rawWarpedL, let rawWarpedR else {
            return .failure(.metalWarpFailed)
        }

        // 6.5 縁の黒枠・片側欠損ラインを自動クロップ（アーチ黒枠保持時はスキップ）
        var (warpedL, warpedR, cw, ch) = preserveArch
            ? (rawWarpedL, rawWarpedR, rawCW, rawCH)
            : trimEdgeColorFringe(left: rawWarpedL, right: rawWarpedR, width: rawCW, height: rawCH)

        // 7. 自動カラーマッチング（基本設定）
        let pixelCount = cw * ch
        switch colorMode {
        case .off:
            break
        case .left:
            warpedR = HistogramColorMatcher.matchHistogram(referenceRGB: warpedL, targetRGB: warpedR, pixelCount: pixelCount)
        case .right:
            warpedL = HistogramColorMatcher.matchHistogram(referenceRGB: warpedR, targetRGB: warpedL, pixelCount: pixelCount)
        }

        // 8. 片側ノイズ自動除去（反対側の正常テクスチャを移植）
        if removeNoise {
            let cleaned = UnilateralNoiseRemover.clean(
                leftRGB: warpedL,
                rightRGB: warpedR,
                width: cw,
                height: ch,
                minParallax: windowDecision.minShiftedParallax,
                maxParallax: windowDecision.farShiftedParallax
            )
            warpedL = cleaned.left
            warpedR = cleaned.right
        }

        // 8.5 アーチ角丸保持時は、平行化・ノイズ除去後に左右共通の滑らかなパラメトリックアーチマスクで仕上げる
        if preserveArch {
            let archParams = StereoCardSegmenter.shared.currentArchParams
            StereoCardSegmenter.applyArchMaskPair(&warpedL, &warpedR, width: cw, height: ch, params: archParams, extraInsetRatio: 0.008, cardLuma: StereoCardSegmenter.shared.currentCardLuma)
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let dispRangePct = cw > 0 ? ((windowDecision.farShiftedParallax - windowDecision.minShiftedParallax) / Double(cw) * 100.0) : 0.0
        let (prevL, prevCW, prevCH) = downsampleForPreview(warpedL, width: cw, height: ch, maxDim: previewMaxDimension)
        let (prevR, _, _) = downsampleForPreview(warpedR, width: cw, height: ch, maxDim: previewMaxDimension)

        // スライダードラッグ中の 60fps 追従用（tx = 0 で平行化済み軽量バッファ）を1回だけ生成（vL, vR を再利用）
        let rw = vw, rh = vh
        let rsx = Double(rw) / Double(max(1, w))
        let rsy = Double(rh) / Double(max(1, h))
        let rScale = simd_double3x3(columns: (SIMD3(rsx, 0, 0), SIMD3(0, rsy, 0), SIMD3(0, 0, 1)))
        let rInvScale = simd_double3x3(columns: (SIMD3(1.0 / rsx, 0, 0), SIMD3(0, 1.0 / rsy, 0), SIMD3(0, 0, 1)))
        let rHL = rScale * rectRes.homographyLeftPixel * rInvScale
        let rHR = rScale * rectRes.homographyRightPixel * rInvScale
        var rectPrevL = (try? renderer.warpRGB8(rgbData: vL, srcWidth: rw, srcHeight: rh, forwardHomography: rHL, cropOrigin: .zero, dstWidth: rw, dstHeight: rh)) ?? vL
        var rectPrevR = (try? renderer.warpRGB8(rgbData: vR, srcWidth: rw, srcHeight: rh, forwardHomography: rHR, cropOrigin: .zero, dstWidth: rw, dstHeight: rh)) ?? vR

        let rCount = rw * rh
        switch colorMode {
        case .off:
            break
        case .left:
            rectPrevR = HistogramColorMatcher.matchHistogram(referenceRGB: rectPrevL, targetRGB: rectPrevR, pixelCount: rCount)
        case .right:
            rectPrevL = HistogramColorMatcher.matchHistogram(referenceRGB: rectPrevR, targetRGB: rectPrevL, pixelCount: rCount)
        }

        return .success(AlignmentPipelineOutput(
            warpedL: warpedL,
            warpedR: warpedR,
            cw: cw,
            ch: ch,
            prevWarpedL: prevL,
            prevWarpedR: prevR,
            prevCW: prevCW,
            prevCH: prevCH,
            rectPrevL: rectPrevL,
            rectPrevR: rectPrevR,
            rectPrevW: rw,
            rectPrevH: rh,
            matches: matches,
            rectRes: rectRes,
            commonPoly: commonPoly,
            samples: samples,
            saliencyMap: saliencyMap,
            windowDecision: windowDecision,
            elapsedMs: elapsedMs,
            dispRangePct: max(0, dispRangePct)
        ))
    }

    /// Vision Saliency Subject Priority トグル変更時にウィンドウ最適値を再計算・適用
    func recalculateOptimalWindow() {
        guard isAligned, let rectRes = lastRectResult, !lastMatches.isEmpty else { return }
        let w = Double(imageWidth), h = Double(imageHeight)
        let useSaliency = useAttentionSaliency
        let salMap = lastRawSaliencyMap

        var updatedSamples: [DisparitySample] = []
        updatedSamples.reserveCapacity(rectRes.inlierCount)
        for m in lastMatches where m.isInlier {
            if let qL = HomographyGeometry.project(SIMD2(m.x1, m.y1), by: rectRes.homographyLeftPixel),
               let qR = HomographyGeometry.project(SIMD2(m.x2, m.y2), by: rectRes.homographyRightPixel) {
                let parallax = qR.x - qL.x
                let rawSal = salMap?.sample(atPixelX: m.x1, pixelY: m.y1, imageWidth: w, imageHeight: h) ?? 0.5
                let sal = useSaliency ? max(0.05, rawSal) : 0.5
                updatedSamples.append(DisparitySample(x: qL.x, y: qL.y, parallax: parallax, saliency: sal, foregroundWeight: 0.7))
            }
        }
        lastDisparitySamples = updatedSamples
        let winOpts = Self.makeWindowOptimizationOptions(preserveArch: hasPreservedArch)
        let decision = IntelligentStereoWindow.solveOptimalHorizontalShift(samples: updatedSamples, imageWidth: w, imageHeight: h, options: winOpts)
        let maxArchShift = w * 0.020
        let optTx = hasPreservedArch ? min(maxArchShift, max(-maxArchShift, decision.optimalShiftX)) : decision.optimalShiftX
        autoOptimalShiftX = optTx
        windowShiftX = optTx
        applyManualWindowShift()
    }

    nonisolated private static func makeWindowOptimizationOptions(preserveArch: Bool) -> WindowOptimizationOptions {
        var opts = WindowOptimizationOptions()
        opts.edgeBandRatio = preserveArch ? 0.14 : 0.10
        opts.lambdaWindowViolation = 250.0
        opts.lambdaSaliency = 0.5
        opts.maxComfortRatio = 0.05
        opts.lambdaNear = 150.0
        return opts
    }

    /// スライダードラッグ中のゼロレイテンシ追従プレビュー（Metal 呼び出しなし・1パス RGBA 合成）
    func updateRealtimeDragPreview() {
        guard isAligned,
              let rL = rectifiedPreviewLeftRGB,
              let rR = rectifiedPreviewRightRGB,
              rectifiedPreviewWidth > 0,
              rectifiedPreviewHeight > 0,
              imageWidth > 0 else {
            return
        }

        let rw = rectifiedPreviewWidth
        let rh = rectifiedPreviewHeight
        let tx = windowShiftX
        let sx = Double(rw) / Double(imageWidth)
        let dxL = Int((-0.5 * tx * sx).rounded())
        let dxR = Int((+0.5 * tx * sx).rounded())

        let startX = max(0, max(dxL, dxR))
        let endX = min(rw, min(rw + dxL, rw + dxR))
        let cropW = endX - startX
        guard cropW >= 16 else { return }

        let srcXL = startX - dxL
        let srcXR = startX - dxR
        let mode = displayMode
        let style = frameStyle
        let swapped = isSwapped
        let cardCfg = makeCardMountConfig()
        let mountCtx = currentMountContext
        let restOpts = makeVintageRestorationOptions()

        var sl = Self.cropHorizontalSlice(rL, srcW: rw, height: rh, srcX: srcXL, cropW: cropW)
        var sr = Self.cropHorizontalSlice(rR, srcW: rw, height: rh, srcX: srcXR, cropW: cropW)
        if !restOpts.isIdentity {
            let restored = VintageToneRestorer.restorePair(leftRGB: sl, rightRGB: sr, width: cropW, height: rh, options: restOpts)
            sl = restored.left
            sr = restored.right
        }
        if style != .off && mode != .stereoviewCard {
            Self.applyFrameStyleIfNeeded(left: &sl, right: &sr, width: cropW, height: rh, style: style)
        }
        let img = Self.renderPreviewNSImage(
            left: sl, right: sr, width: cropW, height: rh,
            mode: mode,
            isSwapped: swapped,
            transparentCorners: (style != .off),
            cardConfig: cardCfg,
            mountContext: mountCtx
        )
        if let img {
            displayImage = img
        }

        let estFullCropW = max(16, Int(Double(cropW) / sx))
        let erg = Self.evaluateWindowErgonomics(samples: lastDisparitySamples, shiftX: tx, imageWidth: Double(imageWidth), imageHeight: Double(imageHeight), cropWidth: estFullCropW)
        hasWindowViolationRisk = erg.hasWindowViolationRisk
        requiresFloatingWindow = erg.requiresFloatingWindow
        maxDisparityPercent = erg.dispRangePct
        statusMessage = String(format: "Window Shift: %.1f px | Disparity: %.2f%%", tx, erg.dispRangePct)
    }

    nonisolated private static func makeShiftedAnaglyphNSImage(
        left: [UInt8], right: [UInt8], srcW: Int, height: Int, srcXL: Int, srcXR: Int, cropW: Int
    ) -> NSImage? {
        var rgba = [UInt8](repeating: 255, count: cropW * height * 4)
        left.withUnsafeBufferPointer { lPtr in
            right.withUnsafeBufferPointer { rPtr in
                rgba.withUnsafeMutableBufferPointer { dPtr in
                    guard let lBase = lPtr.baseAddress, let rBase = rPtr.baseAddress, let dBase = dPtr.baseAddress else { return }
                    for y in 0..<height {
                        let lRow = (y * srcW + srcXL) * 3
                        let rRow = (y * srcW + srcXR) * 3
                        let dRow = y * cropW * 4
                        for x in 0..<cropW {
                            let li = lRow + x * 3
                            let ri = rRow + x * 3
                            let di = dRow + x * 4
                            let lGray = (77 * Int(lBase[li]) + 150 * Int(lBase[li + 1]) + 29 * Int(lBase[li + 2])) >> 8
                            let rGray = (77 * Int(rBase[ri]) + 150 * Int(rBase[ri + 1]) + 29 * Int(rBase[ri + 2])) >> 8
                            dBase[di] = UInt8(lGray)
                            dBase[di + 1] = UInt8(rGray)
                            dBase[di + 2] = UInt8(rGray)
                        }
                    }
                }
            }
        }
        return makeNSImageFromRGBA(rgba, width: cropW, height: height)
    }

    nonisolated private static func makeShiftedSBSNSImage(
        left: [UInt8], right: [UInt8], srcW: Int, height: Int, srcXL: Int, srcXR: Int, cropW: Int
    ) -> NSImage? {
        let outW = cropW * 2
        var rgba = [UInt8](repeating: 255, count: outW * height * 4)
        left.withUnsafeBufferPointer { lPtr in
            right.withUnsafeBufferPointer { rPtr in
                rgba.withUnsafeMutableBufferPointer { dPtr in
                    guard let lBase = lPtr.baseAddress, let rBase = rPtr.baseAddress, let dBase = dPtr.baseAddress else { return }
                    for y in 0..<height {
                        let lRow = (y * srcW + srcXL) * 3
                        let rRow = (y * srcW + srcXR) * 3
                        let dRowL = y * outW * 4
                        let dRowR = dRowL + cropW * 4
                        for x in 0..<cropW {
                            let li = lRow + x * 3
                            let ri = rRow + x * 3
                            let dli = dRowL + x * 4
                            let dri = dRowR + x * 4
                            dBase[dli] = lBase[li]; dBase[dli + 1] = lBase[li + 1]; dBase[dli + 2] = lBase[li + 2]
                            dBase[dri] = rBase[ri]; dBase[dri + 1] = rBase[ri + 1]; dBase[dri + 2] = rBase[ri + 2]
                        }
                    }
                }
            }
        }
        return makeNSImageFromRGBA(rgba, width: outW, height: height)
    }

    nonisolated private static func makeNSImageFromRGBA(_ rgba: [UInt8], width: Int, height: Int) -> NSImage? {
        guard let cfData = CFDataCreate(kCFAllocatorDefault, rgba, rgba.count),
              let provider = CGDataProvider(data: cfData),
              let cg = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    /// スライダードラッグ終了後などの精密プレビュー更新（軽量バッファ＋Metal Lanczos-3）
    func scheduleRealtimeWindowPreview() {
        guard isAligned else { return }
        if isPreviewWarping {
            needsAnotherPreviewWarp = true
            return
        }
        runNextPreviewWarp()
    }

    private func runNextPreviewWarp() {
        guard isAligned,
              let rectRes = lastRectResult,
              let pL = previewRawLeftRGB,
              let pR = previewRawRightRGB,
              let renderer = metalRenderer else {
            return
        }

        let w = imageWidth, h = imageHeight
        let pw = previewWidth, ph = previewHeight
        let preserveArch = hasPreservedArch
        let rawTx = windowShiftX
        let maxArchShift = Double(w) * 0.035
        let tx = preserveArch ? min(maxArchShift, max(-maxArchShift, rawTx)) : rawTx
        let keepAR = keepOriginalAspectRatio
        let samples = lastDisparitySamples
        let mode = displayMode
        let style = frameStyle
        let swapped = isSwapped
        let cardCfg = makeCardMountConfig()
        let mountCtx = currentMountContext
        let restOpts = makeVintageRestorationOptions()
        let detailOpts = makeDetailRestorationOptions()
        let colorMode = autoColorMode
        let removeNoise = removeUnilateralNoise

        isPreviewWarping = true
        needsAnotherPreviewWarp = false
        previewRenderGeneration += 1
        let gen = previewRenderGeneration
        let showHeavyProgress = removeNoise || !detailOpts.isIdentity
        if showHeavyProgress {
            isRestoringPreview = true
            restorationProgress = 0.08
            restorationProgressMessage = removeNoise
                ? String(localized: "Removing unilateral dust & restoring photo...")
                : String(localized: "Applying AI optical deblur (NAFNet)...")
        }

        Task {
            let output = await Task.detached(priority: .userInitiated) { () -> ([UInt8], [UInt8], Int, Int, Int, Int, Bool, Bool, Double, NSImage?)? in
                let shiftL = HomographyGeometry.translation(dx: -0.5 * tx, dy: 0) * rectRes.homographyLeftPixel
                let shiftR = HomographyGeometry.translation(dx: +0.5 * tx, dy: 0) * rectRes.homographyRightPixel
                let corners = [SIMD2(0.0, 0.0), SIMD2(Double(w), 0.0), SIMD2(Double(w), Double(h)), SIMD2(0.0, Double(h))]
                let quadL = corners.compactMap { HomographyGeometry.project($0, by: shiftL) }
                let quadR = corners.compactMap { HomographyGeometry.project($0, by: shiftR) }
                guard quadL.count == 4, quadR.count == 4 else { return nil }
                let fullCW: Int
                let fullCH: Int
                let prevOrigin: SIMD2<Double>
                let rawPrevCW: Int
                let rawPrevCH: Int
                let sx = Double(pw) / Double(max(1, w))
                let sy = Double(ph) / Double(max(1, h))
                if preserveArch {
                    // 左右の視差シフト (tx) や回転で生じる外周の黒い隙間（未定義領域）を除去するため、
                    // quadL と quadR の共通有効矩形にフィットさせて余計な黒枠の発生を防ぐ
                    let minCommonX = max(quadL.map { $0.x }.min() ?? 0.0, quadR.map { $0.x }.min() ?? 0.0)
                    let maxCommonX = min(quadL.map { $0.x }.max() ?? Double(w), quadR.map { $0.x }.max() ?? Double(w))
                    let minCommonY = max(quadL.map { $0.y }.min() ?? 0.0, quadR.map { $0.y }.min() ?? 0.0)

                    let originX = ceil(max(0.0, minCommonX))
                    let originY = ceil(max(0.0, minCommonY))
                    let endX = floor(min(Double(w), maxCommonX))
                    // 下端（endY）は足先や車輪底の被写体を切断しないよう下端フルハイト（Double(h)）を最大限確保
                    let endY = floor(Double(h))

                    fullCW = max(16, Int(endX - originX))
                    fullCH = max(16, Int(endY - originY))
                    prevOrigin = SIMD2<Double>(ceil(originX * sx), ceil(originY * sy))
                    rawPrevCW = max(16, Int(floor(endX * sx) - prevOrigin.x))
                    rawPrevCH = max(16, Int(floor(endY * sy) - prevOrigin.y))
                } else {
                    let poly = ConvexPolygonRect.intersectConvexPolygons(quadL, quadR)
                    let aspect: Double? = keepAR ? (Double(w) / Double(h)) : nil
                    guard let maair = ConvexPolygonRect.largestAxisParallelInscribedRectangle(in: poly, aspectRatio: aspect) else {
                        return nil
                    }
                    let inset = (maair.maxX - maair.minX > 48 && maair.maxY - maair.minY > 48) ? 4.0 : 0.0
                    fullCW = max(16, Int(floor(maair.maxX - inset) - ceil(maair.minX + inset)))
                    fullCH = max(16, Int(floor(maair.maxY - inset) - ceil(maair.minY + inset)))
                    prevOrigin = SIMD2<Double>(ceil((maair.minX + inset) * sx), ceil((maair.minY + inset) * sy))
                    rawPrevCW = max(16, Int(floor((maair.maxX - inset) * sx) - prevOrigin.x))
                    rawPrevCH = max(16, Int(floor((maair.maxY - inset) * sy) - prevOrigin.y))
                }

                // プレビュー座標系へホモグラフィをスケール変換: H_prev = S * H_full * S^-1
                let scaleMat = simd_double3x3(columns: (
                    SIMD3<Double>(sx, 0, 0),
                    SIMD3<Double>(0, sy, 0),
                    SIMD3<Double>(0, 0, 1)
                ))
                let invScaleMat = simd_double3x3(columns: (
                    SIMD3<Double>(1.0 / sx, 0, 0),
                    SIMD3<Double>(0, 1.0 / sy, 0),
                    SIMD3<Double>(0, 0, 1)
                ))
                let prevShiftL = scaleMat * shiftL * invScaleMat
                let prevShiftR = scaleMat * shiftR * invScaleMat

                guard let rawWarpedPL = try? renderer.warpRGB8(rgbData: pL, srcWidth: pw, srcHeight: ph, forwardHomography: prevShiftL, cropOrigin: prevOrigin, dstWidth: rawPrevCW, dstHeight: rawPrevCH),
                      let rawWarpedPR = try? renderer.warpRGB8(rgbData: pR, srcWidth: pw, srcHeight: ph, forwardHomography: prevShiftR, cropOrigin: prevOrigin, dstWidth: rawPrevCW, dstHeight: rawPrevCH) else {
                    return nil
                }

                var (warpedPL, warpedPR, prevCW, prevCH) = preserveArch
                    ? (rawWarpedPL, rawWarpedPR, rawPrevCW, rawPrevCH)
                    : Self.trimEdgeColorFringe(left: rawWarpedPL, right: rawWarpedPR, width: rawPrevCW, height: rawPrevCH)

                let prevPixelCount = prevCW * prevCH
                switch colorMode {
                case .off:
                    break
                case .left:
                    warpedPR = HistogramColorMatcher.matchHistogram(referenceRGB: warpedPL, targetRGB: warpedPR, pixelCount: prevPixelCount)
                case .right:
                    warpedPL = HistogramColorMatcher.matchHistogram(referenceRGB: warpedPR, targetRGB: warpedPL, pixelCount: prevPixelCount)
                }

                let erg = Self.evaluateWindowErgonomics(samples: samples, shiftX: tx, imageWidth: Double(w), imageHeight: Double(h), cropWidth: fullCW)
                if removeNoise {
                    await MainActor.run {
                        if self.previewRenderGeneration == gen {
                            self.restorationProgress = 0.20
                            self.restorationProgressMessage = String(localized: "Removing unilateral noise & dust...")
                        }
                    }
                    let pScale = Double(prevCW) / Double(max(1, fullCW))
                    let cleaned = UnilateralNoiseRemover.clean(
                        leftRGB: warpedPL,
                        rightRGB: warpedPR,
                        width: prevCW,
                        height: prevCH,
                        minParallax: erg.dispRangePct > 0 ? -max(20.0, Double(prevCW) * 0.08 * pScale) : -24.0,
                        maxParallax: erg.dispRangePct > 0 ? max(20.0, Double(prevCW) * 0.08 * pScale) : 24.0
                    )
                    warpedPL = cleaned.left
                    warpedPR = cleaned.right
                }

                if preserveArch {
                    let archParams = StereoCardSegmenter.shared.currentArchParams
                    StereoCardSegmenter.applyArchMaskPair(&warpedPL, &warpedPR, width: prevCW, height: prevCH, params: archParams, extraInsetRatio: 0.008, cardLuma: StereoCardSegmenter.shared.currentCardLuma)
                }

                var dispL = warpedPL
                var dispR = warpedPR
                if !restOpts.isIdentity || !detailOpts.isIdentity {
                    if !detailOpts.isIdentity {
                        await MainActor.run {
                            if self.previewRenderGeneration == gen {
                                self.restorationProgress = 0.35
                                self.restorationProgressMessage = String(localized: "Applying AI optical deblur (NAFNet)...")
                            }
                        }
                    }
                    let restored = Self.applyVintagePipeline(
                        left: dispL,
                        right: dispR,
                        width: prevCW,
                        height: prevCH,
                        toneOptions: restOpts,
                        detailOptions: detailOpts,
                        progress: { p in
                            Task { @MainActor in
                                if self.previewRenderGeneration == gen {
                                    self.restorationProgress = (removeNoise ? 0.35 : 0.10) + p * (removeNoise ? 0.55 : 0.80)
                                }
                            }
                        }
                    )
                    dispL = restored.left
                    dispR = restored.right
                }
                if mode != .stereoviewCard {
                    Self.applyFrameStyleIfNeeded(left: &dispL, right: &dispR, width: prevCW, height: prevCH, style: style)
                }
                let trimmed = Self.trimToTightBoundingBox(left: dispL, right: dispR, width: prevCW, height: prevCH)
                let tl = trimmed.left, tr = trimmed.right, tw = trimmed.width, th = trimmed.height

                let previewImg = Self.renderPreviewNSImage(
                    left: tl, right: tr, width: tw, height: th,
                    mode: mode, isSwapped: swapped, transparentCorners: true,
                    cardConfig: cardCfg, mountContext: mountCtx
                )
                return (warpedPL, warpedPR, prevCW, prevCH, fullCW, fullCH, erg.hasWindowViolationRisk, erg.requiresFloatingWindow, erg.dispRangePct, previewImg)
            }.value

            isPreviewWarping = false
            if let (warpedPL, warpedPR, prevCW, prevCH, fullCW, fullCH, wvRisk, fwReq, dispPct, previewImg) = output {
                previewAlignedLeftRGB = warpedPL
                previewAlignedRightRGB = warpedPR
                previewCroppedWidth = prevCW
                previewCroppedHeight = prevCH
                croppedWidth = fullCW
                croppedHeight = fullCH
                hasWindowViolationRisk = wvRisk
                requiresFloatingWindow = fwReq
                maxDisparityPercent = dispPct
                if let previewImg {
                    displayImage = previewImg
                }
                statusMessage = String(format: "Window Shift: %.1f px | Disparity: %.2f%%", tx, dispPct)
            }

            if needsAnotherPreviewWarp {
                runNextPreviewWarp()
            } else if gen == self.previewRenderGeneration {
                isRestoringPreview = false
                restorationProgress = 0.0
            }
        }
    }

    /// 片側ノイズ・ダスト自動除去トグル変更時に非破壊でプレビューを即時更新
    func applyUnilateralNoiseToggle() {
        guard isAligned, !isProcessing else { return }
        scheduleRealtimeWindowPreview()
    }

    /// 手動ステレオウィンドウ微調整確定時の処理（即座にプレビュー更新、フル解像度は書き出し時に同期）
    func applyManualWindowShift() {
        scheduleRealtimeWindowPreview()
    }

    /// 現在の windowShiftX と removeUnilateralNoise でフル解像度バッファを同期する（Export / Color Match 用）
    private func ensureFullResAlignedSynced() async -> Bool {
        guard isAligned else { return hasLoadedImages }
        let removeNoise = removeUnilateralNoise
        let colorMode = autoColorMode
        if abs(windowShiftX - lastFullResShiftX) <= 1e-4,
           lastFullResRemoveNoise == removeNoise,
           alignedLeftRGB != nil,
           alignedRightRGB != nil {
            return true
        }
        guard let rectRes = lastRectResult,
              let lRGB = rawLeftRGB,
              let rRGB = rawRightRGB,
              let renderer = metalRenderer else {
            return false
        }
        let w = imageWidth, h = imageHeight
        let preserveArch = hasPreservedArch
        let rawTx = windowShiftX
        let maxArchShift = Double(w) * 0.035
        let tx = preserveArch ? min(maxArchShift, max(-maxArchShift, rawTx)) : rawTx
        let keepAR = keepOriginalAspectRatio

        let res = await Task.detached(priority: .userInitiated) { () -> ([UInt8], [UInt8], Int, Int)? in
            let shiftL = HomographyGeometry.translation(dx: -0.5 * tx, dy: 0) * rectRes.homographyLeftPixel
            let shiftR = HomographyGeometry.translation(dx: +0.5 * tx, dy: 0) * rectRes.homographyRightPixel
            let corners = [SIMD2(0.0, 0.0), SIMD2(Double(w), 0.0), SIMD2(Double(w), Double(h)), SIMD2(0.0, Double(h))]
            let quadL = corners.compactMap { HomographyGeometry.project($0, by: shiftL) }
            let quadR = corners.compactMap { HomographyGeometry.project($0, by: shiftR) }
            guard quadL.count == 4, quadR.count == 4 else { return nil }
            let cropOrigin: SIMD2<Double>
            let rawCW: Int
            let rawCH: Int
            if preserveArch {
                // 左右の視差シフト (tx) や回転で生じる外周の黒い隙間（未定義領域）を除去するため、
                // quadL と quadR の共通有効矩形にフィットさせて余計な黒枠の発生を防ぐ
                let minCommonX = max(quadL.map { $0.x }.min() ?? 0.0, quadR.map { $0.x }.min() ?? 0.0)
                let maxCommonX = min(quadL.map { $0.x }.max() ?? Double(w), quadR.map { $0.x }.max() ?? Double(w))
                let minCommonY = max(quadL.map { $0.y }.min() ?? 0.0, quadR.map { $0.y }.min() ?? 0.0)

                let originX = ceil(max(0.0, minCommonX))
                let originY = ceil(max(0.0, minCommonY))
                let endX = floor(min(Double(w), maxCommonX))
                // 下端（endY）は足先や車輪底の被写体を切断しないよう下端フルハイト（Double(h)）を最大限確保
                let endY = floor(Double(h))

                cropOrigin = SIMD2<Double>(originX, originY)
                rawCW = max(16, Int(endX - originX))
                rawCH = max(16, Int(endY - originY))
            } else {
                let poly = ConvexPolygonRect.intersectConvexPolygons(quadL, quadR)
                let aspect: Double? = keepAR ? (Double(w) / Double(h)) : nil
                guard let maair = ConvexPolygonRect.largestAxisParallelInscribedRectangle(in: poly, aspectRatio: aspect) else {
                    return nil
                }
                let inset = (maair.maxX - maair.minX > 48 && maair.maxY - maair.minY > 48) ? 4.0 : 0.0
                cropOrigin = SIMD2<Double>(ceil(maair.minX + inset), ceil(maair.minY + inset))
                rawCW = max(16, Int(floor(maair.maxX - inset) - cropOrigin.x))
                rawCH = max(16, Int(floor(maair.maxY - inset) - cropOrigin.y))
            }

            guard let rawWarpedL = try? renderer.warpRGB8(rgbData: lRGB, srcWidth: w, srcHeight: h, forwardHomography: shiftL, cropOrigin: cropOrigin, dstWidth: rawCW, dstHeight: rawCH),
                  let rawWarpedR = try? renderer.warpRGB8(rgbData: rRGB, srcWidth: w, srcHeight: h, forwardHomography: shiftR, cropOrigin: cropOrigin, dstWidth: rawCW, dstHeight: rawCH) else {
                return nil
            }
            var (warpedL, warpedR, cw, ch) = preserveArch
                ? (rawWarpedL, rawWarpedR, rawCW, rawCH)
                : Self.trimEdgeColorFringe(left: rawWarpedL, right: rawWarpedR, width: rawCW, height: rawCH)
            let pixelCount = cw * ch
            switch colorMode {
            case .off:
                break
            case .left:
                warpedR = HistogramColorMatcher.matchHistogram(referenceRGB: warpedL, targetRGB: warpedR, pixelCount: pixelCount)
            case .right:
                warpedL = HistogramColorMatcher.matchHistogram(referenceRGB: warpedR, targetRGB: warpedL, pixelCount: pixelCount)
            }
            if removeNoise {
                let cleaned = UnilateralNoiseRemover.clean(leftRGB: warpedL, rightRGB: warpedR, width: cw, height: ch)
                warpedL = cleaned.left
                warpedR = cleaned.right
            }
            if preserveArch {
                let archParams = StereoCardSegmenter.shared.currentArchParams
                StereoCardSegmenter.applyArchMaskPair(&warpedL, &warpedR, width: cw, height: ch, params: archParams, extraInsetRatio: 0.008, cardLuma: StereoCardSegmenter.shared.currentCardLuma)
            }
            return (warpedL, warpedR, cw, ch)
        }.value

        guard let (warpedL, warpedR, cw, ch) = res else { return false }
        alignedLeftRGB = warpedL
        alignedRightRGB = warpedR
        croppedWidth = cw
        croppedHeight = ch
        lastFullResShiftX = tx
        lastFullResRemoveNoise = removeNoise
        return true
    }

    nonisolated private static func evaluateWindowErgonomics(
        samples: [DisparitySample],
        shiftX tx: Double,
        imageWidth: Double,
        imageHeight: Double,
        cropWidth: Int
    ) -> (hasWindowViolationRisk: Bool, requiresFloatingWindow: Bool, dispRangePct: Double) {
        guard !samples.isEmpty, imageWidth > 1, imageHeight > 1, cropWidth > 0 else {
            return (false, false, 0.0)
        }
        let sortedP = samples.map { $0.parallax }.sorted()
        let pMin = sortedP.first!
        let farIdx = min(sortedP.count - 1, max(0, Int(Double(sortedP.count - 1) * 0.98)))
        let pFar = sortedP[farIdx]

        let minShifted = pMin + tx
        let farShifted = pFar + tx
        let leftEdge = imageWidth * 0.08
        let rightEdge = imageWidth * 0.92
        let topEdge = imageHeight * 0.08
        let bottomEdge = imageHeight * 0.92
        let pMaxLimit = 0.04 * imageWidth

        let edgeViolation = samples.contains { s in
            let onEdge = (s.x <= leftEdge || s.x >= rightEdge || s.y <= topEdge || s.y >= bottomEdge)
            return onEdge && (s.parallax + tx < -0.5)
        }
        let exceedsComfort = farShifted > pMaxLimit + 0.5
        let dispRangePct = max(0.0, (farShifted - minShifted) / Double(cropWidth) * 100.0)
        return (edgeViolation, edgeViolation || exceedsComfort, dispRangePct)
    }

    // MARK: - Auto Color Matching

    func applyAutoColor(leftReference: Bool) {
        guard hasLoadedImages else { return }
        isProcessing = true
        statusMessage = "Matching color..."
        Task {
            if isAligned {
                _ = await ensureFullResAlignedSynced()
            }
            guard let l = activeLeftRGB, let r = activeRightRGB else {
                isProcessing = false
                return
            }
            let w = activeWidth, h = activeHeight
            let count = w * h
            let wasAligned = isAligned
            let rPrevL = rectifiedPreviewLeftRGB
            let rPrevR = rectifiedPreviewRightRGB
            let rPrevCount = rectifiedPreviewWidth * rectifiedPreviewHeight

            let (newL, newR, prevL, prevR, pW, pH, newRectPrevL, newRectPrevR) = await Task.detached(priority: .userInitiated) { () -> ([UInt8], [UInt8], [UInt8], [UInt8], Int, Int, [UInt8]?, [UInt8]?) in
                let resL: [UInt8]
                let resR: [UInt8]
                if leftReference {
                    resL = l
                    resR = HistogramColorMatcher.matchHistogram(referenceRGB: l, targetRGB: r, pixelCount: count)
                } else {
                    resL = HistogramColorMatcher.matchHistogram(referenceRGB: r, targetRGB: l, pixelCount: count)
                    resR = r
                }
                let (pL, pw, ph) = Self.downsampleForPreview(resL, width: w, height: h, maxDim: Self.previewMaxDimension)
                let (pR, _, _) = Self.downsampleForPreview(resR, width: w, height: h, maxDim: Self.previewMaxDimension)

                var outRectL: [UInt8]? = rPrevL
                var outRectR: [UInt8]? = rPrevR
                if wasAligned, let rl = rPrevL, let rr = rPrevR, rPrevCount > 0 {
                    if leftReference {
                        outRectR = HistogramColorMatcher.matchHistogram(referenceRGB: rl, targetRGB: rr, pixelCount: rPrevCount)
                    } else {
                        outRectL = HistogramColorMatcher.matchHistogram(referenceRGB: rr, targetRGB: rl, pixelCount: rPrevCount)
                    }
                }
                return (resL, resR, pL, pR, pw, ph, outRectL, outRectR)
            }.value

            if isAligned {
                alignedLeftRGB = newL
                alignedRightRGB = newR
                previewAlignedLeftRGB = prevL
                previewAlignedRightRGB = prevR
                previewCroppedWidth = pW
                previewCroppedHeight = pH
                rectifiedPreviewLeftRGB = newRectPrevL
                rectifiedPreviewRightRGB = newRectPrevR
            } else {
                rawLeftRGB = newL
                rawRightRGB = newR
                previewRawLeftRGB = prevL
                previewRawRightRGB = prevR
                previewWidth = pW
                previewHeight = pH
            }
            isProcessing = false
            statusMessage = leftReference ? "Matched color to Left." : "Matched color to Right."
            renderDisplayPreview()
        }
    }

    // MARK: - Preview & Export

    func renderDisplayPreview() {
        guard let l = activePreviewLeftRGB, let r = activePreviewRightRGB else {
            displayImage = nil
            return
        }
        let w = activePreviewWidth, h = activePreviewHeight
        let mode = displayMode
        let style = frameStyle
        let swapped = isSwapped
        let cardCfg = makeCardMountConfig()
        let mountCtx = currentMountContext
        let restOpts = makeVintageRestorationOptions()
        let detailOpts = makeDetailRestorationOptions()
        previewRenderGeneration += 1
        let gen = previewRenderGeneration
        let showHeavyProgress = !detailOpts.isIdentity
        if showHeavyProgress {
            isRestoringPreview = true
            restorationProgress = 0.06
            restorationProgressMessage = String(localized: "Applying AI optical deblur (NAFNet)...")
        }

        Task {
            let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                var dispL = l
                var dispR = r
                if !restOpts.isIdentity || !detailOpts.isIdentity {
                    let restored = Self.applyVintagePipeline(
                        left: dispL,
                        right: dispR,
                        width: w,
                        height: h,
                        toneOptions: restOpts,
                        detailOptions: detailOpts,
                        progress: { p in
                            Task { @MainActor in
                                if self.previewRenderGeneration == gen {
                                    self.restorationProgress = 0.08 + p * 0.84
                                }
                            }
                        }
                    )
                    dispL = restored.left
                    dispR = restored.right
                }
                if mode != .stereoviewCard {
                    Self.applyFrameStyleIfNeeded(left: &dispL, right: &dispR, width: w, height: h, style: style)
                }
                let trimmed = Self.trimToTightBoundingBox(left: dispL, right: dispR, width: w, height: h)
                let tl = trimmed.left, tr = trimmed.right, tw = trimmed.width, th = trimmed.height

                return Self.renderPreviewNSImage(
                    left: tl, right: tr, width: tw, height: th,
                    mode: mode, isSwapped: swapped, transparentCorners: true,
                    cardConfig: cardCfg, mountContext: mountCtx
                )
            }.value
            guard gen == self.previewRenderGeneration else { return }
            if showHeavyProgress {
                isRestoringPreview = false
                restorationProgress = 0.0
            }
            displayImage = image
        }
    }

    func exportImage() {
        guard hasLoadedImages else { return }
        let layout = exportLayout
        let imgFormat = exportImageFormat
        let style = frameStyle
        let swapped = isSwapped
        let cardCfg = makeCardMountConfig()
        let mountCtx = currentMountContext
        let restOpts = makeVintageRestorationOptions(ignorePreviewToggle: true)
        let detailOpts = makeDetailRestorationOptions(ignorePreviewToggle: true)
        let ext = imgFormat.fileExtension

        if layout == .separateLR {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export L/R Here"
            if panel.runModal() == .OK, let dir = panel.url {
                let base = leftURL?.deletingPathExtension().lastPathComponent ?? "stereo"
                let outL = dir.appendingPathComponent("\(base)_L.\(ext)")
                let outR = dir.appendingPathComponent("\(base)_R.\(ext)")
                isProcessing = true
                statusMessage = "Rendering full-resolution L/R..."
                Task {
                    if isAligned {
                        _ = await ensureFullResAlignedSynced()
                    }
                    guard let lRaw = activeLeftRGB, let rRaw = activeRightRGB else {
                        isProcessing = false
                        statusMessage = "Export failed."
                        return
                    }
                    let w = activeWidth, h = activeHeight
                    let ok = await Task.detached(priority: .userInitiated) {
                        Self.renderAndSaveSeparateLR(
                            left: swapped ? rRaw : lRaw,
                            right: swapped ? lRaw : rRaw,
                            width: w, height: h,
                            style: style, imageFormat: imgFormat,
                            restorationOptions: restOpts,
                            detailOptions: detailOpts,
                            outL: outL, outR: outR
                        )
                    }.value
                    isProcessing = false
                    statusMessage = ok
                        ? "Exported \(outL.lastPathComponent) & \(outR.lastPathComponent)"
                        : "Failed to export L/R images."
                }
            }
            return
        }

        let panel = NSSavePanel()
        let base = leftURL?.deletingPathExtension().lastPathComponent ?? "ViewStereo_Output"
        switch layout {
        case .twoD:
            panel.allowedContentTypes = [imgFormat.utType]
            panel.nameFieldStringValue = "\(base)_2D.\(ext)"
        case .sbs:
            panel.allowedContentTypes = [imgFormat.utType]
            panel.nameFieldStringValue = "\(base)_SBS.\(ext)"
        case .lrrl:
            panel.allowedContentTypes = [imgFormat.utType]
            panel.nameFieldStringValue = "\(base)_LRRL.\(ext)"
        case .dubois:
            panel.allowedContentTypes = [imgFormat.utType]
            panel.nameFieldStringValue = "\(base)_Dubois.\(ext)"
        case .colorAnaglyph:
            panel.allowedContentTypes = [imgFormat.utType]
            panel.nameFieldStringValue = "\(base)_ColorAnaglyph.\(ext)"
        case .grayAnaglyph:
            panel.allowedContentTypes = [imgFormat.utType]
            panel.nameFieldStringValue = "\(base)_GrayAnaglyph.\(ext)"
        case .polarized:
            panel.allowedContentTypes = [imgFormat.utType]
            panel.nameFieldStringValue = "\(base)_Polarized.\(ext)"
        case .stereoviewCard:
            panel.allowedContentTypes = [imgFormat.utType]
            panel.nameFieldStringValue = "\(base)_Card.\(ext)"
        case .spatialPhoto:
            panel.allowedContentTypes = [.heic]
            panel.nameFieldStringValue = "\(base)_Spatial.heic"
        case .mpo:
            if let mpoType = UTType(filenameExtension: "mpo") {
                panel.allowedContentTypes = [mpoType]
            } else {
                panel.allowedContentTypes = [.jpeg]
            }
            panel.nameFieldStringValue = "\(base).mpo"
        case .separateLR:
            break
        }

        if panel.runModal() == .OK, let url = panel.url {
            isProcessing = true
            statusMessage = "Rendering full-resolution \(url.lastPathComponent)..."
            Task {
                if isAligned {
                    _ = await ensureFullResAlignedSynced()
                }
                guard let lRaw = activeLeftRGB, let rRaw = activeRightRGB else {
                    isProcessing = false
                    statusMessage = "Export failed."
                    return
                }
                let w = activeWidth, h = activeHeight
                let ok = await Task.detached(priority: .userInitiated) {
                    Self.renderAndSaveSingleFile(
                        left: lRaw, right: rRaw, width: w, height: h,
                        style: style, layout: layout, imageFormat: imgFormat, isSwapped: swapped,
                        cardConfig: cardCfg, mountContext: mountCtx,
                        restorationOptions: restOpts,
                        detailOptions: detailOpts,
                        to: url
                    )
                }.value
                isProcessing = false
                statusMessage = ok ? "Saved \(url.lastPathComponent)" : "Failed to save \(url.lastPathComponent)."
            }
        }
    }

    func exportAdjustmentReport() {
        guard let res = lastRectResult else { return }
        let p = res.params
        let report = """
        ViewStereo Alignment Report
        Left File       : \(leftURL?.path ?? "-")
        Right File      : \(rightURL?.path ?? "-")
        Original Size   : \(imageWidth) x \(imageHeight)
        Cropped Size    : \(croppedWidth) x \(croppedHeight)
        Matches / Inliers: \(matchCount) / \(inlierCount)
        Vertical RMSE   : \(String(format: "%.4f px", verticalRMSE))
        Window Shift X  : \(String(format: "%.3f px (Auto: %.3f px)", windowShiftX, autoOptimalShiftX))
        Log Scale (u_s) : \(p.logScale)
        Roll L / R (rad): \(p.rollL) / \(p.rollR)
        Keystone H L/R  : \(p.keystoneXL) / \(p.keystoneXR)
        Keystone V (k_y): \(p.keystoneY)
        Shift V (t_y)   : \(p.shiftY)
        """
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let base = leftURL?.deletingPathExtension().lastPathComponent ?? "ViewStereo"
        panel.nameFieldStringValue = "\(base)_adj.txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? report.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Saved \(url.lastPathComponent)"
        }
    }

    // MARK: - Folder Batch Auto-Alignment

    func openBatchFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder for Batch Auto-Align"
        if panel.runModal() == .OK, let dir = panel.url {
            batchInputFolder = dir
            batchOutputFolder = dir.appendingPathComponent("ViewStereo_Output", isDirectory: true)
            isBatchSectionExpanded = true
            startBatchProcessing(inputDir: dir)
        }
    }

    func chooseBatchOutputFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select Output Folder"
        if panel.runModal() == .OK, let dir = panel.url {
            batchOutputFolder = dir
        }
    }

    func dismissBatchCompletionNotice() {
        batchCompletionSummary = nil
    }

    func openBatchOutputFolderInFinder() {
        let dir = batchCompletionSummary?.outputDirectory ?? batchOutputFolder
        guard let dir else { return }
        NSWorkspace.shared.open(dir)
    }

    func cancelBatchProcessing() {
        batchTask?.cancel()
        batchTask = nil
        isBatchRunning = false
        statusMessage = "Batch processing cancelled."
    }

    func startBatchProcessing(inputDir: URL? = nil) {
        guard !isBatchRunning else { return }
        let targetDir = inputDir ?? batchInputFolder
        guard let targetDir else {
            openBatchFolderPanel()
            return
        }

        let outDir = batchOutputFolder ?? targetDir.appendingPathComponent("ViewStereo_Output", isDirectory: true)
        batchInputFolder = targetDir
        batchOutputFolder = outDir

        let pairingMode = batchPairingMode
        let items = Self.discoverBatchItems(in: targetDir, mode: pairingMode)
        guard !items.isEmpty else {
            statusMessage = "No stereo images found in \(targetDir.lastPathComponent)."
            return
        }

        let useMask = usePersonMotionMask
        let useSaliency = useAttentionSaliency
        let keepAR = keepOriginalAspectRatio
        let colorMode = autoColorMode
        let removeNoise = removeUnilateralNoise
        let cardMode = stereoCardMode
        let useCoreML = useCoreMLCardSegmentation
        let refiner = coreMLRefinerModel
        let style = frameStyle
        let layout = exportLayout
        let imgFormat = exportImageFormat
        let swapped = isSwapped
        let saveReport = batchSaveReport
        let restOpts = makeVintageRestorationOptions(ignorePreviewToggle: true)
        let detailOpts = makeDetailRestorationOptions(ignorePreviewToggle: true)
        if cardTextMode != .manualTypeset {
            clearCardMountTexts()
        }
        let baseCardCfg = makeCardMountConfig()
        let renderer = metalRenderer

        isBatchRunning = true
        batchCompletionSummary = nil
        batchTotalCount = items.count
        batchCompletedCount = 0
        batchFailedCount = 0
        batchProgress = 0.0
        batchCurrentFile = ""
        statusMessage = "Batch starting (\(items.count) items)..."

        batchTask = Task {
            do {
                try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            } catch {
                isBatchRunning = false
                statusMessage = "Failed to create output folder."
                return
            }

            var successCnt = 0
            var failCnt = 0

            for (idx, item) in items.enumerated() {
                if Task.isCancelled { break }
                batchCurrentFile = item.displayLabel
                statusMessage = "Batch [\(idx + 1)/\(items.count)]: \(item.displayLabel)"

                let stepResult = await Task.detached(priority: .userInitiated) { () -> Result<(AlignmentPipelineOutput, Int, Int, Bool, StereoCardSegmenter.OriginalCardMountContext?, StereoCardMountConfig), AlignmentPipelineError>? in
                    guard let (lRGB, rRGB, w, h, preservedArch, mountCtx) = Self.loadBatchPair(item: item, cardMode: cardMode, useCoreML: useCoreML, refiner: refiner) else {
                        return nil
                    }
                    let res = Self.executeAlignmentPipeline(
                        lRGB: lRGB,
                        rRGB: rRGB,
                        width: w,
                        height: h,
                        useMask: useMask,
                        useSaliency: useSaliency,
                        keepAR: keepAR,
                        colorMode: colorMode,
                        removeNoise: removeNoise,
                        preserveArch: preservedArch,
                        renderer: renderer
                    )
                    switch res {
                    case .failure(let e):
                        return .failure(e)
                    case .success(let out):
                        var itemCardCfg = baseCardCfg
                        itemCardCfg.sourceFilename = item.leftURL.lastPathComponent
                        itemCardCfg.preservedArchFromAI = preservedArch
                        if layout == .stereoviewCard && itemCardCfg.textMode == .ocrAuto, let ctx = mountCtx {
                            let rec = await StereoCardMountRenderer.recognizeTextsFromOriginalMount(ctx: ctx)
                            itemCardCfg.bottomCaption = rec.bottomCaption
                            itemCardCfg.topCenterText = rec.topCenter
                            itemCardCfg.leftMarginText = rec.leftMargin
                            itemCardCfg.rightMarginText = rec.rightMargin
                        }
                        let savedOK = Self.saveBatchOutput(
                            out: out,
                            item: item,
                            srcWidth: w,
                            srcHeight: h,
                            outDir: outDir,
                            layout: layout,
                            imageFormat: imgFormat,
                            isSwapped: swapped,
                            frameStyle: style,
                            cardConfig: itemCardCfg,
                            mountContext: mountCtx,
                            restorationOptions: restOpts,
                            detailOptions: detailOpts,
                            saveReport: saveReport
                        )
                        return savedOK ? .success((out, w, h, preservedArch, mountCtx, itemCardCfg)) : nil
                    }
                }.value

                if Task.isCancelled { break }

                if case .success(let (out, w, h, preservedArch, mountCtx, itemCfg)) = stepResult {
                    successCnt += 1
                    leftURL = item.leftURL
                    rightURL = item.rightURL ?? item.leftURL
                    isSingleSBSInput = (item.rightURL == nil)
                    hasPreservedArch = preservedArch
                    currentMountContext = mountCtx
                    if baseCardCfg.textMode == .ocrAuto {
                        cardBottomCaption = itemCfg.bottomCaption
                        cardTopCenterText = itemCfg.topCenterText
                        cardLeftMarginText = itemCfg.leftMarginText
                        cardRightMarginText = itemCfg.rightMarginText
                    }
                    imageWidth = w
                    imageHeight = h
                    applyAlignmentOutput(out)
                } else {
                    failCnt += 1
                }

                batchCompletedCount = idx + 1
                batchFailedCount = failCnt
                batchProgress = Double(idx + 1) / Double(items.count)
            }

            let cancelled = Task.isCancelled
            isBatchRunning = false
            batchTask = nil
            batchCompletionSummary = BatchCompletionSummary(
                succeeded: successCnt,
                failed: failCnt,
                total: items.count,
                wasCancelled: cancelled,
                outputDirectory: outDir
            )
            if cancelled {
                statusMessage = "Batch cancelled (\(successCnt)/\(items.count) completed)."
            } else {
                statusMessage = "Batch finished: \(successCnt) succeeded, \(failCnt) failed → \(outDir.lastPathComponent)/"
            }
        }
    }

    nonisolated private static func discoverBatchItems(in dir: URL, mode: StereoBatchPairingMode) -> [StereoBatchItem] {
        let exts = supportedImageExtensions
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let files = contents
            .filter { url in
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                return isFile && exts.contains(url.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

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

            // ペアにならなかった単体ファイルは SBS として追加（ただし相手側の R ファイル単体は除く）
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

    nonisolated private static func loadBatchPair(item: StereoBatchItem, cardMode: StereoCardMode, useCoreML: Bool, refiner: CoreMLRefinerModel = .mobileSAM) -> ([UInt8], [UInt8], Int, Int, Bool, StereoCardSegmenter.OriginalCardMountContext?)? {
        if let rURL = item.rightURL {
            guard let (lRGB, lw, lh) = loadNormalizedRGB(url: item.leftURL),
                  let (rRGBRaw, rw, rh) = loadNormalizedRGB(url: rURL) else {
                return nil
            }
            let rRGB = (lw == rw && lh == rh) ? rRGBRaw : resizeBilinearRGB(rRGBRaw, sw: rw, sh: rh, dw: lw, dh: lh)
            return (lRGB, rRGB, lw, lh, false, nil)
        } else {
            if let pair = loadStereoPairFromContainer(url: item.leftURL) {
                return (pair.0, pair.1, pair.2, pair.3, false, nil)
            }
            guard let (rgb, fw, fh) = loadNormalizedRGB(url: item.leftURL), fw >= 64 else {
                return nil
            }
            let extMode: StereoCardCropper.ExtractionMode = (cardMode == .keepArchBlack) ? .keepArchBlack : .cropInner
            if cardMode != .off,
               let card = (useCoreML ? StereoCardSegmenter.shared.extractPhotoPair(from: rgb, width: fw, height: fh, mode: extMode, refiner: refiner) : nil)
                       ?? StereoCardCropper.extractPhotoPair(from: rgb, width: fw, height: fh, mode: extMode) {
                let mountCtx = StereoCardSegmenter.shared.currentMountContext
                return (card.leftRGB, card.rightRGB, card.width, card.height, card.preservedArch, mountCtx)
            }
            let w = fw / 2
            var l = [UInt8](repeating: 0, count: w * fh * 3)
            var r = [UInt8](repeating: 0, count: w * fh * 3)
            for y in 0..<fh {
                let srcRow = y * fw * 3
                let dstRow = y * w * 3
                l[dstRow..<(dstRow + w * 3)] = rgb[srcRow..<(srcRow + w * 3)]
                r[dstRow..<(dstRow + w * 3)] = rgb[(srcRow + w * 3)..<(srcRow + w * 6)]
            }
            return (l, r, w, fh, false, nil)
        }
    }

    nonisolated private static func renderAndSaveSeparateLR(
        left: [UInt8],
        right: [UInt8],
        width: Int,
        height: Int,
        style: StereoFrameStyle,
        imageFormat: StereoExportImageFormat,
        restorationOptions: VintageRestorationOptions = VintageRestorationOptions(),
        detailOptions: StereoDetailRestorationOptions = StereoDetailRestorationOptions(),
        outL: URL,
        outR: URL
    ) -> Bool {
        var l = left
        var r = right
        if !restorationOptions.isIdentity || !detailOptions.isIdentity {
            let restored = applyVintagePipeline(left: l, right: r, width: width, height: height, toneOptions: restorationOptions, detailOptions: detailOptions)
            l = restored.left
            r = restored.right
        }
        applyFrameStyleIfNeeded(left: &l, right: &r, width: width, height: height, style: style)
        let trimmed = trimToTightBoundingBox(left: l, right: r, width: width, height: height)
        let tl = trimmed.left, tr = trimmed.right, tw = trimmed.width, th = trimmed.height
        switch imageFormat {
        case .jpeg:
            return saveRGB(tl, width: tw, height: th, to: outL, type: .jpeg)
                && saveRGB(tr, width: tw, height: th, to: outR, type: .jpeg)
        case .png:
            let rgbaL = convertToRGBA(from: tl, width: tw, height: th, transparentCorners: true)
            let rgbaR = convertToRGBA(from: tr, width: tw, height: th, transparentCorners: true)
            return saveRGBABuffer(rgbaL, width: tw, height: th, to: outL, hasAlpha: true)
                && saveRGBABuffer(rgbaR, width: tw, height: th, to: outR, hasAlpha: true)
        }
    }

    nonisolated private static func renderAndSaveSingleFile(
        left: [UInt8],
        right: [UInt8],
        width: Int,
        height: Int,
        style: StereoFrameStyle,
        layout: StereoExportLayout,
        imageFormat: StereoExportImageFormat,
        isSwapped: Bool,
        cardConfig: StereoCardMountConfig = StereoCardMountConfig(),
        mountContext: StereoCardSegmenter.OriginalCardMountContext? = nil,
        restorationOptions: VintageRestorationOptions = VintageRestorationOptions(),
        detailOptions: StereoDetailRestorationOptions = StereoDetailRestorationOptions(),
        to url: URL
    ) -> Bool {
        var l = left
        var r = right
        if !restorationOptions.isIdentity || !detailOptions.isIdentity {
            let restored = applyVintagePipeline(left: l, right: r, width: width, height: height, toneOptions: restorationOptions, detailOptions: detailOptions)
            l = restored.left
            r = restored.right
        }
        if layout != .stereoviewCard {
            applyFrameStyleIfNeeded(left: &l, right: &r, width: width, height: height, style: style)
        }
        let trimmed = trimToTightBoundingBox(left: l, right: r, width: width, height: height)
        let tl = isSwapped ? trimmed.right : trimmed.left
        let tr = isSwapped ? trimmed.left : trimmed.right
        let tw = trimmed.width, th = trimmed.height

        switch layout {
        case .twoD:
            switch imageFormat {
            case .jpeg:
                return saveRGB(tl, width: tw, height: th, to: url, type: .jpeg)
            case .png:
                let rgba = convertToRGBA(from: tl, width: tw, height: th, transparentCorners: true)
                return saveRGBABuffer(rgba, width: tw, height: th, to: url, hasAlpha: true)
            }
        case .sbs:
            switch imageFormat {
            case .jpeg:
                let combined = combineSBS(left: tl, right: tr, width: tw, height: th)
                return saveRGB(combined, width: tw * 2, height: th, to: url, type: .jpeg)
            case .png:
                let rgba1 = convertToRGBA(from: tl, width: tw, height: th, transparentCorners: true)
                let rgba2 = convertToRGBA(from: tr, width: tw, height: th, transparentCorners: true)
                let combinedRGBA = combineSBSRGBA(left: rgba1, right: rgba2, width: tw, height: th)
                return saveRGBABuffer(combinedRGBA, width: tw * 2, height: th, to: url, hasAlpha: true)
            }
        case .lrrl:
            switch imageFormat {
            case .jpeg:
                let grid = combineLRRL(left: tl, right: tr, width: tw, height: th)
                return saveRGB(grid, width: tw * 2, height: th * 2, to: url, type: .jpeg)
            case .png:
                let rgba1 = convertToRGBA(from: tl, width: tw, height: th, transparentCorners: true)
                let rgba2 = convertToRGBA(from: tr, width: tw, height: th, transparentCorners: true)
                let gridRGBA = combineLRRLRGBA(left: rgba1, right: rgba2, width: tw, height: th)
                return saveRGBABuffer(gridRGBA, width: tw * 2, height: th * 2, to: url, hasAlpha: true)
            }
        case .dubois, .colorAnaglyph, .grayAnaglyph:
            let type: AnaglyphType = (layout == .dubois) ? .dubois : (layout == .colorAnaglyph ? .color : .gray)
            let ana = makeAnaglyph(left: tl, right: tr, width: tw, height: th, type: type)
            switch imageFormat {
            case .jpeg:
                return saveRGB(ana, width: tw, height: th, to: url, type: .jpeg)
            case .png:
                let anaRGBA = convertToRGBA(from: ana, width: tw, height: th, transparentCorners: true)
                return saveRGBABuffer(anaRGBA, width: tw, height: th, to: url, hasAlpha: true)
            }
        case .polarized:
            switch imageFormat {
            case .jpeg:
                let pol = makePolarized(left: tl, right: tr, width: tw, height: th)
                return saveRGB(pol, width: tw, height: th, to: url, type: .jpeg)
            case .png:
                let rgba1 = convertToRGBA(from: tl, width: tw, height: th, transparentCorners: true)
                let rgba2 = convertToRGBA(from: tr, width: tw, height: th, transparentCorners: true)
                let polRGBA = makePolarizedRGBA(left: rgba1, right: rgba2, width: tw, height: th)
                return saveRGBABuffer(polRGBA, width: tw, height: th, to: url, hasAlpha: true)
            }
        case .stereoviewCard:
            switch imageFormat {
            case .jpeg:
                let card = StereoCardMountRenderer.renderCardRGB(
                    leftRGB: tl, rightRGB: tr, printWidth: tw, printHeight: th,
                    config: cardConfig, mountContext: mountContext
                )
                return saveRGB(card.rgb, width: card.width, height: card.height, to: url, type: .jpeg)
            case .png:
                let cardRGBA = StereoCardMountRenderer.renderCardRGBA(
                    leftRGB: tl, rightRGB: tr, printWidth: tw, printHeight: th,
                    config: cardConfig, mountContext: mountContext, transparentOuterCorners: true
                )
                return saveRGBABuffer(cardRGBA.rgba, width: cardRGBA.width, height: cardRGBA.height, to: url, hasAlpha: true)
            }
        case .spatialPhoto:
            return saveSpatialHEIC(left: tl, right: tr, width: tw, height: th, to: url)
        case .mpo:
            return saveMPO(left: tl, right: tr, width: tw, height: th, to: url)
        case .separateLR:
            return false
        }
    }

    nonisolated private static func saveBatchOutput(
        out: AlignmentPipelineOutput,
        item: StereoBatchItem,
        srcWidth: Int,
        srcHeight: Int,
        outDir: URL,
        layout: StereoExportLayout,
        imageFormat: StereoExportImageFormat,
        isSwapped: Bool,
        frameStyle: StereoFrameStyle,
        cardConfig: StereoCardMountConfig = StereoCardMountConfig(),
        mountContext: StereoCardSegmenter.OriginalCardMountContext? = nil,
        restorationOptions: VintageRestorationOptions = VintageRestorationOptions(),
        detailOptions: StereoDetailRestorationOptions = StereoDetailRestorationOptions(),
        saveReport: Bool
    ) -> Bool {
        let base = item.baseName
        let w = out.cw, h = out.ch
        let ext = imageFormat.fileExtension
        let restored = (restorationOptions.isIdentity && detailOptions.isIdentity)
            ? (left: out.warpedL, right: out.warpedR)
            : applyVintagePipeline(left: out.warpedL, right: out.warpedR, width: w, height: h, toneOptions: restorationOptions, detailOptions: detailOptions)
        let wL = restored.left
        let wR = restored.right
        let ok: Bool

        switch layout {
        case .twoD:
            ok = renderAndSaveSingleFile(
                left: wL, right: wR, width: w, height: h,
                style: frameStyle, layout: .twoD, imageFormat: imageFormat, isSwapped: isSwapped,
                to: outDir.appendingPathComponent("\(base)_2D.\(ext)")
            )
        case .sbs:
            ok = renderAndSaveSingleFile(
                left: wL, right: wR, width: w, height: h,
                style: frameStyle, layout: .sbs, imageFormat: imageFormat, isSwapped: isSwapped,
                to: outDir.appendingPathComponent("\(base)_SBS.\(ext)")
            )
        case .lrrl:
            ok = renderAndSaveSingleFile(
                left: wL, right: wR, width: w, height: h,
                style: frameStyle, layout: .lrrl, imageFormat: imageFormat, isSwapped: isSwapped,
                to: outDir.appendingPathComponent("\(base)_LRRL.\(ext)")
            )
        case .dubois:
            ok = renderAndSaveSingleFile(
                left: wL, right: wR, width: w, height: h,
                style: frameStyle, layout: .dubois, imageFormat: imageFormat, isSwapped: isSwapped,
                to: outDir.appendingPathComponent("\(base)_Dubois.\(ext)")
            )
        case .colorAnaglyph:
            ok = renderAndSaveSingleFile(
                left: wL, right: wR, width: w, height: h,
                style: frameStyle, layout: .colorAnaglyph, imageFormat: imageFormat, isSwapped: isSwapped,
                to: outDir.appendingPathComponent("\(base)_ColorAnaglyph.\(ext)")
            )
        case .grayAnaglyph:
            ok = renderAndSaveSingleFile(
                left: wL, right: wR, width: w, height: h,
                style: frameStyle, layout: .grayAnaglyph, imageFormat: imageFormat, isSwapped: isSwapped,
                to: outDir.appendingPathComponent("\(base)_GrayAnaglyph.\(ext)")
            )
        case .polarized:
            ok = renderAndSaveSingleFile(
                left: wL, right: wR, width: w, height: h,
                style: frameStyle, layout: .polarized, imageFormat: imageFormat, isSwapped: isSwapped,
                to: outDir.appendingPathComponent("\(base)_Polarized.\(ext)")
            )
        case .stereoviewCard:
            ok = renderAndSaveSingleFile(
                left: wL, right: wR, width: w, height: h,
                style: frameStyle, layout: .stereoviewCard, imageFormat: imageFormat, isSwapped: isSwapped,
                cardConfig: cardConfig, mountContext: mountContext,
                to: outDir.appendingPathComponent("\(base)_Card.\(ext)")
            )
        case .spatialPhoto:
            ok = renderAndSaveSingleFile(
                left: wL, right: wR, width: w, height: h,
                style: frameStyle, layout: .spatialPhoto, imageFormat: imageFormat, isSwapped: isSwapped,
                to: outDir.appendingPathComponent("\(base)_Spatial.heic")
            )
        case .mpo:
            ok = renderAndSaveSingleFile(
                left: wL, right: wR, width: w, height: h,
                style: frameStyle, layout: .mpo, imageFormat: imageFormat, isSwapped: isSwapped,
                to: outDir.appendingPathComponent("\(base).mpo")
            )
        case .separateLR:
            ok = renderAndSaveSeparateLR(
                left: isSwapped ? wR : wL,
                right: isSwapped ? wL : wR,
                width: w, height: h,
                style: frameStyle, imageFormat: imageFormat,
                outL: outDir.appendingPathComponent("\(base)_L.\(ext)"),
                outR: outDir.appendingPathComponent("\(base)_R.\(ext)")
            )
        }

        if ok && saveReport {
            let p = out.rectRes.params
            let report = """
            ViewStereo Batch Alignment Report
            Left File       : \(item.leftURL.path)
            Right File      : \(item.rightURL?.path ?? item.leftURL.path)
            Original Size   : \(srcWidth) x \(srcHeight)
            Cropped Size    : \(w) x \(h)
            Matches / Inliers: \(out.matches.count) / \(out.rectRes.inlierCount)
            Vertical RMSE   : \(String(format: "%.4f px", out.rectRes.verticalRMSEPixels))
            Window Shift X  : \(String(format: "%.3f px", out.windowDecision.optimalShiftX))
            Log Scale (u_s) : \(p.logScale)
            Roll L / R (rad): \(p.rollL) / \(p.rollR)
            Keystone H L/R  : \(p.keystoneXL) / \(p.keystoneXR)
            Keystone V (k_y): \(p.keystoneY)
            Shift V (t_y)   : \(p.shiftY)
            """
            try? report.write(to: outDir.appendingPathComponent("\(base)_adj.txt"), atomically: true, encoding: .utf8)
        }
        return ok
    }

    // MARK: - Static Image Processing Helpers

    /// MPO（マルチピクチャJPEG）および Apple 空間写真 HEIC（StereoPair グループ）から左右画像ペアを抽出
    nonisolated private static func loadStereoPairFromContainer(url: URL) -> ([UInt8], [UInt8], Int, Int)? {
        let ext = url.pathExtension.lowercased()
        guard ext == "mpo" || ext == "heic" || ext == "heics" else {
            return nil
        }

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let count = CGImageSourceGetCount(source)

            // Apple 空間写真 HEIC: kCGImagePropertyGroups の StereoPair 情報を確認
            if ext == "heic" || ext == "heics" {
                if count >= 2,
                   let fileProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
                   let groups = fileProps[kCGImagePropertyGroups] as? [[CFString: Any]] {
                    for grp in groups {
                        if let type = grp[kCGImagePropertyGroupType] as? String,
                           type == (kCGImagePropertyGroupTypeStereoPair as String),
                           let leftIdx = grp[kCGImagePropertyGroupImageIndexLeft] as? Int,
                           let rightIdx = grp[kCGImagePropertyGroupImageIndexRight] as? Int,
                           leftIdx < count, rightIdx < count,
                           let (lRGB, lw, lh) = loadNormalizedRGB(from: source, index: leftIdx),
                           let (rRGBRaw, rw, rh) = loadNormalizedRGB(from: source, index: rightIdx) {
                            let rRGB = (lw == rw && lh == rh) ? rRGBRaw : resizeBilinearRGB(rRGBRaw, sw: rw, sh: rh, dw: lw, dh: lh)
                            return (lRGB, rRGB, lw, lh)
                        }
                    }
                }
                return nil
            }

            // MPO: 2フレーム以上あれば index 0 (L) / index 1 (R) として読み込み
            if ext == "mpo", count >= 2,
               let (lRGB, lw, lh) = loadNormalizedRGB(from: source, index: 0),
               let (rRGBRaw, rw, rh) = loadNormalizedRGB(from: source, index: 1) {
                let rRGB = (lw == rw && lh == rh) ? rRGBRaw : resizeBilinearRGB(rRGBRaw, sw: rw, sh: rh, dw: lw, dh: lh)
                return (lRGB, rRGB, lw, lh)
            }
        }

        // MPO フォールバック: JPEG SOI マーカー (FF D8 FF) をスキャンして埋め込み JPEG 2枚を分離抽出
        if ext == "mpo", let data = try? Data(contentsOf: url) {
            var offsets: [Int] = []
            data.withUnsafeBytes { raw in
                guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                let len = data.count
                var i = 0
                while i + 3 < len {
                    if bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF && (bytes[i + 3] == 0xE0 || bytes[i + 3] == 0xE1) {
                        offsets.append(i)
                        i += 4
                        continue
                    }
                    i += 1
                }
            }
            if offsets.count >= 2 {
                let dataL = data.subdata(in: offsets[0]..<offsets[1])
                let dataR = data.subdata(in: offsets[1]..<data.count)
                if let srcL = CGImageSourceCreateWithData(dataL as CFData, nil),
                   let srcR = CGImageSourceCreateWithData(dataR as CFData, nil),
                   let (lRGB, lw, lh) = loadNormalizedRGB(from: srcL, index: 0),
                   let (rRGBRaw, rw, rh) = loadNormalizedRGB(from: srcR, index: 0) {
                    let rRGB = (lw == rw && lh == rh) ? rRGBRaw : resizeBilinearRGB(rRGBRaw, sw: rw, sh: rh, dw: lw, dh: lh)
                    return (lRGB, rRGB, lw, lh)
                }
            }
        }
        return nil
    }

    nonisolated static func loadNormalizedRGB(url: URL) -> ([UInt8], Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return loadNormalizedRGB(from: source, index: 0)
    }

    nonisolated private static func loadNormalizedRGB(from source: CGImageSource, index: Int) -> ([UInt8], Int, Int)? {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            return nil
        }

        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1

        let rawW = cgImage.width, rawH = cgImage.height
        let swapAxes = [5, 6, 7, 8].contains(orientation)
        let w = swapAxes ? rawH : rawW
        let h = swapAxes ? rawW : rawH

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // EXIF Orientation 補正変換を適用（CGContext 左下原点系）
        var transform = CGAffineTransform.identity
        switch orientation {
        case 2: transform = CGAffineTransform(translationX: CGFloat(w), y: 0).scaledBy(x: -1, y: 1)
        case 3: transform = CGAffineTransform(translationX: CGFloat(w), y: CGFloat(h)).rotated(by: .pi)
        case 4: transform = CGAffineTransform(translationX: 0, y: CGFloat(h)).scaledBy(x: 1, y: -1)
        case 5: transform = CGAffineTransform(translationX: CGFloat(w), y: CGFloat(h)).rotated(by: -.pi / 2).scaledBy(x: 1, y: -1)
        case 6: transform = CGAffineTransform(translationX: 0, y: CGFloat(h)).rotated(by: -.pi / 2)
        case 7: transform = CGAffineTransform(translationX: 0, y: 0).rotated(by: .pi / 2).scaledBy(x: 1, y: -1)
        case 8: transform = CGAffineTransform(translationX: CGFloat(w), y: 0).rotated(by: .pi / 2)
        default: break
        }
        ctx.concatenate(transform)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: rawW, height: rawH))

        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return (rgb, w, h)
    }

    /// 上下左右の端にある黒縁・片側欠損ライン（アナグリフのシアン/赤ライン）を検出して自動クロップ
    nonisolated private static func trimEdgeColorFringe(
        left: [UInt8],
        right: [UInt8],
        width: Int,
        height: Int
    ) -> ([UInt8], [UInt8], Int, Int) {
        guard width > 64, height > 64,
              left.count >= width * height * 3,
              right.count >= width * height * 3 else {
            return (left, right, width, height)
        }

        let maxTrimX = min(48, width / 25)
        let maxTrimY = min(48, height / 25)

        func isBadRow(_ y: Int) -> Bool {
            var darkL = 0, darkR = 0
            var sumL = 0, sumR = 0
            let rowOff = y * width * 3
            let step = max(1, width / 128)
            var samples = 0
            var x = 0
            while x < width {
                let idx = rowOff + x * 3
                let lMax = max(Int(left[idx]), max(Int(left[idx + 1]), Int(left[idx + 2])))
                let rMax = max(Int(right[idx]), max(Int(right[idx + 1]), Int(right[idx + 2])))
                if lMax < 16 { darkL += 1 }
                if rMax < 16 { darkR += 1 }
                sumL += lMax
                sumR += rMax
                samples += 1
                x += step
            }
            guard samples > 0 else { return false }
            let avgL = sumL / samples
            let avgR = sumR / samples
            let fracL = Double(darkL) / Double(samples)
            let fracR = Double(darkR) / Double(samples)
            if fracL > 0.95 && fracR > 0.95 { return true }
            if (fracL > 0.92 && avgL < 12 && avgR > 24) || (fracR > 0.92 && avgR < 12 && avgL > 24) { return true }
            return false
        }

        func isBadCol(_ x: Int) -> Bool {
            var darkL = 0, darkR = 0
            var sumL = 0, sumR = 0
            let step = max(1, height / 128)
            var samples = 0
            var y = 0
            while y < height {
                let idx = (y * width + x) * 3
                let lMax = max(Int(left[idx]), max(Int(left[idx + 1]), Int(left[idx + 2])))
                let rMax = max(Int(right[idx]), max(Int(right[idx + 1]), Int(right[idx + 2])))
                if lMax < 16 { darkL += 1 }
                if rMax < 16 { darkR += 1 }
                sumL += lMax
                sumR += rMax
                samples += 1
                y += step
            }
            guard samples > 0 else { return false }
            let avgL = sumL / samples
            let avgR = sumR / samples
            let fracL = Double(darkL) / Double(samples)
            let fracR = Double(darkR) / Double(samples)
            if fracL > 0.95 && fracR > 0.95 { return true }
            if (fracL > 0.92 && avgL < 12 && avgR > 24) || (fracR > 0.92 && avgR < 12 && avgL > 24) { return true }
            return false
        }

        var top = 0
        while top < maxTrimY && isBadRow(top) { top += 1 }
        var bottom = 0
        while bottom < maxTrimY && (height - 1 - bottom > top + 32) && isBadRow(height - 1 - bottom) { bottom += 1 }
        var leftTrim = 0
        while leftTrim < maxTrimX && isBadCol(leftTrim) { leftTrim += 1 }
        var rightTrim = 0
        while rightTrim < maxTrimX && (width - 1 - rightTrim > leftTrim + 32) && isBadCol(width - 1 - rightTrim) { rightTrim += 1 }

        guard top > 0 || bottom > 0 || leftTrim > 0 || rightTrim > 0 else {
            return (left, right, width, height)
        }

        let newW = width - leftTrim - rightTrim
        let newH = height - top - bottom
        guard newW >= 32, newH >= 32 else {
            return (left, right, width, height)
        }

        var outL = [UInt8](repeating: 0, count: newW * newH * 3)
        var outR = [UInt8](repeating: 0, count: newW * newH * 3)
        let rowBytes = newW * 3
        for y in 0..<newH {
            let srcOff = ((y + top) * width + leftTrim) * 3
            let dstOff = y * rowBytes
            outL[dstOff..<(dstOff + rowBytes)] = left[srcOff..<(srcOff + rowBytes)]
            outR[dstOff..<(dstOff + rowBytes)] = right[srcOff..<(srcOff + rowBytes)]
        }
        return (outL, outR, newW, newH)
    }

    nonisolated private static func applyFrameStyleIfNeeded(
        left: inout [UInt8],
        right: inout [UInt8],
        width: Int,
        height: Int,
        style: StereoFrameStyle
    ) {
        switch style {
        case .off:
            return
        case .rounded:
            let r = Double(min(width, height)) * 0.11
            StereoCardCropper.applyRoundedArchMask(&left, width: width, height: height, topRX: r, topRY: r, botRX: r, botRY: r)
            StereoCardCropper.applyRoundedArchMask(&right, width: width, height: height, topRX: r, topRY: r, botRX: r, botRY: r)
        case .arch:
            let topRX = Double(width) * 0.28
            let topRY = Double(height) * 0.24
            let botR = Double(min(width, height)) * 0.09
            StereoCardCropper.applyRoundedArchMask(&left, width: width, height: height, topRX: topRX, topRY: topRY, botRX: botR, botRY: botR)
            StereoCardCropper.applyRoundedArchMask(&right, width: width, height: height, topRX: topRX, topRY: topRY, botRX: botR, botRY: botR)
        }
    }

    nonisolated private static func cropHorizontalSlice(
        _ src: [UInt8],
        srcW: Int,
        height: Int,
        srcX: Int,
        cropW: Int
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cropW * height * 3)
        let rowBytes = cropW * 3
        for y in 0..<height {
            let sOff = (y * srcW + srcX) * 3
            let dOff = y * rowBytes
            out[dOff..<(dOff + rowBytes)] = src[sOff..<(sOff + rowBytes)]
        }
        return out
    }

    nonisolated private static func downsampleForPreview(_ src: [UInt8], width: Int, height: Int, maxDim: Int) -> ([UInt8], Int, Int) {
        let longEdge = max(width, height)
        guard longEdge > maxDim, width > 0, height > 0 else {
            return (src, width, height)
        }
        let scale = Double(maxDim) / Double(longEdge)
        let dw = max(16, Int((Double(width) * scale).rounded()))
        let dh = max(16, Int((Double(height) * scale).rounded()))
        return (resizeBilinearRGB(src, sw: width, sh: height, dw: dw, dh: dh), dw, dh)
    }

    nonisolated private static func resizeBilinearRGB(_ src: [UInt8], sw: Int, sh: Int, dw: Int, dh: Int) -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: dw * dh * 3)
        let scaleX = Float(sw) / Float(dw), scaleY = Float(sh) / Float(dh)
        src.withUnsafeBufferPointer { sPtr in
            dst.withUnsafeMutableBufferPointer { dPtr in
                guard let s = sPtr.baseAddress, let d = dPtr.baseAddress else { return }
                for y in 0..<dh {
                    let fy = Float(y) * scaleY
                    let y0 = Int(fy), y1 = min(y0 + 1, sh - 1)
                    let ay = fy - Float(y0)
                    let row0 = y0 * sw * 3
                    let row1 = y1 * sw * 3
                    let dRow = y * dw * 3
                    for x in 0..<dw {
                        let fx = Float(x) * scaleX
                        let x0 = Int(fx), x1 = min(x0 + 1, sw - 1)
                        let ax = fx - Float(x0)
                        let w00 = (1 - ax) * (1 - ay)
                        let w10 = ax * (1 - ay)
                        let w01 = (1 - ax) * ay
                        let w11 = ax * ay
                        let p00 = row0 + x0 * 3
                        let p10 = row0 + x1 * 3
                        let p01 = row1 + x0 * 3
                        let p11 = row1 + x1 * 3
                        let di = dRow + x * 3
                        d[di]     = UInt8(min(255, max(0, Int(Float(s[p00])     * w00 + Float(s[p10])     * w10 + Float(s[p01])     * w01 + Float(s[p11])     * w11 + 0.5))))
                        d[di + 1] = UInt8(min(255, max(0, Int(Float(s[p00 + 1]) * w00 + Float(s[p10 + 1]) * w10 + Float(s[p01 + 1]) * w01 + Float(s[p11 + 1]) * w11 + 0.5))))
                        d[di + 2] = UInt8(min(255, max(0, Int(Float(s[p00 + 2]) * w00 + Float(s[p10 + 2]) * w10 + Float(s[p01 + 2]) * w01 + Float(s[p11 + 2]) * w11 + 0.5))))
                    }
                }
            }
        }
        return dst
    }

    nonisolated private static func combineSBS(left: [UInt8], right: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * 2 * height * 3)
        for y in 0..<height {
            let srcRow = y * width * 3
            let dstL = y * width * 2 * 3
            let dstR = dstL + width * 3
            out[dstL..<(dstL + width * 3)] = left[srcRow..<(srcRow + width * 3)]
            out[dstR..<(dstR + width * 3)] = right[srcRow..<(srcRow + width * 3)]
        }
        return out
    }

    nonisolated private static func combineSBSRGBA(left: [UInt8], right: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * 2 * height * 4)
        for y in 0..<height {
            let srcRow = y * width * 4
            let dstL = y * width * 2 * 4
            let dstR = dstL + width * 4
            out[dstL..<(dstL + width * 4)] = left[srcRow..<(srcRow + width * 4)]
            out[dstR..<(dstR + width * 4)] = right[srcRow..<(srcRow + width * 4)]
        }
        return out
    }

    nonisolated private static func combineLRRL(left: [UInt8], right: [UInt8], width: Int, height: Int) -> [UInt8] {
        let outW = width * 2
        let outH = height * 2
        var out = [UInt8](repeating: 0, count: outW * outH * 3)
        let rowBytes = width * 3
        let outRowBytes = outW * 3
        for y in 0..<height {
            let srcRow = y * rowBytes
            // 上段: L | R
            let topDstL = y * outRowBytes
            let topDstR = topDstL + rowBytes
            out[topDstL..<(topDstL + rowBytes)] = left[srcRow..<(srcRow + rowBytes)]
            out[topDstR..<(topDstR + rowBytes)] = right[srcRow..<(srcRow + rowBytes)]
            // 下段: R | L
            let botDstL = (y + height) * outRowBytes
            let botDstR = botDstL + rowBytes
            out[botDstL..<(botDstL + rowBytes)] = right[srcRow..<(srcRow + rowBytes)]
            out[botDstR..<(botDstR + rowBytes)] = left[srcRow..<(srcRow + rowBytes)]
        }

        // 外枠と中央十字の細い境界線（黒）
        let b = max(2, min(outW, outH) / 400)
        let bh = max(1, b / 2)
        // 水平線（上端・中央・下端）
        for y in 0..<outH {
            if y < b || y >= outH - b || abs(y - height) < bh {
                let rowStart = y * outRowBytes
                for i in 0..<outRowBytes { out[rowStart + i] = 0 }
            } else {
                let rowStart = y * outRowBytes
                // 左端・中央・右端の垂直線
                for x in 0..<b {
                    let iL = rowStart + x * 3
                    let iR = rowStart + (outW - 1 - x) * 3
                    out[iL] = 0; out[iL + 1] = 0; out[iL + 2] = 0
                    out[iR] = 0; out[iR + 1] = 0; out[iR + 2] = 0
                }
                for x in max(0, width - bh)..<min(outW, width + bh) {
                    let iC = rowStart + x * 3
                    out[iC] = 0; out[iC + 1] = 0; out[iC + 2] = 0
                }
            }
        }
        return out
    }

    nonisolated private static func combineLRRLRGBA(left: [UInt8], right: [UInt8], width: Int, height: Int) -> [UInt8] {
        let outW = width * 2
        let outH = height * 2
        var out = [UInt8](repeating: 0, count: outW * outH * 4)
        let rowBytes = width * 4
        let outRowBytes = outW * 4
        for y in 0..<height {
            let srcRow = y * rowBytes
            let topDstL = y * outRowBytes
            let topDstR = topDstL + rowBytes
            out[topDstL..<(topDstL + rowBytes)] = left[srcRow..<(srcRow + rowBytes)]
            out[topDstR..<(topDstR + rowBytes)] = right[srcRow..<(srcRow + rowBytes)]

            let botDstL = (y + height) * outRowBytes
            let botDstR = botDstL + rowBytes
            out[botDstL..<(botDstL + rowBytes)] = right[srcRow..<(srcRow + rowBytes)]
            out[botDstR..<(botDstR + rowBytes)] = left[srcRow..<(srcRow + rowBytes)]
        }

        let b = max(2, min(outW, outH) / 400)
        let bh = max(1, b / 2)
        for y in 0..<outH {
            let rowStart = y * outRowBytes
            if y < b || y >= outH - b || abs(y - height) < bh {
                for x in 0..<outW {
                    let i = rowStart + x * 4
                    out[i] = 0; out[i + 1] = 0; out[i + 2] = 0; out[i + 3] = 255
                }
            } else {
                for x in 0..<b {
                    let iL = rowStart + x * 4
                    let iR = rowStart + (outW - 1 - x) * 4
                    out[iL] = 0; out[iL + 1] = 0; out[iL + 2] = 0; out[iL + 3] = 255
                    out[iR] = 0; out[iR + 1] = 0; out[iR + 2] = 0; out[iR + 3] = 255
                }
                for x in max(0, width - bh)..<min(outW, width + bh) {
                    let iC = rowStart + x * 4
                    out[iC] = 0; out[iC + 1] = 0; out[iC + 2] = 0; out[iC + 3] = 255
                }
            }
        }
        return out
    }

    nonisolated private static func makePolarized(left: [UInt8], right: [UInt8], width: Int, height: Int) -> [UInt8] {
        let rowBytes = width * 3
        var out = [UInt8](repeating: 0, count: height * rowBytes)
        for y in 0..<height {
            let rowStart = y * rowBytes
            if (y & 1) == 0 {
                out[rowStart..<(rowStart + rowBytes)] = left[rowStart..<(rowStart + rowBytes)]
            } else {
                out[rowStart..<(rowStart + rowBytes)] = right[rowStart..<(rowStart + rowBytes)]
            }
        }
        return out
    }

    nonisolated private static func makePolarizedRGBA(left: [UInt8], right: [UInt8], width: Int, height: Int) -> [UInt8] {
        let rowBytes = width * 4
        var out = [UInt8](repeating: 0, count: height * rowBytes)
        for y in 0..<height {
            let rowStart = y * rowBytes
            if (y & 1) == 0 {
                out[rowStart..<(rowStart + rowBytes)] = left[rowStart..<(rowStart + rowBytes)]
            } else {
                out[rowStart..<(rowStart + rowBytes)] = right[rowStart..<(rowStart + rowBytes)]
            }
        }
        return out
    }

    nonisolated private static func makeAnaglyph(left: [UInt8], right: [UInt8], width: Int, height: Int, type: AnaglyphType = .gray) -> [UInt8] {
        let count = width * height
        var out = [UInt8](repeating: 0, count: count * 3)
        left.withUnsafeBufferPointer { lPtr in
            right.withUnsafeBufferPointer { rPtr in
                out.withUnsafeMutableBufferPointer { oPtr in
                    guard let l = lPtr.baseAddress, let r = rPtr.baseAddress, let o = oPtr.baseAddress else { return }
                    switch type {
                    case .gray:
                        for i in 0..<count {
                            let idx = i * 3
                            let lGray = (77 * Int(l[idx]) + 150 * Int(l[idx + 1]) + 29 * Int(l[idx + 2])) >> 8
                            let rGray = (77 * Int(r[idx]) + 150 * Int(r[idx + 1]) + 29 * Int(r[idx + 2])) >> 8
                            o[idx] = UInt8(lGray)
                            o[idx + 1] = UInt8(rGray)
                            o[idx + 2] = UInt8(rGray)
                        }
                    case .color:
                        for i in 0..<count {
                            let idx = i * 3
                            o[idx] = l[idx]
                            o[idx + 1] = r[idx + 1]
                            o[idx + 2] = r[idx + 2]
                        }
                    case .dubois:
                        for i in 0..<count {
                            let idx = i * 3
                            let lr = Float(l[idx]), lg = Float(l[idx + 1]), lb = Float(l[idx + 2])
                            let rr = Float(r[idx]), rg = Float(r[idx + 1]), rb = Float(r[idx + 2])
                            let outR = 0.437 * lr + 0.449 * lg + 0.164 * lb - 0.011 * rr - 0.032 * rg - 0.007 * rb
                            let outG = -0.062 * lr - 0.062 * lg - 0.024 * lb + 0.377 * rr + 0.761 * rg + 0.009 * rb
                            let outB = -0.048 * lr - 0.050 * lg - 0.017 * lb - 0.026 * rr - 0.093 * rg + 1.234 * rb
                            o[idx] = UInt8(max(0, min(255, Int(outR + 0.5))))
                            o[idx + 1] = UInt8(max(0, min(255, Int(outG + 0.5))))
                            o[idx + 2] = UInt8(max(0, min(255, Int(outB + 0.5))))
                        }
                    }
                }
            }
        }
        return out
    }

    nonisolated private static func renderPreviewNSImage(
        left: [UInt8],
        right: [UInt8],
        width: Int,
        height: Int,
        mode: StereoDisplayMode,
        isSwapped: Bool,
        transparentCorners: Bool,
        cardConfig: StereoCardMountConfig = StereoCardMountConfig(),
        mountContext: StereoCardSegmenter.OriginalCardMountContext? = nil
    ) -> NSImage? {
        let tl = isSwapped ? right : left
        let tr = isSwapped ? left : right

        switch mode {
        case .twoD:
            if transparentCorners {
                let rgba = convertToRGBA(from: tl, width: width, height: height, transparentCorners: true)
                return makeNSImageFromRGBA(rgba, width: width, height: height, hasAlpha: true)
            }
            return makeNSImage(from: tl, width: width, height: height)
        case .sbs:
            if transparentCorners {
                let rgbaL = convertToRGBA(from: tl, width: width, height: height, transparentCorners: true)
                let rgbaR = convertToRGBA(from: tr, width: width, height: height, transparentCorners: true)
                let combinedRGBA = combineSBSRGBA(left: rgbaL, right: rgbaR, width: width, height: height)
                return makeNSImageFromRGBA(combinedRGBA, width: width * 2, height: height, hasAlpha: true)
            }
            let combined = combineSBS(left: tl, right: tr, width: width, height: height)
            return makeNSImage(from: combined, width: width * 2, height: height)
        case .lrrl:
            if transparentCorners {
                let rgbaL = convertToRGBA(from: tl, width: width, height: height, transparentCorners: true)
                let rgbaR = convertToRGBA(from: tr, width: width, height: height, transparentCorners: true)
                let gridRGBA = combineLRRLRGBA(left: rgbaL, right: rgbaR, width: width, height: height)
                return makeNSImageFromRGBA(gridRGBA, width: width * 2, height: height * 2, hasAlpha: true)
            }
            let grid = combineLRRL(left: tl, right: tr, width: width, height: height)
            return makeNSImage(from: grid, width: width * 2, height: height * 2)
        case .dubois, .colorAnaglyph, .grayAnaglyph:
            let type: AnaglyphType = (mode == .dubois) ? .dubois : (mode == .colorAnaglyph ? .color : .gray)
            let ana = makeAnaglyph(left: tl, right: tr, width: width, height: height, type: type)
            if transparentCorners {
                let anaRGBA = convertToRGBA(from: ana, width: width, height: height, transparentCorners: true)
                return makeNSImageFromRGBA(anaRGBA, width: width, height: height, hasAlpha: true)
            }
            return makeNSImage(from: ana, width: width, height: height)
        case .polarized:
            if transparentCorners {
                let rgbaL = convertToRGBA(from: tl, width: width, height: height, transparentCorners: true)
                let rgbaR = convertToRGBA(from: tr, width: width, height: height, transparentCorners: true)
                let polRGBA = makePolarizedRGBA(left: rgbaL, right: rgbaR, width: width, height: height)
                return makeNSImageFromRGBA(polRGBA, width: width, height: height, hasAlpha: true)
            }
            let pol = makePolarized(left: tl, right: tr, width: width, height: height)
            return makeNSImage(from: pol, width: width, height: height)
        case .stereoviewCard:
            let card = StereoCardMountRenderer.renderCardRGBA(
                leftRGB: tl,
                rightRGB: tr,
                printWidth: width,
                printHeight: height,
                config: cardConfig,
                mountContext: mountContext,
                transparentOuterCorners: true
            )
            return makeNSImageFromRGBA(card.rgba, width: card.width, height: card.height, hasAlpha: true)
        }
    }

    nonisolated private static func drawMatchesOverlay(left: [UInt8], right: [UInt8], width: Int, height: Int, matches: [StereoMatchPoint]) -> [UInt8] {
        var buf = combineSBS(left: left, right: right, width: width, height: height)
        let outW = width * 2
        let colors: [[UInt8]] = [[80, 220, 255], [100, 255, 130], [255, 180, 60], [255, 90, 140], [180, 120, 255]]
        let inliers = matches.filter { $0.isInlier }
        let maxDisplayLines = 120
        let strideStep = max(1, inliers.count / maxDisplayLines)

        for (i, m) in inliers.enumerated() where i % strideStep == 0 {
            let col = colors[(i / strideStep) % colors.count]
            let x0 = Int(m.x1 + 0.5), y0 = Int(m.y1 + 0.5)
            let x1 = Int(m.x2 + 0.5) + width, y1 = Int(m.y2 + 0.5)
            var cx = x0, cy = y0
            let dx = abs(x1 - x0), dy = abs(y1 - y0)
            let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
            var err = dx - dy
            while true {
                if cx >= 0 && cx < outW && cy >= 0 && cy < height {
                    let idx = (cy * outW + cx) * 3
                    buf[idx] = col[0]; buf[idx + 1] = col[1]; buf[idx + 2] = col[2]
                }
                if cx == x1 && cy == y1 { break }
                let e2 = 2 * err
                if e2 > -dy { err -= dy; cx += sx }
                if e2 < dx { err += dx; cy += sy }
            }
            for d in -3...3 {
                for (px, py) in [(x0 + d, y0), (x0, y0 + d), (x1 + d, y1), (x1, y1 + d)] {
                    if px >= 0 && px < outW && py >= 0 && py < height {
                        let idx = (py * outW + px) * 3
                        buf[idx] = col[0]; buf[idx + 1] = col[1]; buf[idx + 2] = col[2]
                    }
                }
            }
        }
        return buf
    }

    nonisolated private static func makeCGImage(from rgb: [UInt8], width: Int, height: Int) -> CGImage? {
        let count = width * height
        guard rgb.count >= count * 3 else { return nil }
        var rgba = [UInt8](repeating: 255, count: count * 4)
        rgb.withUnsafeBufferPointer { sPtr in
            rgba.withUnsafeMutableBufferPointer { dPtr in
                guard let s = sPtr.baseAddress, let d = dPtr.baseAddress else { return }
                for i in 0..<count {
                    let si = i * 3
                    let di = i * 4
                    d[di] = s[si]
                    d[di + 1] = s[si + 1]
                    d[di + 2] = s[si + 2]
                }
            }
        }
        guard let cfData = CFDataCreate(kCFAllocatorDefault, rgba, rgba.count),
              let provider = CGDataProvider(data: cfData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    nonisolated private static func makeNSImage(from rgb: [UInt8], width: Int, height: Int) -> NSImage? {
        guard let cg = makeCGImage(from: rgb, width: width, height: height) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    nonisolated private static func convertToRGBA(
        from rgb: [UInt8],
        width: Int,
        height: Int,
        transparentCorners: Bool,
        isSBS: Bool = false
    ) -> [UInt8] {
        let count = width * height
        guard rgb.count >= count * 3 else { return [] }
        var rgba = [UInt8](repeating: 255, count: count * 4)

        if transparentCorners {
            var isCorner = [Bool](repeating: false, count: count)
            var queue = [Int]()
            queue.reserveCapacity(width * 8)

            var seeds = [Int]()
            if isSBS && width >= 4 {
                let halfW = width / 2
                // 左半分の4隅 + 右半分の4隅（計8隅）
                // これにより外周4隅だけでなく、中央上部の谷間と中央下部の谷間も完全に透明化される！
                seeds = [
                    0, halfW - 1, (height - 1) * width, (height - 1) * width + halfW - 1,
                    halfW, width - 1, (height - 1) * width + halfW, (height - 1) * width + width - 1
                ]
            } else {
                seeds = [0, width - 1, (height - 1) * width, (height - 1) * width + width - 1]
            }

            for c in seeds {
                let si = c * 3
                if max(rgb[si], max(rgb[si + 1], rgb[si + 2])) <= 36 {
                    isCorner[c] = true
                    queue.append(c)
                }
            }

            var head = 0
            while head < queue.count {
                let idx = queue[head]
                head += 1
                let x = idx % width
                let y = idx / width

                if x > 0 {
                    let n = idx - 1
                    if !isCorner[n] && max(rgb[n * 3], max(rgb[n * 3 + 1], rgb[n * 3 + 2])) <= 36 {
                        isCorner[n] = true
                        queue.append(n)
                    }
                }
                if x < width - 1 {
                    let n = idx + 1
                    if !isCorner[n] && max(rgb[n * 3], max(rgb[n * 3 + 1], rgb[n * 3 + 2])) <= 36 {
                        isCorner[n] = true
                        queue.append(n)
                    }
                }
                if y > 0 {
                    let n = idx - width
                    if !isCorner[n] && max(rgb[n * 3], max(rgb[n * 3 + 1], rgb[n * 3 + 2])) <= 36 {
                        isCorner[n] = true
                        queue.append(n)
                    }
                }
                if y < height - 1 {
                    let n = idx + width
                    if !isCorner[n] && max(rgb[n * 3], max(rgb[n * 3 + 1], rgb[n * 3 + 2])) <= 36 {
                        isCorner[n] = true
                        queue.append(n)
                    }
                }
            }

            rgb.withUnsafeBufferPointer { sPtr in
                rgba.withUnsafeMutableBufferPointer { dPtr in
                    guard let s = sPtr.baseAddress, let d = dPtr.baseAddress else { return }
                    for i in 0..<count {
                        let si = i * 3
                        let di = i * 4
                        let r = s[si]
                        let g = s[si + 1]
                        let b = s[si + 2]

                        if isCorner[i] {
                            let maxVal = max(r, max(g, b))
                            if maxVal <= 6 {
                                d[di] = 0; d[di + 1] = 0; d[di + 2] = 0; d[di + 3] = 0
                            } else {
                                let alpha = Float(maxVal - 6) / 30.0
                                let aByte = UInt8(min(255, max(0, Int(alpha * 255.0 + 0.5))))
                                d[di] = r
                                d[di + 1] = g
                                d[di + 2] = b
                                d[di + 3] = aByte
                            }
                        } else {
                            d[di] = r
                            d[di + 1] = g
                            d[di + 2] = b
                            d[di + 3] = 255
                        }
                    }
                }
            }
        } else {
            rgb.withUnsafeBufferPointer { sPtr in
                rgba.withUnsafeMutableBufferPointer { dPtr in
                    guard let s = sPtr.baseAddress, let d = dPtr.baseAddress else { return }
                    for i in 0..<count {
                        let si = i * 3
                        let di = i * 4
                        d[di] = s[si]
                        d[di + 1] = s[si + 1]
                        d[di + 2] = s[si + 2]
                        d[di + 3] = 255
                    }
                }
            }
        }
        return rgba
    }

    nonisolated private static func makeCGImageFromRGBA(_ rgba: [UInt8], width: Int, height: Int, hasAlpha: Bool) -> CGImage? {
        guard let cfData = CFDataCreate(kCFAllocatorDefault, rgba, rgba.count),
              let provider = CGDataProvider(data: cfData) else { return nil }
        let alphaInfo = hasAlpha ? CGImageAlphaInfo.last : CGImageAlphaInfo.noneSkipLast
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    nonisolated private static func makeNSImageFromRGBA(_ rgba: [UInt8], width: Int, height: Int, hasAlpha: Bool) -> NSImage? {
        guard let cg = makeCGImageFromRGBA(rgba, width: width, height: height, hasAlpha: hasAlpha) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    @discardableResult
    nonisolated private static func saveRGBABuffer(_ rgba: [UInt8], width: Int, height: Int, to url: URL, hasAlpha: Bool) -> Bool {
        guard let cg = makeCGImageFromRGBA(rgba, width: width, height: height, hasAlpha: hasAlpha),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }

    @discardableResult
    nonisolated private static func saveRGBA(_ rgb: [UInt8], width: Int, height: Int, to url: URL, transparentCorners: Bool, isSBS: Bool = false) -> Bool {
        let rgba = convertToRGBA(from: rgb, width: width, height: height, transparentCorners: transparentCorners, isSBS: isSBS)
        return saveRGBABuffer(rgba, width: width, height: height, to: url, hasAlpha: transparentCorners)
    }

    nonisolated private static func trimToTightBoundingBox(
        left: [UInt8],
        right: [UInt8],
        width: Int,
        height: Int
    ) -> (left: [UInt8], right: [UInt8], width: Int, height: Int) {
        let threshold: UInt8 = 24

        func findBBox(img: [UInt8]) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
            var minX = width, maxX = -1, minY = height, maxY = -1
            for y in 0..<height {
                let rowOffset = y * width * 3
                for x in 0..<width {
                    let idx = rowOffset + x * 3
                    if img[idx] > threshold || img[idx + 1] > threshold || img[idx + 2] > threshold {
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                }
            }
            if minX > maxX || minY > maxY { return nil }

            // 端の1pxがリサンプリングで暗くなったフリンジ（黒ライン）である場合、左右と上端をインセット
            // （下端の maxY は足先や靴底を守るため削らず保持する）
            if minX + 2 < maxX && minY + 2 < maxY {
                minX += 1
                maxX -= 1
                minY += 1
            }
            return (minX, maxX, minY, maxY)
        }

        let bboxL = findBBox(img: left)
        let bboxR = findBBox(img: right)

        guard let bL = bboxL, let bR = bboxR else {
            return (left, right, width, height)
        }

        let minY = min(bL.minY, bR.minY)
        let maxY = max(bL.maxY, bR.maxY)
        let targetH = max(1, maxY - minY + 1)

        let wL = max(1, bL.maxX - bL.minX + 1)
        let wR = max(1, bR.maxX - bR.minX + 1)
        let targetW = max(wL, wR)

        // If practically full frame, keep original
        if targetW >= width && targetH >= height {
            return (left, right, width, height)
        }

        let startX_L = max(0, min(width - targetW, bL.minX - (targetW - wL) / 2))
        let startX_R = max(0, min(width - targetW, bR.minX - (targetW - wR) / 2))

        var croppedL = [UInt8](repeating: 0, count: targetW * targetH * 3)
        var croppedR = [UInt8](repeating: 0, count: targetW * targetH * 3)

        for dy in 0..<targetH {
            let sy = minY + dy
            if sy < 0 || sy >= height { continue }
            let srcRowL = sy * width * 3
            let srcRowR = sy * width * 3
            let dstRow = dy * targetW * 3

            for dx in 0..<targetW {
                let sxL = startX_L + dx
                if sxL >= 0 && sxL < width {
                    let sIdx = srcRowL + sxL * 3
                    let dIdx = dstRow + dx * 3
                    croppedL[dIdx] = left[sIdx]
                    croppedL[dIdx + 1] = left[sIdx + 1]
                    croppedL[dIdx + 2] = left[sIdx + 2]
                }
                let sxR = startX_R + dx
                if sxR >= 0 && sxR < width {
                    let sIdx = srcRowR + sxR * 3
                    let dIdx = dstRow + dx * 3
                    croppedR[dIdx] = right[sIdx]
                    croppedR[dIdx + 1] = right[sIdx + 1]
                    croppedR[dIdx + 2] = right[sIdx + 2]
                }
            }
        }

        return (croppedL, croppedR, targetW, targetH)
    }

    @discardableResult
    nonisolated private static func saveRGB(_ rgb: [UInt8], width: Int, height: Int, to url: URL, type: UTType) -> Bool {
        guard let cg = makeCGImage(from: rgb, width: width, height: height),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            return false
        }
        let props: [CFString: Any] = (type == .jpeg) ? [kCGImageDestinationLossyCompressionQuality: 0.95] : [:]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    nonisolated private static func saveSpatialHEIC(left: [UInt8], right: [UInt8], width: Int, height: Int, to url: URL) -> Bool {
        guard let cgL = makeCGImage(from: left, width: width, height: height),
              let cgR = makeCGImage(from: right, width: width, height: height) else {
            return false
        }
        return SpatialPhotoExporter.export(
            leftImage: cgL,
            rightImage: cgR,
            to: url,
            fovHorizontalDegrees: 60.0,
            baselineMM: 63.0,
            disparityAdjustment: 0.0,
            projectionKind: .rectilinear
        )
    }

    nonisolated private static func encodeJPEGData(from rgb: [UInt8], width: Int, height: Int, quality: Double = 0.95) -> Data? {
        guard let cg = makeCGImage(from: rgb, width: width, height: height) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// CIPA DC-007 準拠 MPF (APP2) ヘッダ付き MPO ファイルを書き出す
    nonisolated private static func saveMPO(left: [UInt8], right: [UInt8], width: Int, height: Int, to url: URL) -> Bool {
        guard let jpg1 = encodeJPEGData(from: left, width: width, height: height),
              let jpg2 = encodeJPEGData(from: right, width: width, height: height),
              jpg1.count > 2, jpg1[0] == 0xFF, jpg1[1] == 0xD8 else {
            return false
        }

        // MPF APP2 ペイロード: "MPF\0" (4B) + TIFF Header (8B) + IFD (2 + 3*12 + 4 = 42B) + 2*MPEntry (32B) = 86B
        let app2PayloadSize = 86
        let app2SegmentSize = 2 + 2 + app2PayloadSize // FF E2 + len(2B) + payload = 90B
        let img1TotalSize = jpg1.count + app2SegmentSize
        // MPF TIFF Header 開始位置 ("MM") は先頭 SOI(2B) + FF E2(2B) + len(2B) + "MPF\0"(4B) = 10B
        let mpfBaseOffset = 10
        let img2DataOffset = UInt32(img1TotalSize - mpfBaseOffset)

        var app2 = Data()
        func appendU16(_ v: UInt16) {
            app2.append(UInt8((v >> 8) & 0xFF))
            app2.append(UInt8(v & 0xFF))
        }
        func appendU32(_ v: UInt32) {
            app2.append(UInt8((v >> 24) & 0xFF))
            app2.append(UInt8((v >> 16) & 0xFF))
            app2.append(UInt8((v >> 8) & 0xFF))
            app2.append(UInt8(v & 0xFF))
        }

        // APP2 マーカー & 長さ
        app2.append(contentsOf: [0xFF, 0xE2])
        appendU16(UInt16(2 + app2PayloadSize))
        // "MPF\0"
        app2.append(contentsOf: [0x4D, 0x50, 0x46, 0x00])
        // TIFF Header (Big-Endian "MM", 42, IFD offset = 8)
        app2.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A])
        appendU32(8)
        // MP Index IFD (3 entries)
        appendU16(3)
        // Entry 1: MPFVersion (0xB000, UNDEFINED=7, count=4, "0100")
        appendU16(0xB000); appendU16(7); appendU32(4); app2.append(contentsOf: [0x30, 0x31, 0x30, 0x30])
        // Entry 2: NumberOfImages (0xB001, LONG=4, count=1, value=2)
        appendU16(0xB001); appendU16(4); appendU32(1); appendU32(2)
        // Entry 3: MPEntry (0xB002, UNDEFINED=7, count=32, offset=50)
        appendU16(0xB002); appendU16(7); appendU32(32); appendU32(50)
        // Next IFD Offset = 0
        appendU32(0)

        // MP Entry 1 (Left: Representative + Multi-Frame Disparity + JPEG)
        appendU32(0x20030002)
        appendU32(UInt32(img1TotalSize))
        appendU32(0)
        appendU32(0)

        // MP Entry 2 (Right: Multi-Frame Disparity + JPEG)
        appendU32(0x00030002)
        appendU32(UInt32(jpg2.count))
        appendU32(img2DataOffset)
        appendU32(0)

        var mpoData = Data(capacity: img1TotalSize + jpg2.count)
        mpoData.append(jpg1.prefix(2))
        mpoData.append(app2)
        mpoData.append(jpg1.dropFirst(2))
        mpoData.append(jpg2)

        do {
            try mpoData.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
