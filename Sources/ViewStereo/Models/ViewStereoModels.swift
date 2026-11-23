import AppKit
import AVFoundation
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

    var correspondingVideoExportFormat: StereoVideoExportFormat {
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

extension StereoVideoExportFormat {
    var correspondingDisplayMode: StereoDisplayMode? {
        switch self {
        case .stereoviewCard: return .stereoviewCard
        case .sbs: return .sbs
        case .lrrl: return .lrrl
        case .dubois: return .dubois
        case .colorAnaglyph: return .colorAnaglyph
        case .grayAnaglyph: return .grayAnaglyph
        case .polarized: return .polarized
        case .twoD: return .twoD
        case .separateLR, .spatialVideo: return nil
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

/// ステレオ警告・整準失敗時のバッチ書き出しポリシー
enum BatchWarningPolicy: String, CaseIterable, Identifiable {
    case exportAll = "Export All Normally"
    case skipWarnings = "Skip Warnings"
    case convertWarningsTo3D = "Convert Warnings to 2D-3D"
    case onlyConvertWarningsTo3D = "Only Convert Warnings to 2D-3D"

    var id: String { rawValue }
}

/// 単一画像の入力解釈モード（2D自動判定 / 強制ステレオ / 強制2D→3D）
enum StereoInputInterpretation: String, CaseIterable, Identifiable {
    case auto = "Auto (Stereo / 2D)"
    case forceStereo = "Force Stereo (SBS / Card)"
    case force2D = "Force 2D Photo → 3D"

    var id: String { rawValue }
}

/// アプリ全体の作業モード（ステレオ修復 / 2D→3D 専用）
enum ViewStereoWorkspaceMode: String, CaseIterable, Identifiable {
    case stereoRestore = "Stereo Restore"
    case convert2DTo3D = "2D → 3D"

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

/// 片側画像選択 (Left / Right)
public enum StereoSingleEyeSide: String, CaseIterable, Identifiable, Sendable {
    case left = "Left"
    case right = "Right"

    public var id: String { rawValue }
}

/// ステレオ構築モード
public enum StereoReconstructionMode: Equatable, Sendable {
    case trueStereo
    case singleEyeDepth(StereoSingleEyeSide)
    case fullFrame2DDepth

    public var isSingleEyeDepth: Bool {
        switch self {
        case .trueStereo, .fullFrame2DDepth: return false
        case .singleEyeDepth: return true
        }
    }

    public var isDepthSynthesized: Bool {
        switch self {
        case .trueStereo: return false
        case .singleEyeDepth, .fullFrame2DDepth: return true
        }
    }

    public var activeSide: StereoSingleEyeSide? {
        switch self {
        case .trueStereo, .fullFrame2DDepth: return nil
        case .singleEyeDepth(let s): return s
        }
    }
}

/// ステレオペアの3大異常診断サマリー（ユーザー判断支援用）
public struct StereoSalvageAdvisory: Sendable, Equatable {
    public let isMismatchSuspected: Bool          // ① 貼り間違い・別テイク・特徴点不足
    public let mismatchReasonText: String?

    public let isUnilateralDamageSuspected: Bool  // ② 片側の大面積損傷・劣化
    public let damagedSide: StereoSingleEyeSide?  // 損傷が検出された側
    public let leftDefectPercent: Double          // 左画像の推定欠損率 (%)
    public let rightDefectPercent: Double         // 右画像の推定欠損率 (%)
    public let leftSharpnessScore: Double         // 左画像の鮮鋭度スコア (0..100)
    public let rightSharpnessScore: Double        // 右画像の鮮鋭度スコア (0..100)

    public let isExcessiveDisparity: Bool         // ③ ステレオベース過大 (maxDisparityPercent > 6.5%)
    public let disparityPercent: Double

    public var shouldShowSalvagePrompt: Bool {
        isMismatchSuspected || isUnilateralDamageSuspected || isExcessiveDisparity
    }

    public var suggestedSide: StereoSingleEyeSide {
        if let damaged = damagedSide {
            return damaged == .left ? .right : .left
        }
        return leftSharpnessScore >= rightSharpnessScore ? .left : .right
    }
}

/// バッチ処理完了サマリー
struct BatchCompletionSummary: Equatable {
    let succeeded: Int
    let failed: Int
    let warningCount: Int
    let total: Int
    let wasCancelled: Bool
    let isVerifyOnly: Bool
    let outputDirectory: URL
}

/// バッチ処理・ブラウザ対象アイテム
struct StereoBatchItem: Identifiable, Sendable {
    var id: String { leftURL.path + (rightURL?.path ?? "") }
    let baseName: String
    let displayLabel: String
    let leftURL: URL
    let rightURL: URL? // nil の場合は SBS 単体画像または動画

    var isVideo: Bool {
        rightURL == nil && WorkspaceScanner.supportedVideoExtensions.contains(leftURL.pathExtension.lowercased())
    }
}

/// アプリ設定（UI大文字モード・AI深度モデル・メモリ管理等）
final class ViewStereoSettings: ObservableObject {
    static let shared = ViewStereoSettings()

    @Published var autoSwapPseudoscopic: Bool = UserDefaults.standard.object(forKey: "VS.autoSwapPseudoscopic") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoSwapPseudoscopic, forKey: "VS.autoSwapPseudoscopic")
        }
    }

    @Published var useLargeTextMode: Bool = false {
        didSet {
            StudioAccessibilityState.shared.useLargeTextMode = useLargeTextMode
        }
    }

    @Published var depthModelEngineRaw: Int {
        didSet {
            UserDefaults.standard.set(depthModelEngineRaw, forKey: "VS.depthModelEngine")
        }
    }

    var preferredDepthEngine: StudioDepthEngine {
        get { StudioDepthEngine(rawValue: depthModelEngineRaw) ?? .depthAnythingV2Small }
        set { depthModelEngineRaw = newValue.rawValue }
    }

    @Published var releaseAIModelsAfterGeneration: Bool = UserDefaults.standard.object(forKey: "VS.releaseAIModelsAfterGeneration") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(releaseAIModelsAfterGeneration, forKey: "VS.releaseAIModelsAfterGeneration")
        }
    }

    @Published var startupFolderActionRaw: String = UserDefaults.standard.string(forKey: "VS.startupFolderAction") ?? StartupFolderAction.showSheet.rawValue {
        didSet {
            UserDefaults.standard.set(startupFolderActionRaw, forKey: "VS.startupFolderAction")
        }
    }

    var startupFolderAction: StartupFolderAction {
        get { StartupFolderAction(rawValue: startupFolderActionRaw) ?? .showSheet }
        set { startupFolderActionRaw = newValue.rawValue }
    }

    @Published var keepRecipeAcrossImages: Bool = UserDefaults.standard.object(forKey: "VS.keepRecipeAcrossImages") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(keepRecipeAcrossImages, forKey: "VS.keepRecipeAcrossImages")
        }
    }

    @Published var lastWorkspaceFolderPath: String? = UserDefaults.standard.string(forKey: "VS.lastWorkspaceFolderPath") {
        didSet {
            UserDefaults.standard.set(lastWorkspaceFolderPath, forKey: "VS.lastWorkspaceFolderPath")
        }
    }

    @Published var recentWorkspaceFolderPaths: [String] = UserDefaults.standard.stringArray(forKey: "VS.recentWorkspaceFolderPaths") ?? [] {
        didSet {
            UserDefaults.standard.set(recentWorkspaceFolderPaths, forKey: "VS.recentWorkspaceFolderPaths")
        }
    }

    func recordWorkspaceFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        lastWorkspaceFolderPath = path
        var list = recentWorkspaceFolderPaths.filter { $0 != path }
        list.insert(path, at: 0)
        if list.count > 8 {
            list = Array(list.prefix(8))
        }
        recentWorkspaceFolderPaths = list
    }

    private init() {
        if let saved = UserDefaults.standard.object(forKey: "VS.depthModelEngine") as? Int,
           StudioDepthEngine(rawValue: saved) != nil {
            self.depthModelEngineRaw = saved
        } else {
            // 初回起動時はシリーズ他アプリに既に導入済みの高精度エンジンがあれば優先選択する
            let priorityOrder: [StudioDepthEngine] = [
                .depthPro2Large, .depthPro2Base, .moge2ViTL, .depthPro,
                .depthAnythingV3Mono, .depthAnythingV2Large, .moge2ViTB,
                .depthPro2Small, .depthAnythingV2Small
            ]
            let detected = priorityOrder.first { $0.isInstalled(preferredAppFolder: "ViewStereo") }
            self.depthModelEngineRaw = (detected ?? .depthAnythingV2Small).rawValue
        }
    }
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
    @Published var isShowingFileBrowser: Bool = UserDefaults.standard.object(forKey: "VS.isShowingFileBrowser") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isShowingFileBrowser, forKey: "VS.isShowingFileBrowser")
        }
    }
    @Published var fileBrowserWidth: CGFloat = 260

    /// 左ファイルブラウザ専用ストア（ViewStereoViewModel.objectWillChange を発火させず選択等を独立更新）
    let browserStore = WorkspaceBrowserStore()
    private var currentImageLoadTask: Task<Void, Never>? = nil
    private var imageLoadGeneration: Int = 0

    var browserViewMode: WorkspaceBrowserViewMode {
        get { browserStore.viewMode }
        set { browserStore.viewMode = newValue }
    }
    var browserSearchText: String {
        get { browserStore.searchText }
        set { browserStore.searchText = newValue }
    }
    var browserShowWarningsOnly: Bool {
        get { browserStore.showWarningsOnly }
        set { browserStore.showWarningsOnly = newValue }
    }
    var workspaceRootFolder: URL? {
        browserStore.rootFolder
    }
    var workspaceSelectedNodeIDs: Set<String> {
        get { browserStore.selectedNodeIDs }
        set { browserStore.updateSelection(newValue) }
    }
    var workspaceSelectedBatchCount: Int {
        browserStore.selectedBatchCount
    }
    var workspaceActiveItemID: String? {
        get { browserStore.activeItemID }
        set { browserStore.activeItemID = newValue }
    }
    var workspaceItemStatuses: [String: WorkspaceItemStatus] {
        get { browserStore.itemStatuses }
        set { browserStore.itemStatuses = newValue }
    }

    @Published var hasHandledStartupWorkspacePrompt: Bool = false
    @Published var isShowingStartupFolderSheet: Bool = false

    @Published var workspaceMode: ViewStereoWorkspaceMode = {
        if let raw = UserDefaults.standard.string(forKey: "VS.workspaceMode"),
           let mode = ViewStereoWorkspaceMode(rawValue: raw) {
            return mode
        }
        return .stereoRestore
    }() {
        didSet {
            guard oldValue != workspaceMode else { return }
            UserDefaults.standard.set(workspaceMode.rawValue, forKey: "VS.workspaceMode")
            browserStore.configureOptions(
                pairingMode: effectiveBrowserPairingMode,
                includeSubfolders: batchIncludeSubfolders,
                outputFolder: batchOutputFolder
            )
            if hasLoadedImages, let url = leftURL, !isProcessing && !isBatchRunning {
                loadSingleSBSImage(url: url, resetRestoration: false)
            }
        }
    }
    @Published var is2D3DSectionExpanded: Bool = true
    @Published var lastDepthEngineLabel: String = ""
    @Published var lastDepthInferenceMs: Double = 0.0

    var effectiveBrowserPairingMode: StereoBatchPairingMode {
        workspaceMode == .convert2DTo3D ? .sbsOnly : batchPairingMode
    }

    @Published var isShowingInspector: Bool = true
    @Published var isRecipeSectionExpanded: Bool = true
    @Published var isWindowSectionExpanded: Bool = false
    @Published var isCardMountSectionExpanded: Bool = false
    @Published var isRestorationSectionExpanded: Bool = false
    @Published var isColorizationSectionExpanded: Bool = false
    @Published var isBatchSectionExpanded: Bool = false
    @Published var isSwapped: Bool = false {
        didSet {
            if oldValue != isSwapped {
                renderDisplayPreview()
            }
        }
    }
    @Published var isPseudoscopicSuspected: Bool = false
    @Published var isStereoMismatchSuspected: Bool = false
    @Published var stereoQualityWarning: String? = nil
    @Published var stereoReportText: String = "Normal"
    @Published var salvageAdvisory: StereoSalvageAdvisory? = nil
    @Published var stereoReconstructionMode: StereoReconstructionMode = .trueStereo
    @Published var virtualDepthBasePercent: Double = 3.0 {
        didSet {
            if stereoReconstructionMode.isDepthSynthesized, oldValue != virtualDepthBasePercent {
                reapplyDepthSynthesis()
            }
        }
    }
    @Published var depthGamma: Double = 1.0 {
        didSet {
            if stereoReconstructionMode.isDepthSynthesized, oldValue != depthGamma {
                reapplyDepthSynthesis()
            }
        }
    }

    // MARK: - 動画 2D→3D 変換状態
    @Published var isVideoLoaded: Bool = false
    @Published var currentVideoURL: URL? = nil
    @Published var videoMetadata: VideoClipMetadata? = nil
    @Published var videoCurrentTimeSeconds: Double = 0.0
    @Published var isVideoPlaying: Bool = false
    @Published var videoExportFormat: StereoVideoExportFormat = .spatialVideo {
        didSet {
            UserDefaults.standard.set(videoExportFormat.rawValue, forKey: "VS.videoExportFormat")
            if !isSyncingLayoutAndMode, let mode = videoExportFormat.correspondingDisplayMode {
                isSyncingLayoutAndMode = true
                if displayMode != mode {
                    displayMode = mode
                }
                if let layout = mode.correspondingExportLayout, exportLayout != layout {
                    exportLayout = layout
                }
                isSyncingLayoutAndMode = false
            }
        }
    }
    @Published var videoTemporalSmoothing: Double = UserDefaults.standard.object(forKey: "VS.videoTemporalSmoothing") as? Double ?? 0.85 {
        didSet { UserDefaults.standard.set(videoTemporalSmoothing, forKey: "VS.videoTemporalSmoothing") }
    }
    @Published var videoLockDepthRange: Bool = false
    @Published var videoAutoCutDetection: Bool = true
    @Published var videoInputStereoSource: VideoInputStereoSource = .full2D
    @Published var videoPreserveHDR: Bool = true
    @Published var isExportingVideo: Bool = false
    @Published var videoExportProgress: Double = 0.0
    @Published var videoExportStatusText: String = ""
    @Published var videoActiveEngineLabel: String = ""
    private var videoPreviewSession: ViewStereoVideoDepthSession? = nil
    private var videoFrameTask: Task<Void, Never>? = nil
    private var videoPlaybackTask: Task<Void, Never>? = nil
    private var videoExportTask: Task<Void, Never>? = nil
    private var videoPreviewGeneration: Int = 0
    private var isVideoFrameInferring: Bool = false

    // バックアップ用（元ペアに戻せるように保存）
    private var originalTrueStereoAlignedL: [UInt8]? = nil
    private var originalTrueStereoAlignedR: [UInt8]? = nil
    private var originalTrueStereoCW: Int = 0
    private var originalTrueStereoCH: Int = 0
    private var originalTrueStereoPrevWarpedL: [UInt8]? = nil
    private var originalTrueStereoPrevWarpedR: [UInt8]? = nil
    private var originalTrueStereoPrevCW: Int = 0
    private var originalTrueStereoPrevCH: Int = 0
    private var originalTrueStereoWindowShiftX: Double = 0.0
    private var originalTrueStereoMaxDisparityPercent: Double = 0.0
    private var cachedBaseSideRGB: [UInt8]? = nil
    private var cachedBaseW: Int = 0
    private var cachedBaseH: Int = 0
    private var cachedDisparityMap: [Float]? = nil
    private var cachedDepthW: Int = 0
    private var cachedDepthH: Int = 0
    private var cachedSynthFullLeftRGB: [UInt8]? = nil
    private var cachedSynthFullRightRGB: [UInt8]? = nil
    private var isSyncingLayoutAndMode = false
    @Published var displayMode: StereoDisplayMode = .stereoviewCard {
        didSet {
            if !isSyncingLayoutAndMode {
                isSyncingLayoutAndMode = true
                if let layout = displayMode.correspondingExportLayout, exportLayout != layout {
                    exportLayout = layout
                }
                let vfmt = displayMode.correspondingVideoExportFormat
                if videoExportFormat != vfmt {
                    videoExportFormat = vfmt
                }
                isSyncingLayoutAndMode = false
            }
            renderDisplayPreview()
        }
    }

    // ステレオカード（台紙）再構築・書き出し設定
    @Published var cardMountPreset: StereoCardMountPreset = .autoSampleColor {
        didSet {
            UserDefaults.standard.set(cardMountPreset.rawValue, forKey: "VS.cardMountPreset")
        }
    }
    @Published var cardSizeSpec: StereoCardSizeSpec = .standard {
        didSet {
            UserDefaults.standard.set(cardSizeSpec.rawValue, forKey: "VS.cardSizeSpec")
        }
    }
    @Published var cardPrintCutStyle: StereoCardPrintCutStyle = .autoFromPreset {
        didSet {
            UserDefaults.standard.set(cardPrintCutStyle.rawValue, forKey: "VS.cardPrintCutStyle")
        }
    }
    @Published var cardCenterGapStyle: StereoCardCenterGapStyle = .autoFromPreset {
        didSet {
            UserDefaults.standard.set(cardCenterGapStyle.rawValue, forKey: "VS.cardCenterGapStyle")
        }
    }
    @Published var cardTextMode: StereoCardTextMode = .ocrAuto {
        didSet {
            UserDefaults.standard.set(cardTextMode.rawValue, forKey: "VS.cardTextMode")
            if cardTextMode == .ocrAuto, oldValue != .ocrAuto, currentMountContext != nil {
                extractTextsFromOriginalCardMount()
            }
        }
    }
    @Published var cardBottomCaption: String = ""
    @Published var cardTopCenterText: String = ""
    @Published var cardLeftMarginText: String = ""
    @Published var cardRightMarginText: String = ""
    @Published var cardUseFilenameAsCaption: Bool = false {
        didSet {
            UserDefaults.standard.set(cardUseFilenameAsCaption, forKey: "VS.cardUseFilenameAsCaption")
        }
    }
    @Published var isRunningCardOCR: Bool = false
    @Published var currentMountContext: StereoCardSegmenter.OriginalCardMountContext? = nil
    private var ocrGeneration: Int = 0

    @Published private(set) var appliedCardMountConfig: StereoCardMountConfig = StereoCardMountConfig()

    var hasPendingCardMountChanges: Bool {
        guard hasLoadedImages else { return false }
        return makeCardMountConfig() != appliedCardMountConfig
    }

    func applyCardMountConfig() {
        appliedCardMountConfig = makeCardMountConfig()
        renderDisplayPreview()
        statusMessage = "Applied stereoview card mount settings."
    }

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
            appliedCardMountConfig = makeCardMountConfig()
            renderDisplayPreview()
        }
    }

    /// 自動処理基本レシピの設定一式
    struct StereoRecipeConfig: Equatable, Sendable {
        var stereoCardMode: StereoCardMode = .cropInner
        var useCoreMLCardSegmentation: Bool = true
        var frameStyle: StereoFrameStyle = .off
        var autoAlignOnLoad: Bool = true
        var autoColorMode: StereoAutoColorMode = .left
        var keepOriginalAspectRatio: Bool = false
        var usePersonMotionMask: Bool = true
        var useAttentionSaliency: Bool = true
        var removeUnilateralNoise: Bool = true
    }

    // 位置合わせ・基本設定（手動適用 & 永続化）
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
        }
    }
    @Published var stereoCardMode: StereoCardMode = .cropInner {
        didSet {
            UserDefaults.standard.set(stereoCardMode.rawValue, forKey: "VS.stereoCardMode")
        }
    }
    @Published var useCoreMLCardSegmentation: Bool = true {
        didSet {
            UserDefaults.standard.set(useCoreMLCardSegmentation, forKey: "VS.useCoreMLCardSegmentation")
        }
    }
    @Published var frameStyle: StereoFrameStyle = .off {
        didSet {
            UserDefaults.standard.set(frameStyle.rawValue, forKey: "VS.frameStyle")
        }
    }

    @Published private(set) var appliedRecipeConfig: StereoRecipeConfig = StereoRecipeConfig()

    var currentRecipeConfig: StereoRecipeConfig {
        StereoRecipeConfig(
            stereoCardMode: stereoCardMode,
            useCoreMLCardSegmentation: useCoreMLCardSegmentation,
            frameStyle: frameStyle,
            autoAlignOnLoad: autoAlignOnLoad,
            autoColorMode: autoColorMode,
            keepOriginalAspectRatio: keepOriginalAspectRatio,
            usePersonMotionMask: usePersonMotionMask,
            useAttentionSaliency: useAttentionSaliency,
            removeUnilateralNoise: removeUnilateralNoise
        )
    }

    var hasPendingRecipeChanges: Bool {
        guard hasLoadedImages else { return false }
        return currentRecipeConfig != appliedRecipeConfig
    }

    func applyRecipeAndRealign() {
        guard hasLoadedImages, !isProcessing else { return }
        let prev = appliedRecipeConfig
        let next = currentRecipeConfig
        appliedRecipeConfig = next

        if isSingleSBSInput && (prev.stereoCardMode != next.stereoCardMode || prev.useCoreMLCardSegmentation != next.useCoreMLCardSegmentation) {
            reloadCurrentSBSIfNeeded()
        } else if prev.frameStyle != next.frameStyle && prev.autoAlignOnLoad == next.autoAlignOnLoad && prev.keepOriginalAspectRatio == next.keepOriginalAspectRatio && prev.usePersonMotionMask == next.usePersonMotionMask && prev.autoColorMode == next.autoColorMode && prev.removeUnilateralNoise == next.removeUnilateralNoise {
            renderDisplayPreview()
        } else {
            runAutoAlignment()
        }
        statusMessage = "Applied basic recipe & realigned stereo pair."
    }

    // 19世紀古写真・退色＆階調復元設定（画像ごとにリセットされる非破壊ポストプロセス）
    @Published var isRestorationEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isRestorationEnabled, forKey: "VS.isRestorationEnabled")
            if oldValue != isRestorationEnabled && !isApplyingRestorationBatch {
                applyUnilateralNoiseToggle()
                renderDisplayPreview()
            }
        }
    }
    var effectiveRemoveUnilateralNoise: Bool {
        isRestorationEnabled && removeUnilateralNoise
    }
    private var isApplyingRestorationBatch: Bool = false
    @Published var restorationPrintTone: VintagePrintTone = .original
    @Published var restorationAutoLevel: Double = 0.0
    @Published var restorationLocalContrast: Double = 0.0
    @Published var restorationDeblurStrength: Double = 0.0
    @Published var restorationTextureProtection: Double = 60.0
    @Published var restorationColorizationMode: StereoColorizationMode = .off
    @Published var restorationColorStrength: Double = 20.0
    @Published var restorationPaperWarmth: Double = 30.0

    @Published private(set) var appliedRestorationOptions: VintageRestorationOptions = VintageRestorationOptions()
    @Published private(set) var appliedDetailOptions: StereoDetailRestorationOptions = StereoDetailRestorationOptions(deblurStrength: 0.0, textureProtection: 0.60)
    @Published private(set) var appliedColorizationOptions: StereoColorizationOptions = StereoColorizationOptions()

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

    var isCoreMLColorizerAvailable: Bool {
        Self.resolveColorizerModelURL() != nil
    }

    var hasActiveColorization: Bool {
        !appliedColorizationOptions.isIdentity
    }

    var hasActiveVintageRestoration: Bool {
        let restorationActive = isRestorationEnabled && (
            !appliedRestorationOptions.isIdentity
            || !appliedDetailOptions.isIdentity
        )
        return restorationActive || hasActiveColorization
    }

    private func buildPendingVintageRestorationOptions() -> VintageRestorationOptions {
        VintageRestorationOptions(
            autoLevelStrength: min(1.0, max(0.0, restorationAutoLevel / 100.0)),
            localContrastStrength: min(1.0, max(0.0, restorationLocalContrast / 100.0)),
            printTone: restorationPrintTone
        )
    }

    private func buildPendingDetailRestorationOptions() -> StereoDetailRestorationOptions {
        StereoDetailRestorationOptions(
            deblurStrength: min(1.0, max(0.0, restorationDeblurStrength / 100.0)),
            textureProtection: min(1.0, max(0.0, restorationTextureProtection / 100.0))
        )
    }

    private func buildPendingColorizationOptions() -> StereoColorizationOptions {
        StereoColorizationOptions(
            mode: restorationColorizationMode,
            colorStrength: min(1.0, max(0.0, restorationColorStrength / 100.0)),
            paperWarmth: min(1.0, max(0.0, restorationPaperWarmth / 100.0))
        )
    }

    var hasPendingRestorationChanges: Bool {
        guard hasLoadedImages else { return false }
        let pendingRest = buildPendingVintageRestorationOptions()
        let pendingDetail = buildPendingDetailRestorationOptions()
        return abs(pendingRest.autoLevelStrength - appliedRestorationOptions.autoLevelStrength) > 0.001
            || abs(pendingRest.localContrastStrength - appliedRestorationOptions.localContrastStrength) > 0.001
            || pendingRest.printTone != appliedRestorationOptions.printTone
            || abs(pendingDetail.deblurStrength - appliedDetailOptions.deblurStrength) > 0.001
            || abs(pendingDetail.textureProtection - appliedDetailOptions.textureProtection) > 0.001
    }

    var hasPendingColorizationChanges: Bool {
        guard hasLoadedImages else { return false }
        let pending = buildPendingColorizationOptions()
        return pending.mode != appliedColorizationOptions.mode
            || abs(pending.colorStrength - appliedColorizationOptions.colorStrength) > 0.001
            || abs(pending.paperWarmth - appliedColorizationOptions.paperWarmth) > 0.001
    }

    func makeVintageRestorationOptions(ignorePreviewToggle: Bool = false) -> VintageRestorationOptions {
        if !isRestorationEnabled || (!ignorePreviewToggle && isShowingBeforeRestoration) {
            return VintageRestorationOptions()
        }
        return appliedRestorationOptions
    }

    func makeDetailRestorationOptions(ignorePreviewToggle: Bool = false) -> StereoDetailRestorationOptions {
        if !isRestorationEnabled || (!ignorePreviewToggle && isShowingBeforeRestoration) {
            return StereoDetailRestorationOptions(deblurStrength: 0.0, textureProtection: appliedDetailOptions.textureProtection)
        }
        return appliedDetailOptions
    }

    func makeColorizationOptions(ignorePreviewToggle: Bool = false) -> StereoColorizationOptions {
        if !ignorePreviewToggle && isShowingBeforeRestoration {
            return StereoColorizationOptions()
        }
        return appliedColorizationOptions
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

    nonisolated private static func resolveColorizerModelURL() -> URL? {
        if let u = Bundle.main.url(forResource: "StereoColorizer", withExtension: "mlmodelc") { return u }
        if let u = Bundle.main.url(forResource: "StereoColorizer", withExtension: "mlpackage") { return u }
        #if SWIFT_PACKAGE
        if let u = Bundle.module.url(forResource: "StereoColorizer", withExtension: "mlmodelc") { return u }
        if let u = Bundle.module.url(forResource: "StereoColorizer", withExtension: "mlpackage") { return u }
        #endif
        return nil
    }

    nonisolated static func applyVintagePipeline(
        left: [UInt8],
        right: [UInt8],
        width: Int,
        height: Int,
        toneOptions: VintageRestorationOptions,
        detailOptions: StereoDetailRestorationOptions,
        colorOptions: StereoColorizationOptions = StereoColorizationOptions(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> (left: [UInt8], right: [UInt8]) {
        var curL = left
        var curR = right
        let hasColor = !colorOptions.isIdentity
        let detailWeight = (toneOptions.isIdentity && !hasColor) ? 1.0 : (hasColor ? 0.55 : 0.85)

        if !detailOptions.isIdentity {
            let detailed = StereoDetailRestorer.restorePair(
                leftRGB: curL,
                rightRGB: curR,
                width: width,
                height: height,
                options: detailOptions,
                modelURL: resolveDeblurModelURL(),
                progress: { p in
                    progress?(p * detailWeight)
                }
            )
            curL = detailed.left
            curR = detailed.right
        }
        // カラー化が有効な場合は、先に Auto-Level / CLAHE で輝度階調を正規化し、プリントトーンによる上書きは抑止する
        var effectiveTone = toneOptions
        if hasColor {
            effectiveTone.printTone = .original
        }
        if !effectiveTone.isIdentity {
            let toned = VintageToneRestorer.restorePair(leftRGB: curL, rightRGB: curR, width: width, height: height, options: effectiveTone)
            curL = toned.left
            curR = toned.right
            if !hasColor {
                progress?(1.0)
            }
        }
        if hasColor {
            let baseProg = detailOptions.isIdentity ? 0.15 : 0.60
            let colored = StereoColorizer.colorizePair(
                leftRGB: curL,
                rightRGB: curR,
                width: width,
                height: height,
                options: colorOptions,
                modelURL: resolveColorizerModelURL(),
                progress: { p in
                    progress?(baseProg + p * (1.0 - baseProg))
                }
            )
            curL = colored.left
            curR = colored.right
            progress?(1.0)
        }
        return (curL, curR)
    }

    func applyVintageRestoration() {
        isApplyingRestorationBatch = true
        isRestorationEnabled = true
        isShowingBeforeRestoration = false
        appliedRestorationOptions = buildPendingVintageRestorationOptions()
        appliedDetailOptions = buildPendingDetailRestorationOptions()
        isApplyingRestorationBatch = false
        applyUnilateralNoiseToggle()
        statusMessage = "Applied vintage restoration."
        renderDisplayPreview()
    }

    func applyColorization() {
        isApplyingRestorationBatch = true
        isShowingBeforeRestoration = false
        if restorationColorizationMode == .off && !hasActiveColorization {
            restorationColorizationMode = .handTinted1890s
        }
        appliedColorizationOptions = buildPendingColorizationOptions()
        isApplyingRestorationBatch = false
        statusMessage = restorationColorizationMode == .off ? "Cleared colorization." : "Applied colorization."
        renderDisplayPreview()
    }

    func applyVintage19thCenturyPreset() {
        isApplyingRestorationBatch = true
        restorationPrintTone = .albumenSepia
        restorationAutoLevel = 80.0
        restorationLocalContrast = 45.0
        restorationDeblurStrength = 35.0
        restorationTextureProtection = 65.0
        isApplyingRestorationBatch = false
        statusMessage = "Loaded 1860s Albumen preset. Click Apply Restoration to run."
    }

    func apply1890sHandTintedPreset() {
        isApplyingRestorationBatch = true
        restorationPrintTone = .original
        restorationAutoLevel = 70.0
        restorationLocalContrast = 35.0
        restorationDeblurStrength = 25.0
        restorationTextureProtection = 65.0
        restorationColorizationMode = .handTinted1890s
        restorationColorStrength = 20.0
        restorationPaperWarmth = 30.0
        isApplyingRestorationBatch = false
        statusMessage = "Loaded 1890s Hand-Tinted preset."
    }

    func resetVintageRestoration(renderPreview: Bool = true) {
        isApplyingRestorationBatch = true
        isShowingBeforeRestoration = false
        restorationPrintTone = .original
        restorationAutoLevel = 0.0
        restorationLocalContrast = 0.0
        restorationDeblurStrength = 0.0
        restorationTextureProtection = 60.0
        appliedRestorationOptions = VintageRestorationOptions()
        appliedDetailOptions = StereoDetailRestorationOptions(deblurStrength: 0.0, textureProtection: 0.60)
        isApplyingRestorationBatch = false
        if renderPreview {
            statusMessage = "Reset vintage restoration settings."
            renderDisplayPreview()
        }
    }

    func resetColorization(renderPreview: Bool = true) {
        isApplyingRestorationBatch = true
        restorationColorizationMode = .off
        restorationColorStrength = 20.0
        restorationPaperWarmth = 30.0
        appliedColorizationOptions = StereoColorizationOptions()
        isApplyingRestorationBatch = false
        if renderPreview {
            statusMessage = "Reset colorization settings."
            renderDisplayPreview()
        }
    }

    /// アプリ起動時の初期状態（ランディング画面）へリセットする
    func resetToInitialState() {
        guard !isProcessing && !isBatchRunning && !isExportingVideo else { return }
        clearVideoState()
        previewRenderGeneration += 1

        rawLeftRGB = nil
        rawRightRGB = nil
        alignedLeftRGB = nil
        alignedRightRGB = nil
        previewRawLeftRGB = nil
        previewRawRightRGB = nil
        previewAlignedLeftRGB = nil
        previewAlignedRightRGB = nil
        rectifiedPreviewLeftRGB = nil
        rectifiedPreviewRightRGB = nil

        leftURL = nil
        rightURL = nil
        workspaceActiveItemID = nil
        isSingleSBSInput = false
        hasPreservedArch = false
        currentMountContext = nil
        clearCardMountTexts()
        isRunningCardOCR = false

        imageWidth = 0
        imageHeight = 0
        croppedWidth = 0
        croppedHeight = 0
        previewWidth = 0
        previewHeight = 0
        previewCroppedWidth = 0
        previewCroppedHeight = 0
        rectifiedPreviewWidth = 0
        rectifiedPreviewHeight = 0

        isAligned = false
        processingTimeMs = 0.0
        verticalRMSE = 0.0
        matchCount = 0
        inlierCount = 0
        lastMatches = []
        lastRectResult = nil
        lastCommonPolygon = []
        lastDisparitySamples = []
        lastRawSaliencyMap = nil

        windowShiftX = 0.0
        autoOptimalShiftX = 0.0
        hasWindowViolationRisk = false
        requiresFloatingWindow = false
        maxDisparityPercent = 0.0
        lastFullResShiftX = 0.0
        isPseudoscopicSuspected = false
        isStereoMismatchSuspected = false
        stereoQualityWarning = nil
        stereoReportText = "Normal"
        salvageAdvisory = nil
        stereoReconstructionMode = .trueStereo
        originalTrueStereoAlignedL = nil
        originalTrueStereoAlignedR = nil
        cachedDisparityMap = nil
        cachedSynthFullLeftRGB = nil
        cachedSynthFullRightRGB = nil

        isSwapped = false
        resetVintageRestoration(renderPreview: false)
        resetColorization(renderPreview: false)

        batchCompletionSummary = nil
        batchProgress = 0.0
        batchTotalCount = 0
        batchCompletedCount = 0
        batchFailedCount = 0
        batchCurrentFile = ""
        batchQueueItems = []
        isBatchQueueActive = false

        isRestoringPreview = false
        restorationProgress = 0.0
        restorationProgressMessage = ""
        statusMessage = ""
        displayImage = nil
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
            if !isSyncingLayoutAndMode, let mode = exportLayout.correspondingDisplayMode {
                isSyncingLayoutAndMode = true
                if displayMode != mode {
                    displayMode = mode
                }
                let vfmt = mode.correspondingVideoExportFormat
                if videoExportFormat != vfmt {
                    videoExportFormat = vfmt
                }
                isSyncingLayoutAndMode = false
            }
        }
    }
    @Published var exportImageFormat: StereoExportImageFormat = .jpeg {
        didSet { UserDefaults.standard.set(exportImageFormat.rawValue, forKey: "VS.exportImageFormat") }
    }

    // バッチ処理状態
    @Published var batchInputFolder: URL? = nil
    @Published var batchOutputFolder: URL? = nil {
        didSet {
            browserStore.configureOptions(
                pairingMode: effectiveBrowserPairingMode,
                includeSubfolders: batchIncludeSubfolders,
                outputFolder: batchOutputFolder
            )
        }
    }
    @Published var batchPairingMode: StereoBatchPairingMode = .auto {
        didSet {
            UserDefaults.standard.set(batchPairingMode.rawValue, forKey: "VS.batchPairingMode")
            browserStore.configureOptions(
                pairingMode: effectiveBrowserPairingMode,
                includeSubfolders: batchIncludeSubfolders,
                outputFolder: batchOutputFolder
            )
            if isBatchQueueActive, let dir = batchInputFolder {
                batchQueueItems = Self.discoverBatchItems(in: dir, mode: batchPairingMode)
            }
        }
    }
    @Published var batchIncludeSubfolders: Bool = UserDefaults.standard.object(forKey: "VS.batchIncludeSubfolders") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(batchIncludeSubfolders, forKey: "VS.batchIncludeSubfolders")
            browserStore.configureOptions(
                pairingMode: effectiveBrowserPairingMode,
                includeSubfolders: batchIncludeSubfolders,
                outputFolder: batchOutputFolder
            )
        }
    }
    @Published var batchWarningPolicy: BatchWarningPolicy = {
        if let raw = UserDefaults.standard.string(forKey: "VS.batchWarningPolicy"),
           let p = BatchWarningPolicy(rawValue: raw) {
            return p
        }
        return .exportAll
    }() {
        didSet {
            UserDefaults.standard.set(batchWarningPolicy.rawValue, forKey: "VS.batchWarningPolicy")
        }
    }
    @Published var inputInterpretation: StereoInputInterpretation = {
        if let raw = UserDefaults.standard.string(forKey: "VS.inputInterpretation"),
           let mode = StereoInputInterpretation(rawValue: raw) {
            return mode
        }
        return .auto
    }() {
        didSet {
            UserDefaults.standard.set(inputInterpretation.rawValue, forKey: "VS.inputInterpretation")
        }
    }
    @Published var batchSaveReport: Bool = UserDefaults.standard.object(forKey: "VS.batchSaveReport") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(batchSaveReport, forKey: "VS.batchSaveReport")
        }
    }
    @Published var isBatchRunning: Bool = false
    @Published var isBatchVerifyOnly: Bool = false
    @Published var batchProgress: Double = 0.0
    @Published var batchTotalCount: Int = 0
    @Published var batchCompletedCount: Int = 0
    @Published var batchFailedCount: Int = 0
    @Published var verifyWarningCount: Int = 0
    @Published var batchCurrentFile: String = ""
    @Published var batchCompletionSummary: BatchCompletionSummary? = nil
    @Published var batchQueueItems: [StereoBatchItem] = []
    @Published var isBatchQueueActive: Bool = false
    private var batchTask: Task<Void, Never>? = nil

    func prepareBatchQueue(folder: URL) {
        batchInputFolder = folder
        batchOutputFolder = folder.appendingPathComponent("ViewStereo_Output", isDirectory: true)
        batchQueueItems = Self.discoverBatchItems(in: folder, mode: batchPairingMode)
        isBatchQueueActive = true
        batchCompletionSummary = nil
        isBatchSectionExpanded = true
        statusMessage = "Batch queue: \(batchQueueItems.count) image(s) found in \(folder.lastPathComponent)."
    }

    func dismissBatchQueue() {
        isBatchQueueActive = false
    }

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
        if ud.object(forKey: "VS.isRestorationEnabled") != nil {
            self.isRestorationEnabled = ud.bool(forKey: "VS.isRestorationEnabled")
        }
        if let cm = ud.string(forKey: "VS.stereoCardMode"), let cardMode = StereoCardMode(rawValue: cm) {
            self.stereoCardMode = cardMode
        }
        if ud.object(forKey: "VS.useCoreMLCardSegmentation") != nil {
            self.useCoreMLCardSegmentation = ud.bool(forKey: "VS.useCoreMLCardSegmentation")
        }
        if let fs = ud.string(forKey: "VS.frameStyle"), let style = StereoFrameStyle(rawValue: fs) {
            self.frameStyle = style
        }
        self.isSyncingLayoutAndMode = true
        if let el = ud.string(forKey: "VS.exportLayout"), let layout = StereoExportLayout(rawValue: el) {
            self.exportLayout = layout
            if let mode = layout.correspondingDisplayMode {
                self.displayMode = mode
            }
        } else if let legacy = ud.string(forKey: "VS.exportFormat") {
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
        }
        if let vfmt = ud.string(forKey: "VS.videoExportFormat"), let fmt = StereoVideoExportFormat(rawValue: vfmt), fmt.correspondingDisplayMode == nil {
            self.videoExportFormat = fmt
        } else {
            self.videoExportFormat = self.displayMode.correspondingVideoExportFormat
        }
        self.isSyncingLayoutAndMode = false
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
        if let bpm = ud.string(forKey: "VS.batchPairingMode"), let mode = StereoBatchPairingMode(rawValue: bpm) {
            self.batchPairingMode = mode
        }
        browserStore.configureOptions(
            pairingMode: effectiveBrowserPairingMode,
            includeSubfolders: batchIncludeSubfolders,
            outputFolder: batchOutputFolder
        )
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

    var currentDisplayTitle: String {
        if let l = leftURL {
            let leftStem = l.deletingPathExtension().lastPathComponent
            if let r = rightURL, r != l {
                let rightStem = r.deletingPathExtension().lastPathComponent
                return "\(leftStem) + \(rightStem)"
            }
            return leftStem
        }
        return String(localized: "New Stereoview")
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
        var types: [UTType] = [.jpeg, .png, .tiff, .bmp, .heic, .webP, .rawImage, .mpeg4Movie, .quickTimeMovie, .movie]
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

    private func isTemporaryLocation(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        return p.hasPrefix("/var/folders/") || p.hasPrefix("/private/var/folders/") || p.hasPrefix(tmp)
    }

    @discardableResult
    func promptOutputFolderForSelection() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Select Output Folder")
        panel.message = String(localized: "Choose a destination folder for processed images.")
        if let existing = batchOutputFolder, !isTemporaryLocation(existing),
           FileManager.default.fileExists(atPath: existing.path) {
            panel.directoryURL = existing
        } else if let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
            panel.directoryURL = pics
        }
        if panel.runModal() == .OK, let dir = panel.url {
            batchOutputFolder = dir
            return dir
        }
        return nil
    }

    func setVirtualWorkspaceSelection(urls: [URL]) {
        batchInputFolder = nil
        if let out = batchOutputFolder, isTemporaryLocation(out) {
            batchOutputFolder = nil
        }
        // 写真アプリ等からの複数選択時は、出力先ダイアログで出力先を指定させる
        if batchOutputFolder == nil {
            _ = promptOutputFolderForSelection()
        }
        browserStore.setVirtualSelection(
            urls: urls,
            pairingMode: effectiveBrowserPairingMode,
            outputFolder: batchOutputFolder,
            includeSubfolders: batchIncludeSubfolders
        )
        isShowingFileBrowser = true
        statusMessage = browserStore.displayTitle ?? "Selected Photos"
        if let firstItem = browserStore.rootNodes().compactMap(\.item).first {
            openBrowserItem(firstItem)
        }
    }

    func handleDroppedURLs(_ urls: [URL]) {
        hasHandledStartupWorkspacePrompt = true
        if let dir = urls.first(where: { $0.hasDirectoryPath }) {
            setWorkspaceRootFolder(dir)
            isShowingFileBrowser = true
            return
        }
        if let videoURL = urls.first(where: { WorkspaceScanner.supportedVideoExtensions.contains($0.pathExtension.lowercased()) }),
           urls.count == 1 {
            if workspaceRootFolder == nil && !isTemporaryLocation(videoURL) {
                setWorkspaceRootFolder(videoURL.deletingLastPathComponent())
                isShowingFileBrowser = true
            } else if isTemporaryLocation(videoURL), let out = batchOutputFolder, isTemporaryLocation(out) {
                batchOutputFolder = nil
            }
            loadVideo(url: videoURL)
            return
        }
        let filtered = urls.filter { Self.supportedImageExtensions.contains($0.pathExtension.lowercased()) }
        if filtered.count >= 3 || (workspaceMode == .convert2DTo3D && filtered.count >= 2) {
            setVirtualWorkspaceSelection(urls: filtered)
        } else if filtered.count >= 2 {
            if workspaceRootFolder == nil && !isTemporaryLocation(filtered[0]) {
                setWorkspaceRootFolder(filtered[0].deletingLastPathComponent())
                isShowingFileBrowser = true
            } else if isTemporaryLocation(filtered[0]), let out = batchOutputFolder, isTemporaryLocation(out) {
                batchOutputFolder = nil
            }
            loadSeparateImages(left: filtered[0], right: filtered[1])
        } else if let single = filtered.first {
            if workspaceRootFolder == nil && !isTemporaryLocation(single) {
                setWorkspaceRootFolder(single.deletingLastPathComponent())
                isShowingFileBrowser = true
            } else if isTemporaryLocation(single), let out = batchOutputFolder, isTemporaryLocation(out) {
                batchOutputFolder = nil
            }
            loadSingleSBSImage(url: single)
        }
    }

    func reloadCurrentSBSIfNeeded() {
        guard !isProcessing, isSingleSBSInput, let url = leftURL else { return }
        loadSingleSBSImage(url: url, resetRestoration: false)
    }

    func loadSingleSBSImage(
        url: URL,
        resetRestoration: Bool = true,
        interpretationOverride: StereoInputInterpretation? = nil
    ) {
        currentImageLoadTask?.cancel()
        clearVideoState()
        imageLoadGeneration += 1
        let gen = imageLoadGeneration

        if let prevID = workspaceActiveItemID,
           prevID != url.path,
           workspaceItemStatuses[prevID] == .processing {
            workspaceItemStatuses[prevID] = .idle
        }

        isBatchQueueActive = false
        batchCompletionSummary = nil
        if resetRestoration && !ViewStereoSettings.shared.keepRecipeAcrossImages {
            resetVintageRestoration(renderPreview: false)
            resetColorization(renderPreview: false)
        }
        if cardTextMode != .manualTypeset {
            clearCardMountTexts()
        }
        workspaceActiveItemID = url.path
        workspaceItemStatuses[url.path] = .processing
        leftURL = url
        rightURL = url
        isSingleSBSInput = true
        isProcessing = true
        let cardMode = stereoCardMode
        let useCoreML = useCoreMLCardSegmentation
        let interp = interpretationOverride ?? (workspaceMode == .convert2DTo3D ? .force2D : inputInterpretation)
        statusMessage = "Loading image..."

        currentImageLoadTask = Task {
            struct LoadedSingleResult: Sendable {
                let left: [UInt8]
                let right: [UInt8]
                let width: Int
                let height: Int
                let prevL: [UInt8]
                let prevR: [UInt8]
                let prevW: Int
                let prevH: Int
                let isContainerStereo: Bool
                let preservedArch: Bool
                let mountCtx: StereoCardSegmenter.OriginalCardMountContext?
                let is2DPhoto: Bool
            }

            let loaded = await Task.detached(priority: .userInitiated) { () -> LoadedSingleResult? in
                if Task.isCancelled { return nil }
                // 1. MPO / Apple 空間写真 HEIC のマルチフレームステレオコンテナを優先判定
                if interp != .force2D, let (lPair, rPair, pw0, ph0) = Self.loadStereoPairFromContainer(url: url) {
                    if Task.isCancelled { return nil }
                    let (pL, pw, ph) = Self.downsampleForPreview(lPair, width: pw0, height: ph0, maxDim: Self.previewMaxDimension)
                    let (pR, _, _) = Self.downsampleForPreview(rPair, width: pw0, height: ph0, maxDim: Self.previewMaxDimension)
                    return LoadedSingleResult(
                        left: lPair, right: rPair, width: pw0, height: ph0,
                        prevL: pL, prevR: pR, prevW: pw, prevH: ph,
                        isContainerStereo: true, preservedArch: false, mountCtx: nil, is2DPhoto: false
                    )
                }

                // 2. 通常の単一画像（2D写真判定 / ステレオカード処理 / SBS分割）
                guard let (rgb, fw, fh) = Self.loadNormalizedRGB(url: url), fw >= 64 else {
                    return nil
                }
                if Task.isCancelled { return nil }

                // 強制 2D モード
                if interp == .force2D {
                    let (p2D, pw, ph) = Self.downsampleForPreview(rgb, width: fw, height: fh, maxDim: Self.previewMaxDimension)
                    return LoadedSingleResult(
                        left: rgb, right: rgb, width: fw, height: fh,
                        prevL: p2D, prevR: p2D, prevW: pw, prevH: ph,
                        isContainerStereo: false, preservedArch: false, mountCtx: nil, is2DPhoto: true
                    )
                }

                // ステレオカード台紙検出
                let extMode: StereoCardCropper.ExtractionMode = (cardMode == .keepArchBlack) ? .keepArchBlack : .cropInner
                if cardMode != .off,
                   let card = (useCoreML ? StereoCardSegmenter.shared.extractPhotoPair(from: rgb, width: fw, height: fh, mode: extMode) : nil)
                           ?? StereoCardCropper.extractPhotoPair(from: rgb, width: fw, height: fh, mode: extMode) {
                    if Task.isCancelled { return nil }
                    let (pL, pw, ph) = Self.downsampleForPreview(card.leftRGB, width: card.width, height: card.height, maxDim: Self.previewMaxDimension)
                    let (pR, _, _) = Self.downsampleForPreview(card.rightRGB, width: card.width, height: card.height, maxDim: Self.previewMaxDimension)
                    let mountCtx = StereoCardSegmenter.shared.currentMountContext
                    return LoadedSingleResult(
                        left: card.leftRGB, right: card.rightRGB, width: card.width, height: card.height,
                        prevL: pL, prevR: pR, prevW: pw, prevH: ph,
                        isContainerStereo: false, preservedArch: card.preservedArch, mountCtx: mountCtx, is2DPhoto: false
                    )
                }

                if Task.isCancelled { return nil }
                // 自動判定モード時は、SBS か通常の 2D 写真かを判定する
                if interp == .auto && Self.detectIs2DPhoto(rgb: rgb, width: fw, height: fh) {
                    let (p2D, pw, ph) = Self.downsampleForPreview(rgb, width: fw, height: fh, maxDim: Self.previewMaxDimension)
                    return LoadedSingleResult(
                        left: rgb, right: rgb, width: fw, height: fh,
                        prevL: p2D, prevR: p2D, prevW: pw, prevH: ph,
                        isContainerStereo: false, preservedArch: false, mountCtx: nil, is2DPhoto: true
                    )
                }

                // SBS 分割
                let w = fw / 2
                let h = fh
                var tmpL = [UInt8](repeating: 0, count: w * fh * 3)
                var tmpR = [UInt8](repeating: 0, count: w * fh * 3)
                for y in 0..<fh {
                    let srcRow = y * fw * 3
                    let dstRow = y * w * 3
                    tmpL[dstRow..<(dstRow + w * 3)] = rgb[srcRow..<(srcRow + w * 3)]
                    tmpR[dstRow..<(dstRow + w * 3)] = rgb[(srcRow + w * 3)..<(srcRow + w * 6)]
                }
                let (pL, pw, ph) = Self.downsampleForPreview(tmpL, width: w, height: h, maxDim: Self.previewMaxDimension)
                let (pR, _, _) = Self.downsampleForPreview(tmpR, width: w, height: h, maxDim: Self.previewMaxDimension)
                return LoadedSingleResult(
                    left: tmpL, right: tmpR, width: w, height: h,
                    prevL: pL, prevR: pR, prevW: pw, prevH: ph,
                    isContainerStereo: false, preservedArch: false, mountCtx: nil, is2DPhoto: false
                )
            }.value

            guard !Task.isCancelled, self.imageLoadGeneration == gen else { return }

            guard let res = loaded else {
                isProcessing = false
                statusMessage = "Failed to load image."
                workspaceItemStatuses[url.path] = .failed("Failed to load image")
                return
            }

            isSingleSBSInput = !res.isContainerStereo && !res.is2DPhoto
            hasPreservedArch = res.preservedArch
            currentMountContext = res.mountCtx
            if cardTextMode == .ocrAuto {
                clearCardMountTexts()
            }
            rawLeftRGB = res.left
            rawRightRGB = res.right
            alignedLeftRGB = nil
            alignedRightRGB = nil
            previewRawLeftRGB = res.prevL
            previewRawRightRGB = res.prevR
            previewAlignedLeftRGB = nil
            previewAlignedRightRGB = nil
            rectifiedPreviewLeftRGB = nil
            rectifiedPreviewRightRGB = nil
            previewWidth = res.prevW
            previewHeight = res.prevH
            previewCroppedWidth = res.prevW
            previewCroppedHeight = res.prevH
            imageWidth = res.width
            imageHeight = res.height
            croppedWidth = res.width
            croppedHeight = res.height
            isAligned = false
            lastMatches = []
            lastRectResult = nil
            lastDisparitySamples = []
            lastRawSaliencyMap = nil
            windowShiftX = 0
            autoOptimalShiftX = 0
            lastFullResShiftX = 0
            salvageAdvisory = nil
            isStereoMismatchSuspected = false
            isPseudoscopicSuspected = false
            stereoQualityWarning = nil
            appliedCardMountConfig = makeCardMountConfig()
            appliedRecipeConfig = currentRecipeConfig

            if res.is2DPhoto {
                statusMessage = "2D photo detected (\(res.width)×\(res.height)). Converting to 3D..."
                convertFullFrame2DToDepth3D(rgb: res.left, width: res.width, height: res.height)
                return
            }

            isProcessing = false
            statusMessage = res.isContainerStereo ? "Loaded Stereo Container (\(res.width)×\(res.height))" : "Loaded SBS (\(res.width)×\(res.height))"
            if cardTextMode == .ocrAuto, res.mountCtx != nil {
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
        currentImageLoadTask?.cancel()
        clearVideoState()
        imageLoadGeneration += 1
        let gen = imageLoadGeneration

        let activeID = left.path + right.path
        if let prevID = workspaceActiveItemID,
           prevID != activeID,
           workspaceItemStatuses[prevID] == .processing {
            workspaceItemStatuses[prevID] = .idle
        }

        batchCompletionSummary = nil
        if !ViewStereoSettings.shared.keepRecipeAcrossImages {
            resetVintageRestoration(renderPreview: false)
            resetColorization(renderPreview: false)
        }
        if cardTextMode != .manualTypeset {
            clearCardMountTexts()
        }
        workspaceActiveItemID = activeID
        workspaceItemStatuses[activeID] = .processing
        leftURL = left
        rightURL = right
        isSingleSBSInput = false
        isProcessing = true
        statusMessage = "Loading L/R images..."

        currentImageLoadTask = Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> ([UInt8], [UInt8], Int, Int, [UInt8], [UInt8], Int, Int)? in
                if Task.isCancelled { return nil }
                guard let (lRGB, lw, lh) = Self.loadNormalizedRGB(url: left),
                      let (rRGBRaw, rw, rh) = Self.loadNormalizedRGB(url: right) else {
                    return nil
                }
                if Task.isCancelled { return nil }
                let rRGB = (lw == rw && lh == rh) ? rRGBRaw : Self.resizeBilinearRGB(rRGBRaw, sw: rw, sh: rh, dw: lw, dh: lh)
                let (pL, pw, ph) = Self.downsampleForPreview(lRGB, width: lw, height: lh, maxDim: Self.previewMaxDimension)
                let (pR, _, _) = Self.downsampleForPreview(rRGB, width: lw, height: lh, maxDim: Self.previewMaxDimension)
                return (lRGB, rRGB, lw, lh, pL, pR, pw, ph)
            }.value

            guard !Task.isCancelled, self.imageLoadGeneration == gen else { return }

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
            appliedCardMountConfig = makeCardMountConfig()
            appliedRecipeConfig = currentRecipeConfig
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
        // 左右入れ替えで視差の符号が反転するため、ウィンドウ最適シフトを再計算してバイオレーションを防ぐ
        if isAligned { recalculateOptimalWindow() }
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
        isPseudoscopicSuspected = false
        isStereoMismatchSuspected = false
        stereoQualityWarning = nil
        stereoReportText = "Normal"
        salvageAdvisory = nil
        stereoReconstructionMode = .trueStereo
        originalTrueStereoAlignedL = nil
        originalTrueStereoAlignedR = nil
        cachedDisparityMap = nil
        cachedSynthFullLeftRGB = nil
        cachedSynthFullRightRGB = nil
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
        let isPseudoscopicSuspected: Bool
        let isStereoMismatchSuspected: Bool
        let stereoQualityWarning: String?
        let stereoReportText: String
        let salvageAdvisory: StereoSalvageAdvisory
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
        let removeNoise = effectiveRemoveUnilateralNoise
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
                let errMsg: String
                switch err {
                case .notEnoughMatches(let count):
                    errMsg = "Not enough feature matches (\(count))."
                case .rectificationFailed:
                    errMsg = "Rectification failed to converge."
                case .projectionFailed:
                    errMsg = "Failed to project bounding corners."
                case .noValidInteriorRect:
                    errMsg = "No valid interior rectangle found."
                case .metalWarpFailed:
                    errMsg = "Metal warp failed."
                }
                statusMessage = errMsg
                if let activeID = workspaceActiveItemID {
                    workspaceItemStatuses[activeID] = .failed(errMsg)
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
        lastFullResRemoveNoise = effectiveRemoveUnilateralNoise
        hasWindowViolationRisk = out.windowDecision.hasWindowViolationRisk
        requiresFloatingWindow = out.windowDecision.requiresFloatingWindow
        maxDisparityPercent = out.dispRangePct
        isPseudoscopicSuspected = out.isPseudoscopicSuspected
        isStereoMismatchSuspected = out.isStereoMismatchSuspected
        stereoQualityWarning = out.stereoQualityWarning
        stereoReportText = out.stereoReportText
        salvageAdvisory = out.salvageAdvisory
        stereoReconstructionMode = .trueStereo
        if out.isPseudoscopicSuspected && ViewStereoSettings.shared.autoSwapPseudoscopic {
            isSwapped = true
        }
        isProcessing = false
        if let warn = out.stereoQualityWarning {
            statusMessage = String(format: "Aligned in %.1f ms | vRMSE: %.3f px  %@", out.elapsedMs, out.rectRes.verticalRMSEPixels, warn)
            if let activeID = workspaceActiveItemID {
                workspaceItemStatuses[activeID] = .warning(warn)
            }
        } else {
            statusMessage = String(format: "Aligned in %.1f ms | vRMSE: %.3f px", out.elapsedMs, out.rectRes.verticalRMSEPixels)
            if let activeID = workspaceActiveItemID {
                workspaceItemStatuses[activeID] = .completed
            }
        }
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

        let isPseudoscopicSuspected = detectPseudoscopicParallax(samples: samples, height: Double(h))

        let winOpts = makeWindowOptimizationOptions(preserveArch: preserveArch)
        // 左右逆を自動スワップする場合、ユーザーが見る視差は符号反転 (-p) になるため、
        // 反転視差でウィンドウ最適化を行い、実ワープ座標系のシフトは符号を戻して適用する
        let willAutoSwap = isPseudoscopicSuspected && (UserDefaults.standard.object(forKey: "VS.autoSwapPseudoscopic") as? Bool ?? true)
        let solveSamples = willAutoSwap
            ? samples.map { DisparitySample(x: $0.x, y: $0.y, parallax: -$0.parallax, saliency: $0.saliency, foregroundWeight: $0.foregroundWeight) }
            : samples
        let solved = Self.resolveWindowDecision(samples: solveSamples, width: Double(w), height: Double(h), preserveArch: preserveArch, options: winOpts)
        let windowDecision = willAutoSwap
            ? StereoWindowDecision(
                optimalShiftX: -solved.optimalShiftX,
                minShiftedParallax: -solved.farShiftedParallax,
                farShiftedParallax: -solved.minShiftedParallax,
                hasWindowViolationRisk: solved.hasWindowViolationRisk,
                requiresFloatingWindow: solved.requiresFloatingWindow
            )
            : solved
        let tx = windowDecision.optimalShiftX

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

        let stereoQuality = evaluateStereoQuality(
            matches: matches,
            samples: samples,
            width: Double(w),
            height: Double(h),
            isPseudoscopic: isPseudoscopicSuspected,
            isSwapped: willAutoSwap
        )

        let damageEval = evaluateUnilateralDamage(
            leftRGB: warpedL,
            rightRGB: warpedR,
            width: cw,
            height: ch
        )

        let isExcessive = dispRangePct > 6.5
        let advisory = StereoSalvageAdvisory(
            isMismatchSuspected: stereoQuality.isMismatch,
            mismatchReasonText: stereoQuality.warningText,
            isUnilateralDamageSuspected: damageEval.isDamaged,
            damagedSide: damageEval.damagedSide,
            leftDefectPercent: damageEval.leftDefect,
            rightDefectPercent: damageEval.rightDefect,
            leftSharpnessScore: damageEval.leftSharp,
            rightSharpnessScore: damageEval.rightSharp,
            isExcessiveDisparity: isExcessive,
            disparityPercent: dispRangePct
        )

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
            dispRangePct: max(0, dispRangePct),
            isPseudoscopicSuspected: isPseudoscopicSuspected,
            isStereoMismatchSuspected: stereoQuality.isMismatch,
            stereoQualityWarning: stereoQuality.warningText,
            stereoReportText: stereoQuality.reportText,
            salvageAdvisory: advisory
        ))
    }

    /// ステレオ写真として幾何・被写体が両立しているかの総合適合性評価
    /// 左右で別写真が貼られている場合や片側だけ被写体が消失しているケースを検出し、
    /// 空間カバレッジや近景不一致を警告する
    nonisolated static func evaluateStereoQuality(
        matches: [StereoMatchPoint],
        samples: [DisparitySample],
        width w: Double,
        height h: Double,
        isPseudoscopic: Bool,
        isSwapped: Bool
    ) -> (isMismatch: Bool, warningText: String?, reportText: String) {
        // 1. 特徴点数が極端に少ない場合
        if matches.count < 20 || samples.count < 15 {
            let warn = "⚠️ 特徴点不足 (アライメント信頼性低)"
            let rep = "⚠️ Warning: Very low feature matches (\(matches.count) matches, \(samples.count) inliers)"
            return (true, warn, rep)
        }

        // 2. 空間グリッドカバレッジ（3x3 = 9セル）
        var gridCounts = [Int](repeating: 0, count: 9)
        var topCount = 0
        var midCount = 0
        var botCount = 0

        for s in samples {
            let gx = min(2, max(0, Int(s.x / (w / 3.0))))
            let gy = min(2, max(0, Int(s.y / (h / 3.0))))
            gridCounts[gy * 3 + gx] += 1
            if gy == 0 { topCount += 1 }
            else if gy == 1 { midCount += 1 }
            else { botCount += 1 }
        }

        let botActiveCells = [gridCounts[6], gridCounts[7], gridCounts[8]].filter { $0 >= 3 }.count
        let topActiveCells = [gridCounts[0], gridCounts[1], gridCounts[2]].filter { $0 >= 3 }.count
        let midActiveCells = [gridCounts[3], gridCounts[4], gridCounts[5]].filter { $0 >= 3 }.count
        let activeCells = gridCounts.filter { $0 >= 3 }.count

        let totalSamples = Double(samples.count)
        let topRatio = Double(topCount) / totalSamples
        let midRatio = Double(midCount) / totalSamples
        let botRatio = Double(botCount) / totalSamples

        // 1. 近景（手前下部）の被写体不一致・人物消失パターン
        // （奥の部屋や天井・棚は共通してマッチするが、手前の人物や家具が片側にしかいない／別テイク・エラーカード）
        // 上・中部に20点以上のマッチがあるのに、下部（近景）のインライアが極端に少ない（比率8%未満、または下段3セル中有効セルが1以下）
        let isForegroundMismatch = (topCount + midCount >= 20) && (botCount < 8 || botRatio < 0.08 || botActiveCells <= 1)

        // 2. 遠景・背景（画像上部）の不一致パターン（手前だけ一致して背景が別物）
        let isBackgroundMismatch = (botCount + midCount >= 20) && (topCount < 6 || topRatio < 0.06 || topActiveCells <= 1)

        // 3. 極端な空間偏在（3x3グリッド中4セル以下しかカバーされていない、または有効な行が1行以下）
        let activeRows = [topCount, midCount, botCount].filter { $0 >= 8 }.count
        let isSeverelySparse = activeCells <= 4 || activeRows <= 1

        if isForegroundMismatch || isBackgroundMismatch || isSeverelySparse {
            let reason: String
            if isForegroundMismatch {
                reason = "Near foreground mismatch / Missing subject in foreground (botRatio: \(String(format: "%.1f%%", botRatio * 100)), botCells: \(botActiveCells)/3)"
            } else if isBackgroundMismatch {
                reason = "Background / distant scene mismatch (topRatio: \(String(format: "%.1f%%", topRatio * 100)), topCells: \(topActiveCells)/3)"
            } else {
                reason = "Extreme spatial clustering (\(activeCells)/9 grid coverage, \(activeRows)/3 rows)"
            }
            let warn = "⚠️ ステレオ不成立 (左右不一致)"
            let rep = "⚠️ Warning: Stereo Mismatch / Invalid Pair (\(reason); not a consistent stereoscopic pair)"
            return (true, warn, rep)
        }

        // 3. 左右逆（偽視）
        if isPseudoscopic {
            if isSwapped {
                return (false, nil, "Pseudoscopic (Auto-Swapped: Left <-> Right)")
            } else {
                let warn = "⚠️ 左右逆の疑い (偽視)"
                let rep = "⚠️ Warning: Pseudoscopic detected (Reversed Left/Right; needs swap)"
                return (false, warn, rep)
            }
        }

        return (false, nil, "Normal (Consistent stereo pair)")
    }

    /// 視差勾配による左右逆（偽視 / Pseudoscopic）の自動検知
    /// 通常（正視）の場合、手前（画像下部 / 近景）ほど視差 parallax (qR.x - qL.x) は負の方向に大きくなり、
    /// 奥（画像上部 / 遠景）ほど正またはゼロに近くなる (botMed < topMed, diffBotTop < 0)。
    /// 左右逆に貼られている場合、これが逆転して手前（画像下部）ほど視差が正になり、
    /// Y座標（上0→下height）と Parallax に正の相関が生じる (botMed > topMed, diffBotTop >= 2.0 && corrYP >= 0.06)。
    nonisolated static func detectPseudoscopicParallax(samples: [DisparitySample], height: Double) -> Bool {
        guard samples.count >= 10, height > 0 else { return false }

        let n = Double(samples.count)
        let meanY = samples.reduce(0.0) { $0 + $1.y } / n
        let meanP = samples.reduce(0.0) { $0 + $1.parallax } / n
        var covYP = 0.0, varY = 0.0, varP = 0.0
        for s in samples {
            let dy = s.y - meanY
            let dp = s.parallax - meanP
            covYP += dy * dp
            varY += dy * dy
            varP += dp * dp
        }
        let corrYP = (varY > 0 && varP > 0) ? (covYP / sqrt(varY * varP)) : 0.0

        let topPs = samples.filter { $0.y < height * 0.35 }.map(\.parallax).sorted()
        let botPs = samples.filter { $0.y > height * 0.65 }.map(\.parallax).sorted()
        guard topPs.count >= 3, botPs.count >= 3 else { return false }
        let topMed = topPs[topPs.count / 2]
        let botMed = botPs[botPs.count / 2]
        let diffBotTop = botMed - topMed

        return diffBotTop >= 2.0 && corrYP >= 0.06
    }

    /// 左右画像の構造・欠損比較および鮮鋭度評価
    /// 片側プリントの破損（紙の破れ・白抜け・インク染み・カビ・乳剤剥離）を検出
    nonisolated static func evaluateUnilateralDamage(
        leftRGB: [UInt8],
        rightRGB: [UInt8],
        width w: Int,
        height h: Int
    ) -> (isDamaged: Bool, damagedSide: StereoSingleEyeSide?, leftDefect: Double, rightDefect: Double, leftSharp: Double, rightSharp: Double) {
        guard w >= 64, h >= 64, leftRGB.count >= w * h * 3, rightRGB.count >= w * h * 3 else {
            return (false, nil, 0.0, 0.0, 50.0, 50.0)
        }

        let stepX = max(1, w / 256)
        let stepY = max(1, h / 256)

        var sumGradL = 0.0, sumGradR = 0.0
        var sampleCount = 0

        func lumaAt(_ rgb: [UInt8], _ x: Int, _ y: Int) -> Double {
            let idx = (y * w + x) * 3
            return Double(rgb[idx]) * 0.299 + Double(rgb[idx + 1]) * 0.587 + Double(rgb[idx + 2]) * 0.114
        }

        var y = stepY
        while y < h - stepY {
            var x = stepX
            while x < w - stepX {
                let dxL = abs(lumaAt(leftRGB, x + 1, y) - lumaAt(leftRGB, x - 1, y))
                let dyL = abs(lumaAt(leftRGB, x, y + 1) - lumaAt(leftRGB, x, y - 1))
                let dxR = abs(lumaAt(rightRGB, x + 1, y) - lumaAt(rightRGB, x - 1, y))
                let dyR = abs(lumaAt(rightRGB, x, y + 1) - lumaAt(rightRGB, x, y - 1))
                sumGradL += dxL + dyL
                sumGradR += dxR + dyR
                sampleCount += 1
                x += stepX
            }
            y += stepY
        }

        let meanGradL = sampleCount > 0 ? (sumGradL / Double(sampleCount)) : 0.0
        let meanGradR = sampleCount > 0 ? (sumGradR / Double(sampleCount)) : 0.0
        let leftSharp = min(100.0, max(0.0, meanGradL * 3.5))
        let rightSharp = min(100.0, max(0.0, meanGradR * 3.5))

        // 16x16 ブロックグリッドで左右の大きな輝度乖離（欠損・剥離）を評価
        let numBlocksX = 16
        let numBlocksY = 16
        let blockW = max(2, w / numBlocksX)
        let blockH = max(2, h / numBlocksY)
        var leftDefectBlocks = 0
        var rightDefectBlocks = 0
        var totalBlocks = 0

        for by in 0..<numBlocksY {
            let by0 = by * blockH
            let by1 = min(h, (by + 1) * blockH)
            for bx in 0..<numBlocksX {
                let bx0 = bx * blockW
                let bx1 = min(w, (bx + 1) * blockW)

                var sumL = 0.0, sumR = 0.0
                var bSamples = 0
                for py in stride(from: by0, to: by1, by: max(1, blockH / 4)) {
                    for px in stride(from: bx0, to: bx1, by: max(1, blockW / 4)) {
                        sumL += lumaAt(leftRGB, px, py)
                        sumR += lumaAt(rightRGB, px, py)
                        bSamples += 1
                    }
                }
                guard bSamples > 0 else { continue }
                totalBlocks += 1
                let avgL = sumL / Double(bSamples)
                let avgR = sumR / Double(bSamples)
                let diff = abs(avgL - avgR)

                if diff >= 50.0 {
                    if (avgL >= 238.0 || avgL <= 20.0) && (avgR > 25.0 && avgR < 230.0) {
                        leftDefectBlocks += 1
                    } else if (avgR >= 238.0 || avgR <= 20.0) && (avgL > 25.0 && avgL < 230.0) {
                        rightDefectBlocks += 1
                    }
                }
            }
        }

        let leftDefectPct = totalBlocks > 0 ? (Double(leftDefectBlocks) / Double(totalBlocks) * 100.0) : 0.0
        let rightDefectPct = totalBlocks > 0 ? (Double(rightDefectBlocks) / Double(totalBlocks) * 100.0) : 0.0

        let isDamaged = (leftDefectPct >= 4.0 || rightDefectPct >= 4.0) && abs(leftDefectPct - rightDefectPct) >= 2.5
        let damagedSide: StereoSingleEyeSide?
        if isDamaged {
            damagedSide = leftDefectPct > rightDefectPct ? .left : .right
        } else {
            damagedSide = nil
        }

        return (isDamaged, damagedSide, leftDefectPct, rightDefectPct, leftSharp, rightSharp)
    }

    /// Vision Saliency Subject Priority トグル変更時にウィンドウ最適値を再計算・適用
    func recalculateOptimalWindow() {
        if stereoReconstructionMode.isDepthSynthesized {
            reapplyDepthSynthesis()
            return
        }
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
        // スワップ中はユーザーが見る視差が符号反転 (-p) になるため、反転視差で最適化し、実シフトは符号を戻す
        let solveSamples = isSwapped
            ? updatedSamples.map { DisparitySample(x: $0.x, y: $0.y, parallax: -$0.parallax, saliency: $0.saliency, foregroundWeight: $0.foregroundWeight) }
            : updatedSamples
        let solved = Self.resolveWindowDecision(samples: solveSamples, width: w, height: h, preserveArch: hasPreservedArch, options: winOpts)
        let optTx = isSwapped ? -solved.optimalShiftX : solved.optimalShiftX
        hasWindowViolationRisk = solved.hasWindowViolationRisk
        requiresFloatingWindow = solved.requiresFloatingWindow
        autoOptimalShiftX = optTx
        windowShiftX = optTx
        applyManualWindowShift()
    }

    // MARK: - Single-Eye 2D-3D Depth Conversion (救済 3D コンバージョン)

    /// 選択された片側画像から AI 深度推定 ＆ DIBR により高品質な 3D ステレオペアを生成・適用
    func convertSingleEyeToDepth3D(side: StereoSingleEyeSide) {
        guard isAligned || hasLoadedImages else { return }

        // 1. 初回変換時、元の True Stereo ペアをバックアップ
        if !stereoReconstructionMode.isSingleEyeDepth {
            originalTrueStereoAlignedL = alignedLeftRGB
            originalTrueStereoAlignedR = alignedRightRGB
            originalTrueStereoCW = croppedWidth
            originalTrueStereoCH = croppedHeight
            originalTrueStereoPrevWarpedL = previewAlignedLeftRGB
            originalTrueStereoPrevWarpedR = previewAlignedRightRGB
            originalTrueStereoPrevCW = previewCroppedWidth
            originalTrueStereoPrevCH = previewCroppedHeight
            originalTrueStereoWindowShiftX = windowShiftX
            originalTrueStereoMaxDisparityPercent = maxDisparityPercent
        }

        // 2. ソース画像の決定: 台紙から切り出された無歪み 100% 画角 (rawLeftRGB / rawRightRGB) を最優先
        // なければ整準済み画像 (alignedLeftRGB / alignedRightRGB) を使用
        let sourceRGB: [UInt8]
        let srcW: Int
        let srcH: Int
        if side == .left {
            if let rawL = rawLeftRGB, imageWidth > 0, imageHeight > 0 {
                sourceRGB = rawL; srcW = imageWidth; srcH = imageHeight
            } else if let alL = alignedLeftRGB, croppedWidth > 0, croppedHeight > 0 {
                sourceRGB = alL; srcW = croppedWidth; srcH = croppedHeight
            } else { return }
        } else {
            if let rawR = rawRightRGB, imageWidth > 0, imageHeight > 0 {
                sourceRGB = rawR; srcW = imageWidth; srcH = imageHeight
            } else if let alR = alignedRightRGB, croppedWidth > 0, croppedHeight > 0 {
                sourceRGB = alR; srcW = croppedWidth; srcH = croppedHeight
            } else { return }
        }

        isProcessing = true
        statusMessage = String(localized: "Estimating Depth & Generating 3D Stereo Pair...")

        let samples = lastDisparitySamples
        let targetDispPct = virtualDepthBasePercent
        let gamma = depthGamma
        let useSaliency = useAttentionSaliency
        let preserveArch = hasPreservedArch
        let existingSalMap = lastRawSaliencyMap
        let preferredEngine = ViewStereoSettings.shared.preferredDepthEngine
        let releaseAfter = ViewStereoSettings.shared.releaseAIModelsAfterGeneration

        Task {
            let synth = ViewStereoDepthSynthesizer.shared
            // AI 深度推論（優先エンジン＋自動メモリ解放設定を適用）
            guard let depthRes = synth.estimateDisparity(
                rgb: sourceRGB,
                width: srcW,
                height: srcH,
                preferredEngine: preferredEngine,
                releaseAfterInference: releaseAfter
            ) else {
                await MainActor.run {
                    self.isProcessing = false
                    self.statusMessage = String(localized: "Depth estimation failed.")
                }
                return
            }

            // 実測視差サンプルによる較正（サンプルが十分あれば）
            var dispMap = depthRes.disparity
            if !samples.isEmpty {
                dispMap = ViewStereoDepthSynthesizer.calibrateWithSparseStereo(
                    disparityMap: dispMap,
                    depthW: depthRes.width,
                    depthH: depthRes.height,
                    sparseSamples: samples,
                    imageWidth: Double(srcW),
                    imageHeight: Double(srcH)
                )
            }

            var salMap = existingSalMap
            if salMap == nil && useSaliency,
               let cgImg = ViewStereoDepthSynthesizer.createCGImage(from: sourceRGB, width: srcW, height: srcH) {
                salMap = try? VisionAnalyzer.extractAttentionSaliency(from: cgImg)
            }

            // ステレオウィンドウ自動最適化（エッジ飛び出し防止）
            let winSetup = Self.computeDepthWindowSetup(
                disparityMap: dispMap,
                depthW: depthRes.width,
                depthH: depthRes.height,
                imageWidth: srcW,
                imageHeight: srcH,
                targetDisparityPercent: targetDispPct,
                depthGamma: gamma,
                saliencyMap: salMap,
                useSaliency: useSaliency,
                preserveArch: preserveArch
            )

            // DIBR 対称ワーピングによるフル解像度ステレオペア合成
            let (fullL, fullR) = synth.synthesizeStereoPair(
                baseRGB: sourceRGB,
                width: srcW,
                height: srcH,
                disparityMap: dispMap,
                depthW: depthRes.width,
                depthH: depthRes.height,
                targetDisparityPercent: targetDispPct,
                depthGamma: gamma,
                focusRatio: winSetup.focusRatio
            )

            // プレビュー用軽量バッファ（最大長辺 previewMaxDimension = 1440）の生成
            let prevScale = min(1.0, Double(Self.previewMaxDimension) / Double(max(srcW, srcH)))
            let prevW = max(1, Int(Double(srcW) * prevScale))
            let prevH = max(1, Int(Double(srcH) * prevScale))
            let prevL = ViewStereoDepthSynthesizer.resizeRGB(fullL, width: srcW, height: srcH, targetWidth: prevW, targetHeight: prevH)
            let prevR = ViewStereoDepthSynthesizer.resizeRGB(fullR, width: srcW, height: srcH, targetWidth: prevW, targetHeight: prevH)

            await MainActor.run {
                self.cachedBaseSideRGB = sourceRGB
                self.cachedBaseW = srcW
                self.cachedBaseH = srcH
                self.cachedDisparityMap = dispMap
                self.cachedDepthW = depthRes.width
                self.cachedDepthH = depthRes.height
                self.cachedSynthFullLeftRGB = fullL
                self.cachedSynthFullRightRGB = fullR
                if let salMap {
                    self.lastRawSaliencyMap = salMap
                }

                self.alignedLeftRGB = fullL
                self.alignedRightRGB = fullR
                self.croppedWidth = srcW
                self.croppedHeight = srcH
                self.previewAlignedLeftRGB = prevL
                self.previewAlignedRightRGB = prevR
                self.previewCroppedWidth = prevW
                self.previewCroppedHeight = prevH
                self.rectifiedPreviewLeftRGB = prevL
                self.rectifiedPreviewRightRGB = prevR
                self.rectifiedPreviewWidth = prevW
                self.rectifiedPreviewHeight = prevH

                self.stereoReconstructionMode = .singleEyeDepth(side)
                self.isSwapped = false
                self.lastDisparitySamples = winSetup.samples
                self.windowShiftX = 0.0
                self.autoOptimalShiftX = 0.0
                self.lastFullResShiftX = 0.0
                self.hasWindowViolationRisk = winSetup.hasWindowViolationRisk
                self.requiresFloatingWindow = winSetup.requiresFloatingWindow
                self.maxDisparityPercent = winSetup.dispRangePct
                self.isProcessing = false
                self.statusMessage = String(format: String(localized: "3D Conversion Done (%@) | Disp: %.1f%% | %.0f ms"), depthRes.engineName, targetDispPct, depthRes.elapsedMs)
                self.renderDisplayPreview()
            }
        }
    }

    /// 2D 写真（フル画角）から AI 深度推定 + DIBR により 3D ステレオペアを生成する
    func convertFullFrame2DToDepth3D(rgb sourceRGB: [UInt8], width srcW: Int, height srcH: Int) {
        isProcessing = true
        statusMessage = String(localized: "2D photo detected — Estimating depth & converting to 3D...")

        let targetDispPct = virtualDepthBasePercent
        let gamma = depthGamma
        let useSaliency = useAttentionSaliency
        let preserveArch = hasPreservedArch
        let preferredEngine = ViewStereoSettings.shared.preferredDepthEngine
        let releaseAfter = ViewStereoSettings.shared.releaseAIModelsAfterGeneration
        let activeID = workspaceActiveItemID

        Task {
            let synth = ViewStereoDepthSynthesizer.shared
            guard let depthRes = synth.estimateDisparity(
                rgb: sourceRGB,
                width: srcW,
                height: srcH,
                preferredEngine: preferredEngine,
                releaseAfterInference: releaseAfter
            ) else {
                await MainActor.run {
                    self.isProcessing = false
                    self.statusMessage = String(localized: "Depth estimation failed.")
                    if let activeID {
                        self.workspaceItemStatuses[activeID] = .failed("Depth estimation failed")
                    }
                }
                return
            }

            var salMap: NormalizedFloatMap? = nil
            if useSaliency,
               let cgImg = ViewStereoDepthSynthesizer.createCGImage(from: sourceRGB, width: srcW, height: srcH) {
                salMap = try? VisionAnalyzer.extractAttentionSaliency(from: cgImg)
            }

            let winSetup = Self.computeDepthWindowSetup(
                disparityMap: depthRes.disparity,
                depthW: depthRes.width,
                depthH: depthRes.height,
                imageWidth: srcW,
                imageHeight: srcH,
                targetDisparityPercent: targetDispPct,
                depthGamma: gamma,
                saliencyMap: salMap,
                useSaliency: useSaliency,
                preserveArch: preserveArch
            )

            let (fullL, fullR) = synth.synthesizeStereoPair(
                baseRGB: sourceRGB,
                width: srcW,
                height: srcH,
                disparityMap: depthRes.disparity,
                depthW: depthRes.width,
                depthH: depthRes.height,
                targetDisparityPercent: targetDispPct,
                depthGamma: gamma,
                focusRatio: winSetup.focusRatio
            )

            let prevScale = min(1.0, Double(Self.previewMaxDimension) / Double(max(srcW, srcH)))
            let prevW = max(1, Int(Double(srcW) * prevScale))
            let prevH = max(1, Int(Double(srcH) * prevScale))
            let prevL = ViewStereoDepthSynthesizer.resizeRGB(fullL, width: srcW, height: srcH, targetWidth: prevW, targetHeight: prevH)
            let prevR = ViewStereoDepthSynthesizer.resizeRGB(fullR, width: srcW, height: srcH, targetWidth: prevW, targetHeight: prevH)

            await MainActor.run {
                self.cachedBaseSideRGB = sourceRGB
                self.cachedBaseW = srcW
                self.cachedBaseH = srcH
                self.cachedDisparityMap = depthRes.disparity
                self.cachedDepthW = depthRes.width
                self.cachedDepthH = depthRes.height
                self.cachedSynthFullLeftRGB = fullL
                self.cachedSynthFullRightRGB = fullR
                self.lastRawSaliencyMap = salMap

                self.alignedLeftRGB = fullL
                self.alignedRightRGB = fullR
                self.croppedWidth = srcW
                self.croppedHeight = srcH
                self.previewAlignedLeftRGB = prevL
                self.previewAlignedRightRGB = prevR
                self.previewCroppedWidth = prevW
                self.previewCroppedHeight = prevH
                self.rectifiedPreviewLeftRGB = prevL
                self.rectifiedPreviewRightRGB = prevR
                self.rectifiedPreviewWidth = prevW
                self.rectifiedPreviewHeight = prevH

                self.isAligned = true
                self.stereoReconstructionMode = .fullFrame2DDepth
                self.isSwapped = false
                self.lastDisparitySamples = winSetup.samples
                self.windowShiftX = 0.0
                self.autoOptimalShiftX = 0.0
                self.lastFullResShiftX = 0.0
                self.hasWindowViolationRisk = winSetup.hasWindowViolationRisk
                self.requiresFloatingWindow = winSetup.requiresFloatingWindow
                self.maxDisparityPercent = winSetup.dispRangePct
                self.verticalRMSE = 0.0
                self.lastDepthEngineLabel = depthRes.engineName
                self.lastDepthInferenceMs = depthRes.elapsedMs
                self.isProcessing = false
                self.statusMessage = String(format: String(localized: "2D→3D Conversion Done (%@) | Disp: %.1f%% | %.0f ms"), depthRes.engineName, targetDispPct, depthRes.elapsedMs)
                if let activeID {
                    self.workspaceItemStatuses[activeID] = .aiConverted("2D→3D")
                }
                self.renderDisplayPreview()
            }
        }
    }

    /// 単一画像が SBS ステレオ画像ではなく通常の 2D 写真であるかを多段階で自動判定する
    nonisolated static func detectIs2DPhoto(rgb: [UInt8], width fw: Int, height fh: Int) -> Bool {
        guard fw >= 64, fh >= 32, rgb.count >= fw * fh * 3 else { return true }
        let aspect = Double(fw) / Double(fh)
        // 縦長・正方形（< 1.15）は SBS の可能性がないため即 2D 判定
        if aspect < 1.15 {
            return true
        }

        let halfW = fw / 2
        var leftHalf = [UInt8](repeating: 0, count: halfW * fh * 3)
        var rightHalf = [UInt8](repeating: 0, count: halfW * fh * 3)
        for y in 0..<fh {
            let srcRow = y * fw * 3
            let dstRow = y * halfW * 3
            leftHalf[dstRow..<(dstRow + halfW * 3)] = rgb[srcRow..<(srcRow + halfW * 3)]
            rightHalf[dstRow..<(dstRow + halfW * 3)] = rgb[(srcRow + halfW * 3)..<(srcRow + halfW * 6)]
        }

        // 1. 左右半分の低解像度 SIFT 特徴点一致を評価（SBS / ハーフSBS なら水平一致が多数発生）
        let (sL, sw, sh) = downsampleForPreview(leftHalf, width: halfW, height: fh, maxDim: 320)
        let (sR, _, _) = downsampleForPreview(rightHalf, width: halfW, height: fh, maxDim: 320)
        let matches = SiftFeatureMatcher.detectAndMatch(leftRGB: sL, rightRGB: sR, width: sw, height: sh)
        let dyTol = max(12.0, Double(sh) * 0.08)
        let dxTol = max(24.0, Double(sw) * 0.28)
        let horizMatches = matches.filter {
            abs($0.y2 - $0.y1) <= dyTol && abs($0.x2 - $0.x1) <= dxTol
        }
        if horizMatches.count >= 10 {
            return false // SBS と判定
        }

        // 2. 低テクスチャ時の補助判定：中央境界 (x = halfW) の垂直スパイク + 左右 NCC 相関
        let midX = halfW
        let stepY = max(1, fh / 128)
        var seamDiff = 0.0
        var neighborDiff = 0.0
        var seamSamples = 0
        let offset = max(4, min(16, fw / 60))

        func lumaAt(_ x: Int, _ y: Int) -> Double {
            let idx = (y * fw + x) * 3
            return Double(rgb[idx]) * 0.299 + Double(rgb[idx + 1]) * 0.587 + Double(rgb[idx + 2]) * 0.114
        }

        var y = 0
        while y < fh {
            if midX - 2 >= 0 && midX + 2 < fw {
                seamDiff += abs(lumaAt(midX - 1, y) - lumaAt(midX + 1, y))
                let lX = max(1, midX - offset)
                let rX = min(fw - 2, midX + offset)
                neighborDiff += 0.5 * (abs(lumaAt(lX - 1, y) - lumaAt(lX + 1, y)) + abs(lumaAt(rX - 1, y) - lumaAt(rX + 1, y)))
                seamSamples += 1
            }
            y += stepY
        }

        let avgSeam = seamSamples > 0 ? seamDiff / Double(seamSamples) : 0.0
        let avgNeigh = seamSamples > 0 ? max(1.0, neighborDiff / Double(seamSamples)) : 1.0
        let spikeRatio = avgSeam / avgNeigh

        // 左右低解像度 NCC
        let n = sw * sh
        var sumL = 0.0, sumR = 0.0
        for i in 0..<n {
            let idx = i * 3
            sumL += Double(sL[idx]) * 0.299 + Double(sL[idx + 1]) * 0.587 + Double(sL[idx + 2]) * 0.114
            sumR += Double(sR[idx]) * 0.299 + Double(sR[idx + 1]) * 0.587 + Double(sR[idx + 2]) * 0.114
        }
        let meanL = sumL / Double(max(1, n))
        let meanR = sumR / Double(max(1, n))
        var cov = 0.0, varL = 0.0, varR = 0.0
        for i in 0..<n {
            let idx = i * 3
            let l = (Double(sL[idx]) * 0.299 + Double(sL[idx + 1]) * 0.587 + Double(sL[idx + 2]) * 0.114) - meanL
            let r = (Double(sR[idx]) * 0.299 + Double(sR[idx + 1]) * 0.587 + Double(sR[idx + 2]) * 0.114) - meanR
            cov += l * r
            varL += l * l
            varR += r * r
        }
        let ncc = (varL > 0 && varR > 0) ? (cov / sqrt(varL * varR)) : 0.0

        if spikeRatio >= 2.2 && ncc >= 0.35 {
            return false // ハーフSBS等の境界ありステレオと判定
        }

        return true
    }

    /// 深度マップキャッシュを用いたリアルタイム高速再ワーピング（スライダー操作時）
    func reapplyDepthSynthesis() {
        guard stereoReconstructionMode.isDepthSynthesized,
              let dispMap = cachedDisparityMap,
              let baseRGB = cachedBaseSideRGB,
              cachedBaseW > 0, cachedBaseH > 0 else { return }

        let srcW = cachedBaseW
        let srcH = cachedBaseH
        let depthW = cachedDepthW
        let depthH = cachedDepthH
        let targetDispPct = virtualDepthBasePercent
        let gamma = depthGamma
        let useSaliency = useAttentionSaliency
        let preserveArch = hasPreservedArch
        let salMap = lastRawSaliencyMap

        Task {
            let winSetup = Self.computeDepthWindowSetup(
                disparityMap: dispMap,
                depthW: depthW,
                depthH: depthH,
                imageWidth: srcW,
                imageHeight: srcH,
                targetDisparityPercent: targetDispPct,
                depthGamma: gamma,
                saliencyMap: salMap,
                useSaliency: useSaliency,
                preserveArch: preserveArch
            )

            let synth = ViewStereoDepthSynthesizer.shared
            let (fullL, fullR) = synth.synthesizeStereoPair(
                baseRGB: baseRGB,
                width: srcW,
                height: srcH,
                disparityMap: dispMap,
                depthW: depthW,
                depthH: depthH,
                targetDisparityPercent: targetDispPct,
                depthGamma: gamma,
                focusRatio: winSetup.focusRatio
            )

            let prevScale = min(1.0, Double(Self.previewMaxDimension) / Double(max(srcW, srcH)))
            let prevW = max(1, Int(Double(srcW) * prevScale))
            let prevH = max(1, Int(Double(srcH) * prevScale))
            let prevL = ViewStereoDepthSynthesizer.resizeRGB(fullL, width: srcW, height: srcH, targetWidth: prevW, targetHeight: prevH)
            let prevR = ViewStereoDepthSynthesizer.resizeRGB(fullR, width: srcW, height: srcH, targetWidth: prevW, targetHeight: prevH)

            await MainActor.run {
                self.cachedSynthFullLeftRGB = fullL
                self.cachedSynthFullRightRGB = fullR
                self.alignedLeftRGB = fullL
                self.alignedRightRGB = fullR
                self.croppedWidth = srcW
                self.croppedHeight = srcH
                self.previewAlignedLeftRGB = prevL
                self.previewAlignedRightRGB = prevR
                self.previewCroppedWidth = prevW
                self.previewCroppedHeight = prevH
                self.rectifiedPreviewLeftRGB = prevL
                self.rectifiedPreviewRightRGB = prevR
                self.rectifiedPreviewWidth = prevW
                self.rectifiedPreviewHeight = prevH
                self.lastDisparitySamples = winSetup.samples
                self.lastFullResShiftX = 0.0

                if abs(self.windowShiftX) > 0.05 {
                    self.scheduleRealtimeWindowPreview()
                } else {
                    self.hasWindowViolationRisk = winSetup.hasWindowViolationRisk
                    self.requiresFloatingWindow = winSetup.requiresFloatingWindow
                    self.maxDisparityPercent = winSetup.dispRangePct
                    self.renderDisplayPreview()
                }
            }
        }
    }

    /// 変換前のオリジナル真ステレオペアに非破壊復元
    func revertToOriginalStereoPair() {
        guard stereoReconstructionMode.isSingleEyeDepth,
              let l = originalTrueStereoAlignedL,
              let r = originalTrueStereoAlignedR else { return }

        alignedLeftRGB = l
        alignedRightRGB = r
        croppedWidth = originalTrueStereoCW
        croppedHeight = originalTrueStereoCH
        previewAlignedLeftRGB = originalTrueStereoPrevWarpedL
        previewAlignedRightRGB = originalTrueStereoPrevWarpedR
        previewCroppedWidth = originalTrueStereoPrevCW
        previewCroppedHeight = originalTrueStereoPrevCH
        rectifiedPreviewLeftRGB = originalTrueStereoPrevWarpedL
        rectifiedPreviewRightRGB = originalTrueStereoPrevWarpedR
        rectifiedPreviewWidth = originalTrueStereoPrevCW
        rectifiedPreviewHeight = originalTrueStereoPrevCH

        windowShiftX = originalTrueStereoWindowShiftX
        autoOptimalShiftX = originalTrueStereoWindowShiftX
        maxDisparityPercent = originalTrueStereoMaxDisparityPercent
        stereoReconstructionMode = .trueStereo
        statusMessage = String(localized: "Restored to original stereo pair.")
        renderDisplayPreview()
    }

    // MARK: - Video 2D-to-3D Pipeline (Phase 1 MVP)

    /// 動画関連の状態・再生タスク・Stateful セッションをクリーンリセットする
    func clearVideoState() {
        videoPlaybackTask?.cancel()
        videoPlaybackTask = nil
        videoFrameTask?.cancel()
        videoFrameTask = nil
        videoExportTask?.cancel()
        videoExportTask = nil
        videoPreviewGeneration += 1
        isVideoFrameInferring = false
        isVideoPlaying = false
        isExportingVideo = false
        videoExportProgress = 0.0
        videoExportStatusText = ""
        videoActiveEngineLabel = ""
        videoPreviewSession?.endSession(releaseModel: ViewStereoSettings.shared.releaseAIModelsAfterGeneration)
        videoPreviewSession = nil
        isVideoLoaded = false
        currentVideoURL = nil
        videoMetadata = nil
        videoCurrentTimeSeconds = 0.0
        videoInputStereoSource = .full2D
    }

    /// 動画ファイルを読み込み、タイムラインプレビュー用 Stateful セッションを開始する
    func loadVideo(url: URL) {
        currentImageLoadTask?.cancel()
        clearVideoState()
        imageLoadGeneration += 1

        isBatchQueueActive = false
        batchCompletionSummary = nil
        hasPreservedArch = false
        salvageAdvisory = nil
        isStereoMismatchSuspected = false
        isPseudoscopicSuspected = false
        stereoQualityWarning = nil
        lastMatches = []
        lastRectResult = nil
        lastCommonPolygon = []
        lastRawSaliencyMap = nil
        originalTrueStereoAlignedL = nil
        originalTrueStereoAlignedR = nil

        workspaceActiveItemID = url.path
        workspaceItemStatuses[url.path] = .processing
        leftURL = url
        rightURL = url
        isSingleSBSInput = true
        isVideoLoaded = true
        currentVideoURL = url
        isProcessing = true
        statusMessage = String(localized: "Loading video metadata...")

        let preferredEngine = ViewStereoSettings.shared.preferredDepthEngine
        Task {
            guard let meta = await ViewStereoVideoProcessor.shared.loadMetadata(url: url) else {
                await MainActor.run {
                    self.isProcessing = false
                    self.isVideoLoaded = false
                    self.currentVideoURL = nil
                    self.workspaceItemStatuses[url.path] = .failed(String(localized: "Failed to load video."))
                    self.statusMessage = String(localized: "Failed to load video.")
                }
                return
            }

            let session = ViewStereoVideoDepthSession()
            await Task.detached(priority: .userInitiated) {
                session.startSession(preferredEngine: preferredEngine)
            }.value

            await MainActor.run {
                guard self.currentVideoURL == url else {
                    session.endSession(releaseModel: ViewStereoSettings.shared.releaseAIModelsAfterGeneration)
                    return
                }
                self.videoMetadata = meta
                self.imageWidth = meta.naturalWidth
                self.imageHeight = meta.naturalHeight
                self.croppedWidth = meta.naturalWidth
                self.croppedHeight = meta.naturalHeight
                self.videoPreviewSession = session
                self.videoActiveEngineLabel = session.activeEngineName
                self.stereoReconstructionMode = .fullFrame2DDepth
                self.isWindowSectionExpanded = true
                self.isProcessing = false
                self.workspaceItemStatuses[url.path] = .completed
                self.seekVideoAndRender(to: 0.0, resetSession: true)
            }
        }
    }

    /// 指定秒数のフレームをデコードして 2D→3D プレビューを更新する
    /// - 再生中 (`isPlaybackFrame == true`) は 720p 上限でフレームスキップ許容、停止／シーク確定時は 1280p ＋プログレッシブウォームアップ更新
    func seekVideoAndRender(
        to seconds: Double,
        resetSession: Bool = false,
        isPlaybackFrame: Bool = false,
        progressiveWarmup: Bool = false
    ) {
        guard isVideoLoaded, let url = currentVideoURL, let meta = videoMetadata else { return }
        let clampedTime = max(0.0, min(meta.durationSeconds, seconds))
        videoCurrentTimeSeconds = clampedTime

        // 再生中は前フレームの推論が完了していなければフレームスキップして UI フリーズを防止
        if isPlaybackFrame && isVideoFrameInferring {
            return
        }

        videoPreviewGeneration += 1
        let gen = videoPreviewGeneration
        videoFrameTask?.cancel()
        isVideoFrameInferring = true

        let session = videoPreviewSession ?? ViewStereoVideoDepthSession()
        if videoPreviewSession == nil {
            session.startSession(preferredEngine: ViewStereoSettings.shared.preferredDepthEngine)
            videoPreviewSession = session
        }

        let dispPct = virtualDepthBasePercent
        let gamma = depthGamma
        let smoothing = videoTemporalSmoothing
        let lockRange = videoLockDepthRange
        let autoCut = videoAutoCutDetection
        let inputSrc = videoInputStereoSource
        let previewMaxDim = isPlaybackFrame ? 720 : 1280
        let shouldWarmup = progressiveWarmup && !isPlaybackFrame && ViewStereoSettings.shared.preferredDepthEngine.isDepthPro2Engine && clampedTime > (2.0 / max(1.0, meta.nominalFPS))

        videoFrameTask = Task {
            defer {
                Task { @MainActor in
                    if self.videoPreviewGeneration == gen {
                        self.isVideoFrameInferring = false
                    }
                }
            }
            if resetSession {
                session.resetTemporalState()
            }
            guard let decoded = await ViewStereoVideoProcessor.shared.decodePreviewFrame(url: url, atSeconds: clampedTime, maxDimension: previewMaxDim, inputSource: inputSrc) else {
                return
            }
            if Task.isCancelled { return }
            guard let cgImg = ViewStereoDepthSynthesizer.createCGImage(from: decoded.rgb, width: decoded.width, height: decoded.height) else {
                return
            }

            let res = await Task.detached(priority: .userInitiated) { () -> (disp: [Float], dw: Int, dh: Int, left: [UInt8], right: [UInt8], focus: Double, engineName: String) in
                let dOut = session.processFrame(
                    cgImage: cgImg,
                    rgb24: decoded.rgb,
                    width: decoded.width,
                    height: decoded.height,
                    targetDisparityPercent: dispPct,
                    depthGamma: gamma,
                    temporalSmoothing: smoothing,
                    lockDepthRange: lockRange,
                    autoCutDetection: autoCut
                )
                let (l, r) = ViewStereoDepthSynthesizer.shared.synthesizeStereoPair(
                    baseRGB: decoded.rgb,
                    width: decoded.width,
                    height: decoded.height,
                    disparityMap: dOut.disparityMap,
                    depthW: dOut.depthW,
                    depthH: dOut.depthH,
                    targetDisparityPercent: dispPct,
                    depthGamma: gamma,
                    focusRatio: dOut.focusRatio
                )
                return (dOut.disparityMap, dOut.depthW, dOut.depthH, l, r, dOut.focusRatio, dOut.engineName)
            }.value

            if Task.isCancelled { return }
            await applyVideoPreviewResult(decoded: decoded, res: res, gen: gen, url: url, meta: meta, dispPct: dispPct)

            // プログレッシブ・ウォームアップ更新（Depth Pro 2 シーク確定時: 直前2フレームを非同期ウォームアップして再上書き）
            if shouldWarmup && !Task.isCancelled {
                let dt = 1.0 / max(1.0, meta.nominalFPS)
                let warmupTimes = [max(0.0, clampedTime - 2.0 * dt), max(0.0, clampedTime - dt)]
                session.resetTemporalState()
                for wt in warmupTimes {
                    if Task.isCancelled { return }
                    if let wDec = await ViewStereoVideoProcessor.shared.decodePreviewFrame(url: url, atSeconds: wt, maxDimension: 720, inputSource: inputSrc),
                       let wCG = ViewStereoDepthSynthesizer.createCGImage(from: wDec.rgb, width: wDec.width, height: wDec.height) {
                        _ = await Task.detached(priority: .utility) {
                            session.processFrame(
                                cgImage: wCG,
                                rgb24: wDec.rgb,
                                width: wDec.width,
                                height: wDec.height,
                                targetDisparityPercent: dispPct,
                                depthGamma: gamma,
                                temporalSmoothing: smoothing,
                                lockDepthRange: lockRange,
                                autoCutDetection: autoCut
                            )
                        }.value
                    }
                }
                if Task.isCancelled { return }
                let refined = await Task.detached(priority: .utility) { () -> (disp: [Float], dw: Int, dh: Int, left: [UInt8], right: [UInt8], focus: Double, engineName: String) in
                    let dOut = session.processFrame(
                        cgImage: cgImg,
                        rgb24: decoded.rgb,
                        width: decoded.width,
                        height: decoded.height,
                        targetDisparityPercent: dispPct,
                        depthGamma: gamma,
                        temporalSmoothing: smoothing,
                        lockDepthRange: lockRange,
                        autoCutDetection: autoCut
                    )
                    let (l, r) = ViewStereoDepthSynthesizer.shared.synthesizeStereoPair(
                        baseRGB: decoded.rgb,
                        width: decoded.width,
                        height: decoded.height,
                        disparityMap: dOut.disparityMap,
                        depthW: dOut.depthW,
                        depthH: dOut.depthH,
                        targetDisparityPercent: dispPct,
                        depthGamma: gamma,
                        focusRatio: dOut.focusRatio
                    )
                    return (dOut.disparityMap, dOut.depthW, dOut.depthH, l, r, dOut.focusRatio, dOut.engineName)
                }.value
                if Task.isCancelled { return }
                await applyVideoPreviewResult(decoded: decoded, res: refined, gen: gen, url: url, meta: meta, dispPct: dispPct)
            }
        }
    }

    private func applyVideoPreviewResult(
        decoded: (rgb: [UInt8], cgImage: CGImage, width: Int, height: Int, actualSeconds: Double),
        res: (disp: [Float], dw: Int, dh: Int, left: [UInt8], right: [UInt8], focus: Double, engineName: String),
        gen: Int,
        url: URL,
        meta: VideoClipMetadata,
        dispPct: Double
    ) async {
        await MainActor.run {
            guard self.videoPreviewGeneration == gen, self.currentVideoURL == url else { return }
            self.cachedBaseSideRGB = decoded.rgb
            self.cachedBaseW = decoded.width
            self.cachedBaseH = decoded.height
            self.cachedDisparityMap = res.disp
            self.cachedDepthW = res.dw
            self.cachedDepthH = res.dh

            self.alignedLeftRGB = res.left
            self.alignedRightRGB = res.right
            self.croppedWidth = decoded.width
            self.croppedHeight = decoded.height
            self.previewAlignedLeftRGB = res.left
            self.previewAlignedRightRGB = res.right
            self.previewCroppedWidth = decoded.width
            self.previewCroppedHeight = decoded.height
            self.rectifiedPreviewLeftRGB = res.left
            self.rectifiedPreviewRightRGB = res.right
            self.rectifiedPreviewWidth = decoded.width
            self.rectifiedPreviewHeight = decoded.height

            self.isAligned = true
            self.windowShiftX = 0.0
            self.autoOptimalShiftX = 0.0
            self.maxDisparityPercent = dispPct
            self.videoActiveEngineLabel = res.engineName
            self.statusMessage = String(format: String(localized: "Video Frame %.2fs | %dx%d | %@"), decoded.actualSeconds, meta.naturalWidth, meta.naturalHeight, res.engineName)
            self.renderDisplayPreview()
        }
    }

    /// 1 フレーム前後にステップ移動する
    func stepVideoFrame(deltaFrames: Int) {
        guard isVideoLoaded, let meta = videoMetadata else { return }
        if isVideoPlaying { toggleVideoPlayback() }
        let stepSec = 1.0 / max(1.0, meta.nominalFPS)
        seekVideoAndRender(to: videoCurrentTimeSeconds + Double(deltaFrames) * stepSec, resetSession: deltaFrames < 0, isPlaybackFrame: false, progressiveWarmup: deltaFrames < 0)
    }

    /// 動画プレビューの再生／一時停止をトグルする（再生中は 720p・フレームスキップ許容で MLState を継続、停止時に 1280p 再描画）
    func toggleVideoPlayback() {
        guard isVideoLoaded, let meta = videoMetadata else { return }
        if isVideoPlaying {
            videoPlaybackTask?.cancel()
            videoPlaybackTask = nil
            isVideoPlaying = false
            seekVideoAndRender(to: videoCurrentTimeSeconds, resetSession: false, isPlaybackFrame: false, progressiveWarmup: false)
            return
        }

        if videoCurrentTimeSeconds >= max(0.0, meta.durationSeconds - 0.05) {
            videoCurrentTimeSeconds = 0.0
            videoPreviewSession?.resetTemporalState()
        }
        isVideoPlaying = true
        let stepSec = max(1.0 / 15.0, 1.0 / max(1.0, meta.nominalFPS))
        videoPlaybackTask = Task {
            while !Task.isCancelled && self.isVideoPlaying {
                let nextT = self.videoCurrentTimeSeconds + stepSec
                if nextT >= meta.durationSeconds {
                    await MainActor.run {
                        self.isVideoPlaying = false
                    }
                    break
                }
                self.seekVideoAndRender(to: nextT, resetSession: false, isPlaybackFrame: true, progressiveWarmup: false)
                try? await Task.sleep(nanoseconds: UInt64(stepSec * 1_000_000_000))
            }
        }
    }

    /// 優先エンジン切り替え後に動画セッションを再初期化して現在フレームを再推論する
    func refreshVideoEngineAndReprocess() {
        guard isVideoLoaded else { return }
        videoPreviewSession?.startSession(preferredEngine: ViewStereoSettings.shared.preferredDepthEngine)
        videoActiveEngineLabel = videoPreviewSession?.activeEngineName ?? ""
        seekVideoAndRender(to: videoCurrentTimeSeconds, resetSession: true)
    }

    /// 動画 2D→3D フル書き出し（Spatial Video MV-HEVC / Full SBS / Half SBS / Anaglyph）
    func exportVideo(toQuickOutput: Bool) {
        guard isVideoLoaded, let sourceURL = currentVideoURL, let meta = videoMetadata, !isExportingVideo else { return }
        if isVideoPlaying { toggleVideoPlayback() }

        let format = videoExportFormat
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let defaultFilename = "\(baseName)\(format.suffix).\(format.fileExtension)"

        let targetURL: URL
        if toQuickOutput {
            let outDir = batchOutputFolder ?? sourceURL.deletingLastPathComponent().appendingPathComponent("ViewStereo_Output", isDirectory: true)
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            targetURL = outDir.appendingPathComponent(defaultFilename)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = defaultFilename
            panel.allowedContentTypes = format == .spatialVideo ? [.quickTimeMovie] : [.mpeg4Movie]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            targetURL = url
        }

        // 書き出し前のディスク空き容量事前チェック
        let estBytes = ViewStereoVideoProcessor.estimateOutputFileSizeBytes(metadata: meta, format: format)
        let requiredBytes = Int64(Double(estBytes) * 1.2) + 200_000_000
        if let avail = ViewStereoVideoProcessor.availableDiskSpaceBytes(at: targetURL), avail < requiredBytes {
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            let estStr = fmt.string(fromByteCount: estBytes)
            let availStr = fmt.string(fromByteCount: avail)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Low Disk Space Warning")
            alert.informativeText = String(format: String(localized: "Estimated video size is ~%@, but only %@ is available on the destination drive. Continue anyway?"), estStr, availStr)
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Continue Anyway"))
            if alert.runModal() == .alertFirstButtonReturn {
                return
            }
        }

        isExportingVideo = true
        videoExportProgress = 0.0
        videoExportStatusText = String(localized: "Preparing video export...")

        let preferredEngine = ViewStereoSettings.shared.preferredDepthEngine
        let releaseAfter = ViewStereoSettings.shared.releaseAIModelsAfterGeneration
        let dispPct = virtualDepthBasePercent
        let gamma = depthGamma
        let smoothing = videoTemporalSmoothing
        let lockRange = videoLockDepthRange
        let autoCut = videoAutoCutDetection
        let swapped = isSwapped
        let inputSrc = videoInputStereoSource
        let preserveHDR = videoPreserveHDR
        let cardCfg = appliedCardMountConfig
        let toneOpts = makeVintageRestorationOptions()
        let detailOpts = makeDetailRestorationOptions()
        let colorOpts = makeColorizationOptions()

        videoExportTask = Task {
            do {
                let savedURL = try await ViewStereoVideoProcessor.shared.exportVideo(
                    sourceURL: sourceURL,
                    outputURL: targetURL,
                    metadata: meta,
                    format: format,
                    preferredEngine: preferredEngine,
                    virtualDepthBasePercent: dispPct,
                    depthGamma: gamma,
                    temporalSmoothing: smoothing,
                    lockDepthRange: lockRange,
                    autoCutDetection: autoCut,
                    isSwapped: swapped,
                    inputSource: inputSrc,
                    preserveHDR: preserveHDR,
                    cardConfig: cardCfg,
                    toneOptions: toneOpts,
                    detailOptions: detailOpts,
                    colorOptions: colorOpts,
                    releaseAfterExport: releaseAfter
                ) { prog, frameIdx, totalFrames, fps in
                    self.videoExportProgress = prog
                    self.videoExportStatusText = String(format: "%d / %d frames (%.1f fps)", frameIdx, totalFrames, fps)
                }

                await MainActor.run {
                    self.isExportingVideo = false
                    self.videoExportProgress = 1.0
                    self.videoExportStatusText = ""
                    self.workspaceItemStatuses[sourceURL.path] = .aiConverted(format.rawValue)
                    self.statusMessage = String(format: String(localized: "Video exported: %@"), savedURL.lastPathComponent)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isExportingVideo = false
                    self.videoExportProgress = 0.0
                    self.videoExportStatusText = ""
                    self.statusMessage = String(localized: "Video export cancelled.")
                }
            } catch {
                await MainActor.run {
                    self.isExportingVideo = false
                    self.videoExportProgress = 0.0
                    self.videoExportStatusText = ""
                    self.statusMessage = String(format: String(localized: "Video export failed: %@"), error.localizedDescription)
                }
            }
        }
    }

    func cancelVideoExport() {
        videoExportTask?.cancel()
        videoExportTask = nil
    }

    /// ウィンドウ最適シフトを解き、ステレオカード(preserveArch)用の上限クランプ後に
    /// 端帯域のバイオレーションを再評価する。
    /// 通常は ±2% に制限するが、制限後も端で飛び出しが残る場合は ±5% まで拡張して飛び出しを防ぐ。
    nonisolated private static func resolveWindowDecision(
        samples: [DisparitySample],
        width w: Double,
        height h: Double,
        preserveArch: Bool,
        options: WindowOptimizationOptions
    ) -> StereoWindowDecision {
        let solved = IntelligentStereoWindow.solveOptimalHorizontalShift(samples: samples, imageWidth: w, imageHeight: h, options: options)
        let leftEdge = w * options.edgeBandRatio
        let rightEdge = w * (1.0 - options.edgeBandRatio)
        let topEdge = h * options.edgeBandRatio
        let bottomEdge = h * (1.0 - options.edgeBandRatio)
        let edgeSamples = samples.filter { $0.x <= leftEdge || $0.x >= rightEdge || $0.y <= topEdge || $0.y >= bottomEdge }
        func violates(_ tx: Double) -> Bool {
            edgeSamples.contains { $0.parallax + tx < -0.5 }
        }

        var tx = solved.optimalShiftX
        if preserveArch {
            func clamped(_ ratio: Double) -> Double {
                let m = w * ratio
                return min(m, max(-m, solved.optimalShiftX))
            }
            tx = clamped(0.020)
            // 2% 制限でも端で飛び出しが残る場合は、ウィンドウ適正化（立体窓の確保）を優先して上限を外す（安全上限 15%）
            if violates(tx) { tx = clamped(0.150) }
        }
        let delta = tx - solved.optimalShiftX
        let violation = violates(tx)
        let farShifted = solved.farShiftedParallax + delta
        let exceedsComfort = farShifted > options.maxComfortRatio * w + 0.5
        return StereoWindowDecision(
            optimalShiftX: tx,
            minShiftedParallax: solved.minShiftedParallax + delta,
            farShiftedParallax: farShifted,
            hasWindowViolationRisk: violation,
            requiresFloatingWindow: violation || exceedsComfort
        )
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

    /// 2D→3D 深度マップから視差サンプルを抽出し、ステレオウィンドウ違反を防ぐ最適 focusRatio を算出する
    nonisolated private static func computeDepthWindowSetup(
        disparityMap: [Float],
        depthW: Int,
        depthH: Int,
        imageWidth w: Int,
        imageHeight h: Int,
        targetDisparityPercent: Double,
        depthGamma: Double,
        saliencyMap: NormalizedFloatMap?,
        useSaliency: Bool,
        preserveArch: Bool
    ) -> (focusRatio: Double, samples: [DisparitySample], hasWindowViolationRisk: Bool, requiresFloatingWindow: Bool, dispRangePct: Double) {
        guard w > 0, h > 0, depthW > 0, depthH > 0, disparityMap.count >= depthW * depthH else {
            return (0.75, [], false, false, targetDisparityPercent)
        }

        let maxBaselinePx = Double(w) * max(0.2, min(8.0, targetDisparityPercent)) / 100.0
        let baseFocus = 0.5
        let cols = 32
        let rows = 24
        var gridPoints: [(x: Double, y: Double, d: Double, sal: Double)] = []
        gridPoints.reserveCapacity(cols * rows)

        for gy in 0..<rows {
            let v = 0.01 + 0.98 * Double(gy) / Double(rows - 1)
            let py = v * Double(h)
            for gx in 0..<cols {
                let u = 0.01 + 0.98 * Double(gx) / Double(cols - 1)
                let px = u * Double(w)
                let d = Double(ViewStereoDepthSynthesizer.sampleNormalizedDisparity(
                    disparityMap: disparityMap,
                    depthW: depthW,
                    depthH: depthH,
                    u: Float(u),
                    v: Float(v),
                    depthGamma: depthGamma
                ))
                let rawSal = saliencyMap?.sample(atPixelX: px, pixelY: py, imageWidth: Double(w), imageHeight: Double(h)) ?? 0.5
                let sal = useSaliency ? max(0.05, rawSal) : 0.5
                gridPoints.append((px, py, d, sal))
            }
        }

        let baseSamples = gridPoints.map { pt in
            DisparitySample(
                x: pt.x,
                y: pt.y,
                parallax: -(pt.d - baseFocus) * maxBaselinePx,
                saliency: pt.sal,
                foregroundWeight: 0.7
            )
        }

        let winOpts = makeWindowOptimizationOptions(preserveArch: preserveArch)
        let solved = resolveWindowDecision(
            samples: baseSamples,
            width: Double(w),
            height: Double(h),
            preserveArch: preserveArch,
            options: winOpts
        )

        var optFocus = min(1.0, max(0.0, baseFocus + solved.optimalShiftX / max(1.0, maxBaselinePx)))

        // 端帯域（edgeBandRatio）でウィンドウ飛び出しが残る場合は安全側（最大1.0=飛び出しゼロ）へ補正
        let edgeRatio = winOpts.edgeBandRatio
        let leftEdge = Double(w) * edgeRatio
        let rightEdge = Double(w) * (1.0 - edgeRatio)
        let topEdge = Double(h) * edgeRatio
        let bottomEdge = Double(h) * (1.0 - edgeRatio)
        let safeTol = 0.5 / max(1.0, maxBaselinePx)
        for pt in gridPoints where (pt.x <= leftEdge || pt.x >= rightEdge || pt.y <= topEdge || pt.y >= bottomEdge) {
            if pt.d - optFocus > safeTol {
                optFocus = min(1.0, max(optFocus, pt.d))
            }
        }

        let finalSamples = gridPoints.map { pt in
            DisparitySample(
                x: pt.x,
                y: pt.y,
                parallax: -(pt.d - optFocus) * maxBaselinePx,
                saliency: pt.sal,
                foregroundWeight: 0.7
            )
        }

        let erg = evaluateWindowErgonomics(
            samples: finalSamples,
            shiftX: 0.0,
            imageWidth: Double(w),
            imageHeight: Double(h),
            cropWidth: w
        )
        return (optFocus, finalSamples, erg.hasWindowViolationRisk, erg.requiresFloatingWindow, erg.dispRangePct)
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
        let cardCfg = appliedCardMountConfig
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
        guard isAligned else { return }

        if lastRectResult == nil && stereoReconstructionMode.isDepthSynthesized {
            guard let rL = rectifiedPreviewLeftRGB,
                  let rR = rectifiedPreviewRightRGB,
                  rectifiedPreviewWidth > 0,
                  rectifiedPreviewHeight > 0,
                  cachedBaseW > 0,
                  cachedBaseH > 0 else {
                return
            }
            let rw = rectifiedPreviewWidth
            let rh = rectifiedPreviewHeight
            let tx = windowShiftX
            let sx = Double(rw) / Double(cachedBaseW)
            let dxL = Int((-0.5 * tx * sx).rounded())
            let dxR = Int((+0.5 * tx * sx).rounded())
            let startX = max(0, max(dxL, dxR))
            let endX = min(rw, min(rw + dxL, rw + dxR))
            let cropW = endX - startX
            guard cropW >= 16 else { return }

            let srcXL = startX - dxL
            let srcXR = startX - dxR
            let sl = Self.cropHorizontalSlice(rL, srcW: rw, height: rh, srcX: srcXL, cropW: cropW)
            let sr = Self.cropHorizontalSlice(rR, srcW: rw, height: rh, srcX: srcXR, cropW: cropW)

            let fullDxL = Int((-0.5 * tx).rounded())
            let fullDxR = Int((+0.5 * tx).rounded())
            let fullStartX = max(0, max(fullDxL, fullDxR))
            let fullEndX = min(cachedBaseW, min(cachedBaseW + fullDxL, cachedBaseW + fullDxR))
            let fullCW = max(16, fullEndX - fullStartX)

            previewAlignedLeftRGB = sl
            previewAlignedRightRGB = sr
            previewCroppedWidth = cropW
            previewCroppedHeight = rh
            croppedWidth = fullCW
            croppedHeight = cachedBaseH

            let erg = Self.evaluateWindowErgonomics(
                samples: lastDisparitySamples,
                shiftX: tx,
                imageWidth: Double(cachedBaseW),
                imageHeight: Double(cachedBaseH),
                cropWidth: fullCW
            )
            hasWindowViolationRisk = erg.hasWindowViolationRisk
            requiresFloatingWindow = erg.requiresFloatingWindow
            maxDisparityPercent = erg.dispRangePct
            renderDisplayPreview()
            return
        }

        guard let rectRes = lastRectResult,
              let pL = previewRawLeftRGB,
              let pR = previewRawRightRGB,
              let renderer = metalRenderer else {
            return
        }

        let w = imageWidth, h = imageHeight
        let pw = previewWidth, ph = previewHeight
        let preserveArch = hasPreservedArch
        let rawTx = windowShiftX
        let maxArchShift = Double(w) * 0.150
        let tx = preserveArch ? min(maxArchShift, max(-maxArchShift, rawTx)) : rawTx
        let keepAR = keepOriginalAspectRatio
        let samples = lastDisparitySamples
        let mode = displayMode
        let style = frameStyle
        let swapped = isSwapped
        let cardCfg = appliedCardMountConfig
        let mountCtx = currentMountContext
        let restOpts = makeVintageRestorationOptions()
        let detailOpts = makeDetailRestorationOptions()
        let colorOpts = makeColorizationOptions()
        let colorMode = autoColorMode
        let removeNoise = effectiveRemoveUnilateralNoise

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
                if !restOpts.isIdentity || !detailOpts.isIdentity || !colorOpts.isIdentity {
                    if !detailOpts.isIdentity {
                        await MainActor.run {
                            if self.previewRenderGeneration == gen {
                                self.restorationProgress = 0.35
                                self.restorationProgressMessage = String(localized: "Applying AI optical deblur (NAFNet)...")
                            }
                        }
                    } else if !colorOpts.isIdentity {
                        await MainActor.run {
                            if self.previewRenderGeneration == gen {
                                self.restorationProgress = 0.35
                                self.restorationProgressMessage = String(localized: "Colorizing stereo pair...")
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
                        colorOptions: colorOpts,
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
        let removeNoise = effectiveRemoveUnilateralNoise
        let colorMode = autoColorMode
        if abs(windowShiftX - lastFullResShiftX) <= 1e-4,
           lastFullResRemoveNoise == removeNoise,
           alignedLeftRGB != nil,
           alignedRightRGB != nil {
            return true
        }
        if lastRectResult == nil && stereoReconstructionMode.isDepthSynthesized {
            guard let fullL = cachedSynthFullLeftRGB,
                  let fullR = cachedSynthFullRightRGB,
                  cachedBaseW > 0,
                  cachedBaseH > 0 else {
                return false
            }
            let w = cachedBaseW
            let h = cachedBaseH
            let tx = windowShiftX
            let dxL = Int((-0.5 * tx).rounded())
            let dxR = Int((+0.5 * tx).rounded())
            let startX = max(0, max(dxL, dxR))
            let endX = min(w, min(w + dxL, w + dxR))
            let cropW = endX - startX
            guard cropW >= 16 else { return false }

            if cropW == w && dxL == 0 && dxR == 0 {
                alignedLeftRGB = fullL
                alignedRightRGB = fullR
                croppedWidth = w
                croppedHeight = h
            } else {
                let srcXL = startX - dxL
                let srcXR = startX - dxR
                let (sl, sr) = await Task.detached(priority: .userInitiated) {
                    (
                        Self.cropHorizontalSlice(fullL, srcW: w, height: h, srcX: srcXL, cropW: cropW),
                        Self.cropHorizontalSlice(fullR, srcW: w, height: h, srcX: srcXR, cropW: cropW)
                    )
                }.value
                alignedLeftRGB = sl
                alignedRightRGB = sr
                croppedWidth = cropW
                croppedHeight = h
            }
            lastFullResShiftX = tx
            lastFullResRemoveNoise = removeNoise
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
        let maxArchShift = Double(w) * 0.150
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
        let cardCfg = appliedCardMountConfig
        let mountCtx = currentMountContext
        let restOpts = makeVintageRestorationOptions()
        let detailOpts = makeDetailRestorationOptions()
        let colorOpts = makeColorizationOptions()
        previewRenderGeneration += 1
        let gen = previewRenderGeneration
        let showHeavyProgress = !detailOpts.isIdentity || !colorOpts.isIdentity
        if showHeavyProgress {
            isRestoringPreview = true
            restorationProgress = 0.06
            restorationProgressMessage = !detailOpts.isIdentity
                ? String(localized: "Applying AI optical deblur (NAFNet)...")
                : String(localized: "Colorizing stereo pair...")
        }

        Task {
            let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                var dispL = l
                var dispR = r
                if !restOpts.isIdentity || !detailOpts.isIdentity || !colorOpts.isIdentity {
                    let restored = Self.applyVintagePipeline(
                        left: dispL,
                        right: dispR,
                        width: w,
                        height: h,
                        toneOptions: restOpts,
                        detailOptions: detailOpts,
                        colorOptions: colorOpts,
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
        if isVideoLoaded {
            exportVideo(toQuickOutput: false)
            return
        }
        guard hasLoadedImages else { return }
        let layout = exportLayout
        let imgFormat = exportImageFormat
        let style = frameStyle
        let swapped = isSwapped
        let cardCfg = appliedCardMountConfig
        let mountCtx = currentMountContext
        let restOpts = makeVintageRestorationOptions(ignorePreviewToggle: true)
        let detailOpts = makeDetailRestorationOptions(ignorePreviewToggle: true)
        let colorOpts = makeColorizationOptions(ignorePreviewToggle: true)
        let ext = imgFormat.fileExtension

        if layout == .separateLR {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export L/R Here"
            if panel.runModal() == .OK, let dir = panel.url {
                let rawBase = leftURL?.deletingPathExtension().lastPathComponent ?? "stereo"
                let base = stereoReconstructionMode.isDepthSynthesized ? "\(rawBase)_2D3D" : rawBase
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
                            colorOptions: colorOpts,
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
        let rawBase = leftURL?.deletingPathExtension().lastPathComponent ?? "ViewStereo_Output"
        let base = stereoReconstructionMode.isDepthSynthesized ? "\(rawBase)_2D3D" : rawBase
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
                        colorOptions: colorOpts,
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
        Auto-Swap       : \(isSwapped ? "Applied (Left <-> Right swapped for pseudoscopic correction)" : "None")
        Stereo Status   : \(stereoReportText)
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

    /// 作業フォルダ内の出力先（ViewStereo_Output）へダイアログなしで即座に書き出す
    func quickExportToWorkspaceOutput() {
        if isVideoLoaded {
            exportVideo(toQuickOutput: true)
            return
        }
        guard hasLoadedImages, !isProcessing, !isBatchRunning else { return }
        let baseDir: URL
        if let out = batchOutputFolder, !isTemporaryLocation(out) {
            baseDir = out
        } else if browserStore.isVirtualSelection || leftURL.map(isTemporaryLocation) == true {
            guard let chosen = promptOutputFolderForSelection() else {
                statusMessage = String(localized: "Export cancelled (no output folder selected).")
                return
            }
            baseDir = chosen
        } else if let root = workspaceRootFolder {
            baseDir = root.appendingPathComponent("ViewStereo_Output", isDirectory: true)
        } else if let leftParent = leftURL?.deletingLastPathComponent() {
            baseDir = leftParent.appendingPathComponent("ViewStereo_Output", isDirectory: true)
        } else {
            exportImage()
            return
        }

        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        } catch {
            statusMessage = "Failed to create output folder."
            return
        }

        let layout = exportLayout
        let imgFormat = exportImageFormat
        let style = frameStyle
        let swapped = isSwapped
        let cardCfg = makeCardMountConfig()
        let mountCtx = currentMountContext
        let restOpts = isRestorationEnabled ? buildPendingVintageRestorationOptions() : VintageRestorationOptions()
        let detailOpts = isRestorationEnabled ? buildPendingDetailRestorationOptions() : StereoDetailRestorationOptions(deblurStrength: 0.0, textureProtection: 0.60)
        let colorOpts = buildPendingColorizationOptions()
        let ext = imgFormat.fileExtension
        let rawBase = leftURL?.deletingPathExtension().lastPathComponent ?? "ViewStereo_Output"
        let base = stereoReconstructionMode.isDepthSynthesized ? "\(rawBase)_2D3D" : rawBase
        let activeID = workspaceActiveItemID

        isProcessing = true
        statusMessage = "Quick exporting to \(baseDir.lastPathComponent)/..."

        Task {
            if isAligned {
                _ = await ensureFullResAlignedSynced()
            }
            guard let lRaw = activeLeftRGB, let rRaw = activeRightRGB else {
                isProcessing = false
                statusMessage = "Quick export failed."
                return
            }
            let w = activeWidth, h = activeHeight
            let ok: Bool
            if layout == .separateLR {
                let outL = baseDir.appendingPathComponent("\(base)_L.\(ext)")
                let outR = baseDir.appendingPathComponent("\(base)_R.\(ext)")
                ok = await Task.detached(priority: .userInitiated) {
                    Self.renderAndSaveSeparateLR(
                        left: swapped ? rRaw : lRaw,
                        right: swapped ? lRaw : rRaw,
                        width: w, height: h,
                        style: style, imageFormat: imgFormat,
                        restorationOptions: restOpts,
                        detailOptions: detailOpts,
                        colorOptions: colorOpts,
                        outL: outL, outR: outR
                    )
                }.value
            } else {
                let suffix: String
                let targetExt: String
                switch layout {
                case .twoD: suffix = "_2D"; targetExt = ext
                case .sbs: suffix = "_SBS"; targetExt = ext
                case .lrrl: suffix = "_LRRL"; targetExt = ext
                case .dubois: suffix = "_Dubois"; targetExt = ext
                case .colorAnaglyph: suffix = "_ColorAnaglyph"; targetExt = ext
                case .grayAnaglyph: suffix = "_GrayAnaglyph"; targetExt = ext
                case .polarized: suffix = "_Polarized"; targetExt = ext
                case .stereoviewCard: suffix = "_Card"; targetExt = ext
                case .spatialPhoto: suffix = "_Spatial"; targetExt = "heic"
                case .mpo: suffix = ""; targetExt = "mpo"
                case .separateLR: suffix = ""; targetExt = ext
                }
                let outURL = baseDir.appendingPathComponent("\(base)\(suffix).\(targetExt)")
                ok = await Task.detached(priority: .userInitiated) {
                    Self.renderAndSaveSingleFile(
                        left: lRaw, right: rRaw, width: w, height: h,
                        style: style, layout: layout, imageFormat: imgFormat, isSwapped: swapped,
                        cardConfig: cardCfg, mountContext: mountCtx,
                        restorationOptions: restOpts,
                        detailOptions: detailOpts,
                        colorOptions: colorOpts,
                        to: outURL
                    )
                }.value
            }
            isProcessing = false
            if ok {
                statusMessage = "Quick exported \(base) → \(baseDir.lastPathComponent)/"
                if let activeID {
                    workspaceItemStatuses[activeID] = .completed
                }
                refreshWorkspaceBrowser()
            } else {
                statusMessage = "Quick export failed."
            }
        }
    }

    // MARK: - Workspace File Browser Management

    func presentStartupFolderPromptIfNeeded(in window: NSWindow?) {
        guard !hasHandledStartupWorkspacePrompt else { return }
        hasHandledStartupWorkspacePrompt = true

        let settings = ViewStereoSettings.shared
        switch settings.startupFolderAction {
        case .doNothing:
            return
        case .reopenLastFolder:
            if let lastPath = settings.lastWorkspaceFolderPath,
               FileManager.default.fileExists(atPath: lastPath) {
                setWorkspaceRootFolder(URL(fileURLWithPath: lastPath, isDirectory: true))
                return
            }
            openWorkspaceFolderPanel(in: window)
        case .showSheet:
            openWorkspaceFolderPanel(in: window)
        }
    }

    func openWorkspaceFolderPanel(in window: NSWindow? = nil, initialMode: ViewStereoWorkspaceMode? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "Open Workspace Folder")
        panel.message = String(localized: "Select a working folder and choose the processing mode.")
        if let lastPath = ViewStereoSettings.shared.lastWorkspaceFolderPath,
           FileManager.default.fileExists(atPath: lastPath) {
            panel.directoryURL = URL(fileURLWithPath: lastPath, isDirectory: true)
        } else if let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
            panel.directoryURL = pics
        }

        let modeSelection = WorkspacePanelModeSelection(selectedMode: initialMode ?? workspaceMode)
        let accessoryHost = NSHostingView(rootView: WorkspacePanelModeAccessoryView(selection: modeSelection))
        accessoryHost.frame = NSRect(origin: .zero, size: accessoryHost.fittingSize)
        panel.accessoryView = accessoryHost
        panel.isAccessoryViewDisclosed = true

        let handleResult: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .OK, let dir = panel.url {
                if self.workspaceMode != modeSelection.selectedMode {
                    self.workspaceMode = modeSelection.selectedMode
                }
                self.setWorkspaceRootFolder(dir)
                self.isShowingFileBrowser = true
            }
        }

        if let win = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: win, completionHandler: handleResult)
        } else {
            handleResult(panel.runModal())
        }
    }

    func setWorkspaceRootFolder(_ folder: URL) {
        let stdFolder = folder.standardizedFileURL
        let outDir = stdFolder.appendingPathComponent("ViewStereo_Output", isDirectory: true)
        batchInputFolder = stdFolder
        batchOutputFolder = outDir
        ViewStereoSettings.shared.recordWorkspaceFolder(stdFolder)
        browserStore.setRootFolder(
            stdFolder,
            pairingMode: effectiveBrowserPairingMode,
            outputFolder: outDir,
            includeSubfolders: batchIncludeSubfolders
        )
        statusMessage = "Workspace: \(stdFolder.lastPathComponent)"
    }

    func refreshWorkspaceBrowser() {
        browserStore.configureOptions(
            pairingMode: effectiveBrowserPairingMode,
            includeSubfolders: batchIncludeSubfolders,
            outputFolder: batchOutputFolder
        )
        browserStore.refreshAsync()
    }

    func openBrowserItem(_ item: StereoBatchItem) {
        guard !isBatchRunning && !isExportingVideo else { return }
        if item.isVideo {
            loadVideo(url: item.leftURL)
            return
        }
        if let rURL = item.rightURL {
            loadSeparateImages(left: item.leftURL, right: rURL)
        } else {
            loadSingleSBSImage(url: item.leftURL)
        }
    }

    func twoSelectedUnpairedFiles() -> (URL, URL)? {
        browserStore.twoSelectedUnpairedFiles()
    }

    func openTwoSelectedAsLRPair() {
        guard !isBatchRunning,
              let (l, r) = twoSelectedUnpairedFiles() else { return }
        loadSeparateImages(left: l, right: r)
    }

    func resolveSelectedBatchItems() -> [StereoBatchItem] {
        browserStore.resolveBatchItems()
    }

    func startBatchProcessingFromBrowser() {
        let items = resolveSelectedBatchItems()
        guard !items.isEmpty else {
            statusMessage = String(localized: "No stereo images found in selection.")
            return
        }
        let targetDir = workspaceRootFolder ?? items[0].leftURL.deletingLastPathComponent()
        startBatchProcessing(inputDir: targetDir, itemsOverride: items, verifyOnly: false)
    }

    func startStereoVerificationFromBrowser() {
        let items = resolveSelectedBatchItems()
        guard !items.isEmpty else {
            statusMessage = String(localized: "No stereo images found in selection.")
            return
        }
        let targetDir = workspaceRootFolder ?? items[0].leftURL.deletingLastPathComponent()
        startBatchProcessing(inputDir: targetDir, itemsOverride: items, verifyOnly: true)
    }

    /// 現在のブラウザで展開・表示中の全ファイル項目を選択する
    func selectAllBrowserFiles() {
        browserStore.selectAllVisibleFiles()
    }

    func deselectAllBrowserNodes() {
        browserStore.deselectAll()
    }

    // MARK: - Folder Batch Auto-Alignment

    func openBatchFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder for Batch"
        if panel.runModal() == .OK, let dir = panel.url {
            prepareBatchQueue(folder: dir)
        }
    }

    func chooseBatchOutputFolderPanel() {
        _ = promptOutputFolderForSelection()
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

    func startBatchProcessing(inputDir: URL? = nil, itemsOverride: [StereoBatchItem]? = nil, verifyOnly: Bool = false) {
        guard !isBatchRunning else { return }
        let targetDir = inputDir ?? batchInputFolder ?? workspaceRootFolder ?? itemsOverride?.first?.leftURL.deletingLastPathComponent()
        guard let targetDir else {
            openWorkspaceFolderPanel()
            return
        }

        if browserStore.isVirtualSelection && !verifyOnly {
            let needsPrompt = (batchOutputFolder == nil) || batchOutputFolder.map(isTemporaryLocation) == true
            if needsPrompt {
                guard promptOutputFolderForSelection() != nil else {
                    statusMessage = String(localized: "Export cancelled (no output folder selected).")
                    return
                }
            }
        }

        let outDir = batchOutputFolder ?? targetDir.appendingPathComponent("ViewStereo_Output", isDirectory: true)
        if !browserStore.isVirtualSelection {
            batchInputFolder = targetDir
        }
        batchOutputFolder = outDir

        let pairingMode = effectiveBrowserPairingMode
        let rawItems: [StereoBatchItem]
        if let itemsOverride {
            rawItems = itemsOverride
        } else if !batchQueueItems.isEmpty && (inputDir == nil || inputDir == batchInputFolder) {
            rawItems = batchQueueItems
        } else {
            rawItems = WorkspaceScanner.collectBatchItems(
                from: [],
                rootFolder: targetDir,
                pairingMode: pairingMode,
                includeSubfolders: batchIncludeSubfolders,
                customOutputFolder: outDir
            )
        }
        let items = rawItems.filter { !$0.isVideo }
        guard !items.isEmpty else {
            statusMessage = "No stereo images found in \(targetDir.lastPathComponent)."
            return
        }

        // 未適用（Pending）のスライダーや設定もバッチ実行時に確実に反映する
        if hasLoadedImages {
            appliedRecipeConfig = currentRecipeConfig
            appliedCardMountConfig = makeCardMountConfig()
        }
        let restOpts = isRestorationEnabled ? buildPendingVintageRestorationOptions() : VintageRestorationOptions()
        let detailOpts = isRestorationEnabled ? buildPendingDetailRestorationOptions() : StereoDetailRestorationOptions(deblurStrength: 0.0, textureProtection: 0.60)
        let colorOpts = buildPendingColorizationOptions()

        let useMask = usePersonMotionMask
        let useSaliency = useAttentionSaliency
        let keepAR = keepOriginalAspectRatio
        let colorMode = autoColorMode
        let removeNoise = effectiveRemoveUnilateralNoise
        let cardMode = stereoCardMode
        let useCoreML = useCoreMLCardSegmentation
        let style = frameStyle
        let layout = exportLayout
        let imgFormat = exportImageFormat
        let swapped = isSwapped
        let autoSwapPseudo = ViewStereoSettings.shared.autoSwapPseudoscopic
        let saveReport = batchSaveReport
        let isDedicated2D3D = (workspaceMode == .convert2DTo3D)
        let warningPolicy: BatchWarningPolicy = isDedicated2D3D ? .exportAll : batchWarningPolicy
        let interp: StereoInputInterpretation = isDedicated2D3D ? .force2D : inputInterpretation
        let preferredEngine = ViewStereoSettings.shared.preferredDepthEngine
        let targetDispPct = virtualDepthBasePercent
        let gamma = depthGamma
        let releaseAfterBatch = ViewStereoSettings.shared.releaseAIModelsAfterGeneration
        if cardTextMode != .manualTypeset {
            clearCardMountTexts()
        }
        let baseCardCfg = makeCardMountConfig()
        let renderer = metalRenderer

        isBatchQueueActive = false
        isBatchVerifyOnly = verifyOnly
        isBatchRunning = true
        batchCompletionSummary = nil
        batchTotalCount = items.count
        batchCompletedCount = 0
        batchFailedCount = 0
        verifyWarningCount = 0
        batchProgress = 0.0
        batchCurrentFile = ""
        statusMessage = verifyOnly ? "Stereo verification starting (\(items.count) items)..." : "Batch starting (\(items.count) items)..."

        batchTask = Task {
            if !verifyOnly {
                do {
                    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                } catch {
                    isBatchRunning = false
                    statusMessage = "Failed to create output folder."
                    return
                }
            }

            enum BatchStepOutcome: Sendable {
                case alignedSuccess(AlignmentPipelineOutput, Int, Int, Bool, StereoCardSegmenter.OriginalCardMountContext?, StereoCardMountConfig)
                case aiConverted2D3D(left: [UInt8], right: [UInt8], width: Int, height: Int, is2DSource: Bool, preservedArch: Bool, mountCtx: StereoCardSegmenter.OriginalCardMountContext?, cardCfg: StereoCardMountConfig)
                case skippedWarning(String)
                case skippedClean
                case failed(String)
            }

            var successCnt = 0
            var failCnt = 0
            var warnCnt = 0

            for (idx, item) in items.enumerated() {
                if Task.isCancelled { break }
                batchCurrentFile = item.displayLabel

                // 事前ステレオ検証済みの結果がキャッシュされている場合、対象外アイテムを高速スキップ
                let cachedStatus = workspaceItemStatuses[item.id]
                if !verifyOnly, let cachedStatus {
                    if warningPolicy == .skipWarnings && cachedStatus.isWarningOrError {
                        batchCompletedCount = idx + 1
                        batchProgress = Double(idx + 1) / Double(items.count)
                        continue
                    }
                    if warningPolicy == .onlyConvertWarningsTo3D && cachedStatus == .completed {
                        batchCompletedCount = idx + 1
                        batchProgress = Double(idx + 1) / Double(items.count)
                        continue
                    }
                }

                workspaceItemStatuses[item.id] = .processing
                statusMessage = verifyOnly
                    ? "Verifying [\(idx + 1)/\(items.count)]: \(item.displayLabel)"
                    : "Batch [\(idx + 1)/\(items.count)]: \(item.displayLabel)"

                let stepOutcome = await Task.detached(priority: .userInitiated) { () -> BatchStepOutcome in
                    guard let loaded = Self.loadBatchPair(item: item, cardMode: cardMode, useCoreML: useCoreML, interpretation: interp) else {
                        return .failed("Failed to load image")
                    }
                    let lRGB = loaded.left
                    let rRGB = loaded.right
                    let w = loaded.width
                    let h = loaded.height
                    let preservedArch = loaded.preservedArch
                    let mountCtx = loaded.mountContext

                    var itemCardCfg = baseCardCfg
                    itemCardCfg.sourceFilename = item.leftURL.lastPathComponent
                    itemCardCfg.preservedArchFromAI = preservedArch

                    // A. 通常の 2D 写真と判定された場合
                    if loaded.is2DPhoto {
                        if !verifyOnly && warningPolicy == .onlyConvertWarningsTo3D {
                            return .skippedClean
                        }
                        let synth = ViewStereoDepthSynthesizer.shared
                        guard let depthRes = synth.estimateDisparity(
                            rgb: lRGB, width: w, height: h,
                            preferredEngine: preferredEngine, releaseAfterInference: false
                        ) else {
                            return .failed("Depth estimation failed")
                        }
                        var salMap: NormalizedFloatMap? = nil
                        if useSaliency,
                           let cgImg = ViewStereoDepthSynthesizer.createCGImage(from: lRGB, width: w, height: h) {
                            salMap = try? VisionAnalyzer.extractAttentionSaliency(from: cgImg)
                        }
                        let winSetup = Self.computeDepthWindowSetup(
                            disparityMap: depthRes.disparity,
                            depthW: depthRes.width,
                            depthH: depthRes.height,
                            imageWidth: w,
                            imageHeight: h,
                            targetDisparityPercent: targetDispPct,
                            depthGamma: gamma,
                            saliencyMap: salMap,
                            useSaliency: useSaliency,
                            preserveArch: false
                        )
                        let (fullL, fullR) = synth.synthesizeStereoPair(
                            baseRGB: lRGB, width: w, height: h,
                            disparityMap: depthRes.disparity, depthW: depthRes.width, depthH: depthRes.height,
                            targetDisparityPercent: targetDispPct, depthGamma: gamma,
                            focusRatio: winSetup.focusRatio
                        )
                        if verifyOnly {
                            return .aiConverted2D3D(left: fullL, right: fullR, width: w, height: h, is2DSource: true, preservedArch: false, mountCtx: nil, cardCfg: itemCardCfg)
                        }
                        let savedOK = Self.saveBatchRGBPair(
                            left: fullL, right: fullR, width: w, height: h,
                            baseName: "\(item.baseName)_2D3D",
                            item: item, srcWidth: w, srcHeight: h, outDir: outDir,
                            layout: layout, imageFormat: imgFormat, isSwapped: false,
                            frameStyle: style, cardConfig: itemCardCfg, mountContext: nil,
                            restorationOptions: restOpts, detailOptions: detailOpts, colorOptions: colorOpts,
                            saveReport: saveReport, alignmentOutput: nil
                        )
                        return savedOK
                            ? .aiConverted2D3D(left: fullL, right: fullR, width: w, height: h, is2DSource: true, preservedArch: false, mountCtx: nil, cardCfg: itemCardCfg)
                            : .failed("Failed to save output")
                    }

                    // B. ステレオ画像（カード / SBS / L+Rペア）
                    let res = Self.executeAlignmentPipeline(
                        lRGB: lRGB, rRGB: rRGB, width: w, height: h,
                        useMask: useMask, useSaliency: useSaliency, keepAR: keepAR,
                        colorMode: colorMode, removeNoise: removeNoise, preserveArch: preservedArch,
                        renderer: renderer
                    )

                    // ヘルパー：片側から AI 2D-3D サルベージして保存
                    func salvageTo2D3D(preferredSide: StereoSingleEyeSide, samples: [DisparitySample] = []) -> BatchStepOutcome {
                        let baseRGB = (preferredSide == .left) ? lRGB : rRGB
                        let synth = ViewStereoDepthSynthesizer.shared
                        guard let depthRes = synth.estimateDisparity(
                            rgb: baseRGB, width: w, height: h,
                            preferredEngine: preferredEngine, releaseAfterInference: false
                        ) else {
                            return .failed("Depth estimation failed")
                        }
                        var dispMap = depthRes.disparity
                        if !samples.isEmpty {
                            dispMap = ViewStereoDepthSynthesizer.calibrateWithSparseStereo(
                                disparityMap: dispMap, depthW: depthRes.width, depthH: depthRes.height,
                                sparseSamples: samples, imageWidth: Double(w), imageHeight: Double(h)
                            )
                        }
                        var salMap: NormalizedFloatMap? = nil
                        if useSaliency,
                           let cgImg = ViewStereoDepthSynthesizer.createCGImage(from: baseRGB, width: w, height: h) {
                            salMap = try? VisionAnalyzer.extractAttentionSaliency(from: cgImg)
                        }
                        let winSetup = Self.computeDepthWindowSetup(
                            disparityMap: dispMap,
                            depthW: depthRes.width,
                            depthH: depthRes.height,
                            imageWidth: w,
                            imageHeight: h,
                            targetDisparityPercent: targetDispPct,
                            depthGamma: gamma,
                            saliencyMap: salMap,
                            useSaliency: useSaliency,
                            preserveArch: preservedArch
                        )
                        let (fullL, fullR) = synth.synthesizeStereoPair(
                            baseRGB: baseRGB, width: w, height: h,
                            disparityMap: dispMap, depthW: depthRes.width, depthH: depthRes.height,
                            targetDisparityPercent: targetDispPct, depthGamma: gamma,
                            focusRatio: winSetup.focusRatio
                        )
                        let savedOK = Self.saveBatchRGBPair(
                            left: fullL, right: fullR, width: w, height: h,
                            baseName: "\(item.baseName)_2D3D",
                            item: item, srcWidth: w, srcHeight: h, outDir: outDir,
                            layout: layout, imageFormat: imgFormat, isSwapped: false,
                            frameStyle: style, cardConfig: itemCardCfg, mountContext: mountCtx,
                            restorationOptions: restOpts, detailOptions: detailOpts, colorOptions: colorOpts,
                            saveReport: saveReport, alignmentOutput: nil
                        )
                        return savedOK
                            ? .aiConverted2D3D(left: fullL, right: fullR, width: w, height: h, is2DSource: false, preservedArch: preservedArch, mountCtx: mountCtx, cardCfg: itemCardCfg)
                            : .failed("Failed to save 2D-3D output")
                    }

                    switch res {
                    case .failure(let err):
                        let errMsg = "Alignment failed (\(err))"
                        if verifyOnly {
                            return .failed(errMsg)
                        }
                        switch warningPolicy {
                        case .exportAll, .skipWarnings:
                            return .failed(errMsg)
                        case .convertWarningsTo3D, .onlyConvertWarningsTo3D:
                            if layout == .stereoviewCard && itemCardCfg.textMode == .ocrAuto, let ctx = mountCtx {
                                let rec = await StereoCardMountRenderer.recognizeTextsFromOriginalMount(ctx: ctx)
                                itemCardCfg.bottomCaption = rec.bottomCaption
                                itemCardCfg.topCenterText = rec.topCenter
                                itemCardCfg.leftMarginText = rec.leftMargin
                                itemCardCfg.rightMarginText = rec.rightMargin
                            }
                            let dmg = Self.evaluateUnilateralDamage(leftRGB: lRGB, rightRGB: rRGB, width: w, height: h)
                            let side: StereoSingleEyeSide = (dmg.damagedSide == .left) ? .right : (dmg.damagedSide == .right ? .left : (dmg.leftSharp >= dmg.rightSharp ? .left : .right))
                            return salvageTo2D3D(preferredSide: side)
                        }

                    case .success(let out):
                        if layout == .stereoviewCard && itemCardCfg.textMode == .ocrAuto, let ctx = mountCtx {
                            let rec = await StereoCardMountRenderer.recognizeTextsFromOriginalMount(ctx: ctx)
                            itemCardCfg.bottomCaption = rec.bottomCaption
                            itemCardCfg.topCenterText = rec.topCenter
                            itemCardCfg.leftMarginText = rec.leftMargin
                            itemCardCfg.rightMarginText = rec.rightMargin
                        }
                        if verifyOnly {
                            return .alignedSuccess(out, w, h, preservedArch, mountCtx, itemCardCfg)
                        }

                        let hasWarning = (out.stereoQualityWarning != nil) || out.salvageAdvisory.shouldShowSalvagePrompt
                        if hasWarning {
                            let warnMsg = out.stereoQualityWarning
                                ?? (out.salvageAdvisory.isMismatchSuspected ? String(localized: "Stereo Mismatch Detected")
                                    : (out.salvageAdvisory.isUnilateralDamageSuspected ? String(localized: "Unilateral Damage Detected")
                                        : String(localized: "Excessive Stereo Baseline")))
                            switch warningPolicy {
                            case .skipWarnings:
                                return .skippedWarning(warnMsg)
                            case .convertWarningsTo3D, .onlyConvertWarningsTo3D:
                                return salvageTo2D3D(preferredSide: out.salvageAdvisory.suggestedSide, samples: out.samples)
                            case .exportAll:
                                break
                            }
                        } else if warningPolicy == .onlyConvertWarningsTo3D {
                            return .skippedClean
                        }

                        // 通常 True Stereo 書き出し
                        let itemSwapped = (out.isPseudoscopicSuspected && autoSwapPseudo) ? true : swapped
                        let savedOK = Self.saveBatchOutput(
                            out: out, item: item, srcWidth: w, srcHeight: h, outDir: outDir,
                            layout: layout, imageFormat: imgFormat, isSwapped: itemSwapped,
                            frameStyle: style, cardConfig: itemCardCfg, mountContext: mountCtx,
                            restorationOptions: restOpts, detailOptions: detailOpts, colorOptions: colorOpts,
                            saveReport: saveReport
                        )
                        return savedOK
                            ? .alignedSuccess(out, w, h, preservedArch, mountCtx, itemCardCfg)
                            : .failed("Failed to save output")
                    }
                }.value

                if Task.isCancelled { break }

                switch stepOutcome {
                case .alignedSuccess(let out, let w, let h, let preservedArch, let mountCtx, let itemCfg):
                    successCnt += 1
                    workspaceActiveItemID = item.id
                    leftURL = item.leftURL
                    rightURL = item.rightURL ?? item.leftURL
                    isSingleSBSInput = (item.rightURL == nil)
                    hasPreservedArch = preservedArch
                    currentMountContext = mountCtx
                    if !verifyOnly && baseCardCfg.textMode == .ocrAuto {
                        cardBottomCaption = itemCfg.bottomCaption
                        cardTopCenterText = itemCfg.topCenterText
                        cardLeftMarginText = itemCfg.leftMarginText
                        cardRightMarginText = itemCfg.rightMarginText
                    }
                    imageWidth = w
                    imageHeight = h
                    isSwapped = swapped
                    applyAlignmentOutput(out)

                    if out.stereoQualityWarning != nil || out.salvageAdvisory.shouldShowSalvagePrompt {
                        warnCnt += 1
                        let warnMsg = out.stereoQualityWarning
                            ?? (out.salvageAdvisory.isMismatchSuspected ? String(localized: "Stereo Mismatch Detected")
                                : (out.salvageAdvisory.isUnilateralDamageSuspected ? String(localized: "Unilateral Damage Detected")
                                    : String(localized: "Excessive Stereo Baseline")))
                        workspaceItemStatuses[item.id] = .warning(warnMsg)
                    }

                case .aiConverted2D3D(let fullL, let fullR, let w, let h, let is2DSource, let preservedArch, let mountCtx, let itemCfg):
                    successCnt += 1
                    workspaceActiveItemID = item.id
                    leftURL = item.leftURL
                    rightURL = item.rightURL ?? item.leftURL
                    isSingleSBSInput = false
                    hasPreservedArch = preservedArch
                    currentMountContext = mountCtx
                    if baseCardCfg.textMode == .ocrAuto {
                        cardBottomCaption = itemCfg.bottomCaption
                        cardTopCenterText = itemCfg.topCenterText
                        cardLeftMarginText = itemCfg.leftMarginText
                        cardRightMarginText = itemCfg.rightMarginText
                    }
                    let (pL, pw, ph) = Self.downsampleForPreview(fullL, width: w, height: h, maxDim: Self.previewMaxDimension)
                    let (pR, _, _) = Self.downsampleForPreview(fullR, width: w, height: h, maxDim: Self.previewMaxDimension)
                    rawLeftRGB = fullL
                    rawRightRGB = fullR
                    alignedLeftRGB = fullL
                    alignedRightRGB = fullR
                    previewRawLeftRGB = pL
                    previewRawRightRGB = pR
                    previewAlignedLeftRGB = pL
                    previewAlignedRightRGB = pR
                    rectifiedPreviewLeftRGB = pL
                    rectifiedPreviewRightRGB = pR
                    imageWidth = w
                    imageHeight = h
                    croppedWidth = w
                    croppedHeight = h
                    previewWidth = pw
                    previewHeight = ph
                    previewCroppedWidth = pw
                    previewCroppedHeight = ph
                    rectifiedPreviewWidth = pw
                    rectifiedPreviewHeight = ph
                    isAligned = true
                    stereoReconstructionMode = is2DSource ? .fullFrame2DDepth : .singleEyeDepth(.left)
                    salvageAdvisory = nil
                    isStereoMismatchSuspected = false
                    isPseudoscopicSuspected = false
                    stereoQualityWarning = nil
                    isSwapped = false
                    workspaceItemStatuses[item.id] = .aiConverted(is2DSource ? "2D→3D" : "AI 3D")
                    renderDisplayPreview()

                case .skippedWarning(let warnMsg):
                    warnCnt += 1
                    workspaceItemStatuses[item.id] = .warning(warnMsg)

                case .skippedClean:
                    if cachedStatus == nil {
                        workspaceItemStatuses[item.id] = .completed
                    }

                case .failed(let msg):
                    failCnt += 1
                    workspaceItemStatuses[item.id] = .failed(msg)
                }

                batchCompletedCount = idx + 1
                batchFailedCount = failCnt
                verifyWarningCount = warnCnt
                batchProgress = Double(idx + 1) / Double(items.count)
            }

            if releaseAfterBatch {
                ViewStereoDepthSynthesizer.shared.releaseCachedModels()
            }

            let cancelled = Task.isCancelled
            isBatchRunning = false
            batchTask = nil
            if !verifyOnly {
                refreshWorkspaceBrowser()
            }
            batchCompletionSummary = BatchCompletionSummary(
                succeeded: successCnt,
                failed: failCnt,
                warningCount: warnCnt,
                total: items.count,
                wasCancelled: cancelled,
                isVerifyOnly: verifyOnly,
                outputDirectory: outDir
            )
            if cancelled {
                statusMessage = verifyOnly
                    ? "Verification cancelled (\(successCnt)/\(items.count) checked)."
                    : "Batch cancelled (\(successCnt)/\(items.count) completed)."
            } else if verifyOnly {
                statusMessage = "Verification finished: \(successCnt - warnCnt) OK, \(warnCnt) warning(s), \(failCnt) failed."
            } else {
                statusMessage = "Batch finished: \(successCnt) succeeded, \(failCnt) failed → \(outDir.lastPathComponent)/"
            }
        }
    }

    nonisolated static func discoverBatchItems(in dir: URL, mode: StereoBatchPairingMode) -> [StereoBatchItem] {
        WorkspaceScanner.scanDirectory(dir, pairingMode: mode, customOutputFolder: nil).compactMap(\.item)
    }

    nonisolated private static func loadBatchPair(
        item: StereoBatchItem,
        cardMode: StereoCardMode,
        useCoreML: Bool,
        interpretation: StereoInputInterpretation = .auto
    ) -> (left: [UInt8], right: [UInt8], width: Int, height: Int, preservedArch: Bool, mountContext: StereoCardSegmenter.OriginalCardMountContext?, is2DPhoto: Bool)? {
        if let rURL = item.rightURL {
            guard let (lRGB, lw, lh) = loadNormalizedRGB(url: item.leftURL),
                  let (rRGBRaw, rw, rh) = loadNormalizedRGB(url: rURL) else {
                return nil
            }
            let rRGB = (lw == rw && lh == rh) ? rRGBRaw : resizeBilinearRGB(rRGBRaw, sw: rw, sh: rh, dw: lw, dh: lh)
            return (lRGB, rRGB, lw, lh, false, nil, false)
        } else {
            if interpretation != .force2D, let pair = loadStereoPairFromContainer(url: item.leftURL) {
                return (pair.0, pair.1, pair.2, pair.3, false, nil, false)
            }
            guard let (rgb, fw, fh) = loadNormalizedRGB(url: item.leftURL), fw >= 64 else {
                return nil
            }
            if interpretation == .force2D {
                return (rgb, rgb, fw, fh, false, nil, true)
            }
            let extMode: StereoCardCropper.ExtractionMode = (cardMode == .keepArchBlack) ? .keepArchBlack : .cropInner
            if cardMode != .off,
               let card = (useCoreML ? StereoCardSegmenter.shared.extractPhotoPair(from: rgb, width: fw, height: fh, mode: extMode) : nil)
                       ?? StereoCardCropper.extractPhotoPair(from: rgb, width: fw, height: fh, mode: extMode) {
                let mountCtx = StereoCardSegmenter.shared.currentMountContext
                return (card.leftRGB, card.rightRGB, card.width, card.height, card.preservedArch, mountCtx, false)
            }
            if interpretation == .auto && detectIs2DPhoto(rgb: rgb, width: fw, height: fh) {
                return (rgb, rgb, fw, fh, false, nil, true)
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
            return (l, r, w, fh, false, nil, false)
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
        colorOptions: StereoColorizationOptions = StereoColorizationOptions(),
        outL: URL,
        outR: URL
    ) -> Bool {
        var l = left
        var r = right
        if !restorationOptions.isIdentity || !detailOptions.isIdentity || !colorOptions.isIdentity {
            let restored = applyVintagePipeline(left: l, right: r, width: width, height: height, toneOptions: restorationOptions, detailOptions: detailOptions, colorOptions: colorOptions)
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
        colorOptions: StereoColorizationOptions = StereoColorizationOptions(),
        to url: URL
    ) -> Bool {
        var l = left
        var r = right
        if !restorationOptions.isIdentity || !detailOptions.isIdentity || !colorOptions.isIdentity {
            let restored = applyVintagePipeline(left: l, right: r, width: width, height: height, toneOptions: restorationOptions, detailOptions: detailOptions, colorOptions: colorOptions)
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
        colorOptions: StereoColorizationOptions = StereoColorizationOptions(),
        saveReport: Bool
    ) -> Bool {
        saveBatchRGBPair(
            left: out.warpedL,
            right: out.warpedR,
            width: out.cw,
            height: out.ch,
            baseName: item.baseName,
            item: item,
            srcWidth: srcWidth,
            srcHeight: srcHeight,
            outDir: outDir,
            layout: layout,
            imageFormat: imageFormat,
            isSwapped: isSwapped,
            frameStyle: frameStyle,
            cardConfig: cardConfig,
            mountContext: mountContext,
            restorationOptions: restorationOptions,
            detailOptions: detailOptions,
            colorOptions: colorOptions,
            saveReport: saveReport,
            alignmentOutput: out
        )
    }

    nonisolated private static func saveBatchRGBPair(
        left: [UInt8],
        right: [UInt8],
        width w: Int,
        height h: Int,
        baseName base: String,
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
        colorOptions: StereoColorizationOptions = StereoColorizationOptions(),
        saveReport: Bool,
        alignmentOutput out: AlignmentPipelineOutput? = nil
    ) -> Bool {
        let ext = imageFormat.fileExtension
        let restored = (restorationOptions.isIdentity && detailOptions.isIdentity && colorOptions.isIdentity)
            ? (left: left, right: right)
            : applyVintagePipeline(left: left, right: right, width: w, height: h, toneOptions: restorationOptions, detailOptions: detailOptions, colorOptions: colorOptions)
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
            let report: String
            if let out {
                let p = out.rectRes.params
                report = """
                ViewStereo Batch Alignment Report
                Left File       : \(item.leftURL.path)
                Right File      : \(item.rightURL?.path ?? item.leftURL.path)
                Original Size   : \(srcWidth) x \(srcHeight)
                Cropped Size    : \(w) x \(h)
                Matches / Inliers: \(out.matches.count) / \(out.rectRes.inlierCount)
                Vertical RMSE   : \(String(format: "%.4f px", out.rectRes.verticalRMSEPixels))
                Window Shift X  : \(String(format: "%.3f px", out.windowDecision.optimalShiftX))
                Auto-Swap       : \(isSwapped ? "Applied (Left <-> Right swapped for pseudoscopic correction)" : "None")
                Stereo Status   : \(out.stereoReportText)
                Log Scale (u_s) : \(p.logScale)
                Roll L / R (rad): \(p.rollL) / \(p.rollR)
                Keystone H L/R  : \(p.keystoneXL) / \(p.keystoneXR)
                Keystone V (k_y): \(p.keystoneY)
                Shift V (t_y)   : \(p.shiftY)
                """
            } else {
                report = """
                ViewStereo Batch 2D-3D Conversion Report
                Source File     : \(item.leftURL.path)
                Original Size   : \(srcWidth) x \(srcHeight)
                Output Size     : \(w) x \(h)
                Mode            : AI Depth 2D-to-3D Conversion (_2D3D)
                """
            }
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

    nonisolated static func combineSBS(left: [UInt8], right: [UInt8], width: Int, height: Int) -> [UInt8] {
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

    nonisolated static func combineLRRL(left: [UInt8], right: [UInt8], width: Int, height: Int) -> [UInt8] {
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

    nonisolated static func makePolarized(left: [UInt8], right: [UInt8], width: Int, height: Int) -> [UInt8] {
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

    nonisolated static func makeAnaglyph(left: [UInt8], right: [UInt8], width: Int, height: Int, type: AnaglyphType = .gray) -> [UInt8] {
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

            // 端の1pxがリサンプリングで暗くなったフリンジ（黒ライン）や台紙漏れを除去するため、左右および上下端をインセット
            if minX + 2 < maxX && minY + 2 < maxY {
                minX += 1
                maxX -= 1
                minY += 1
                maxY -= 1
            }
            return (minX, maxX, minY, maxY)
        }

        let bboxL = findBBox(img: left)
        let bboxR = findBBox(img: right)

        guard let bL = bboxL, let bR = bboxR else {
            return (left, right, width, height)
        }

        // アナグリフ等で片側チャンネルだけが光って横線になるのを防ぐため、両眼共通の有効範囲を採用
        let minY = max(bL.minY, bR.minY)
        let maxY = min(bL.maxY, bR.maxY)
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
