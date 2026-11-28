import Foundation

// MARK: - フォルダ単位の個別設定ファイル（ViewStereo_Settings.json）

/// 1クリックマスク補正でユーザーが確定したガイド枠・アーチ曲率のオーバーライド設定
struct FolderMaskGuideOverride: Codable, Equatable, Sendable {
    let boxL: InteractivePromptBox
    let boxR: InteractivePromptBox
    let topArchRatio: Double
    let botRoundRatio: Double
}

/// フォルダ内の 1 アイテム（画像ファイル）に対する個別設定スナップショット
struct FolderItemSettings: Codable, Equatable, Sendable {
    var updatedAt: Date

    // 基本設定
    var stereoCardModeRaw: String
    var useCoreMLCardSegmentation: Bool
    var frameStyleRaw: String
    var autoAlignOnLoad: Bool
    var autoColorModeRaw: String
    var keepOriginalAspectRatio: Bool
    var usePersonMotionMask: Bool
    var useAttentionSaliency: Bool
    var removeUnilateralNoise: Bool

    // ステレオウィンドウ・左右スワップ
    var isSwapped: Bool
    var windowShiftX: Double

    // カスタムガイドマスク（1クリックマスク補正で枠・アーチを確定した場合）
    var maskGuideOverride: FolderMaskGuideOverride?

    // Data Flywheel (自動推定初期値と確定値の学習・改善ログ用)
    var autoOptimalShiftX: Double? = nil
    var autoMaskGuide: FolderMaskGuideOverride? = nil

    // 台紙設定
    var cardMountPresetRaw: String
    var cardSizeSpecRaw: String
    var cardPrintCutStyleRaw: String
    var cardCenterGapStyleRaw: String
    var cardTextModeRaw: String
    var cardBottomCaption: String
    var cardTopCenterText: String
    var cardLeftMarginText: String
    var cardRightMarginText: String
    var cardUseFilenameAsCaption: Bool

    // 退色復元・彩色
    var isRestorationEnabled: Bool
    var restorationPrintToneRaw: String
    var restorationAutoLevel: Double
    var restorationLocalContrast: Double
    var restorationDeblurStrength: Double
    var restorationTextureProtection: Double
    var restorationColorizationModeRaw: String
    var restorationColorStrength: Double
    var restorationPaperWarmth: Double

    // 2D→3D・出力設定
    var virtualDepthBasePercent: Double
    var depthGamma: Double
    var exportLayoutRaw: String
    var exportImageFormatRaw: String

    /// タイムスタンプ（updatedAt）を除き、すべての調整値・設定値が一致しているかを比較する
    func isSameValues(as other: FolderItemSettings) -> Bool {
        return stereoCardModeRaw == other.stereoCardModeRaw
            && useCoreMLCardSegmentation == other.useCoreMLCardSegmentation
            && frameStyleRaw == other.frameStyleRaw
            && autoAlignOnLoad == other.autoAlignOnLoad
            && autoColorModeRaw == other.autoColorModeRaw
            && keepOriginalAspectRatio == other.keepOriginalAspectRatio
            && usePersonMotionMask == other.usePersonMotionMask
            && useAttentionSaliency == other.useAttentionSaliency
            && removeUnilateralNoise == other.removeUnilateralNoise
            && isSwapped == other.isSwapped
            && abs(windowShiftX - other.windowShiftX) < 1e-4
            && maskGuideOverride == other.maskGuideOverride
            && cardMountPresetRaw == other.cardMountPresetRaw
            && cardSizeSpecRaw == other.cardSizeSpecRaw
            && cardPrintCutStyleRaw == other.cardPrintCutStyleRaw
            && cardCenterGapStyleRaw == other.cardCenterGapStyleRaw
            && cardTextModeRaw == other.cardTextModeRaw
            && cardBottomCaption == other.cardBottomCaption
            && cardTopCenterText == other.cardTopCenterText
            && cardLeftMarginText == other.cardLeftMarginText
            && cardRightMarginText == other.cardRightMarginText
            && cardUseFilenameAsCaption == other.cardUseFilenameAsCaption
            && isRestorationEnabled == other.isRestorationEnabled
            && restorationPrintToneRaw == other.restorationPrintToneRaw
            && abs(restorationAutoLevel - other.restorationAutoLevel) < 1e-4
            && abs(restorationLocalContrast - other.restorationLocalContrast) < 1e-4
            && abs(restorationDeblurStrength - other.restorationDeblurStrength) < 1e-4
            && abs(restorationTextureProtection - other.restorationTextureProtection) < 1e-4
            && restorationColorizationModeRaw == other.restorationColorizationModeRaw
            && abs(restorationColorStrength - other.restorationColorStrength) < 1e-4
            && abs(restorationPaperWarmth - other.restorationPaperWarmth) < 1e-4
            && abs(virtualDepthBasePercent - other.virtualDepthBasePercent) < 1e-4
            && abs(depthGamma - other.depthGamma) < 1e-4
            && exportLayoutRaw == other.exportLayoutRaw
            && exportImageFormatRaw == other.exportImageFormatRaw
    }

    /// .vstereo サイドカーの値で設定を更新・マージする
    mutating func applySidecarValues(
        updatedAt: Date,
        isSwapped: Bool,
        windowShiftX: Double,
        stereoCardModeRaw: String,
        frameStyleRaw: String,
        autoColorModeRaw: String,
        keepOriginalAspectRatio: Bool,
        virtualDepthBasePercent: Double,
        depthGamma: Double,
        exportLayoutRaw: String,
        exportImageFormatRaw: String
    ) {
        self.updatedAt = max(self.updatedAt, updatedAt)
        self.isSwapped = isSwapped
        self.windowShiftX = windowShiftX
        self.stereoCardModeRaw = stereoCardModeRaw
        self.frameStyleRaw = frameStyleRaw
        self.autoColorModeRaw = autoColorModeRaw
        self.keepOriginalAspectRatio = keepOriginalAspectRatio
        self.virtualDepthBasePercent = virtualDepthBasePercent
        self.depthGamma = depthGamma
        self.exportLayoutRaw = exportLayoutRaw
        self.exportImageFormatRaw = exportImageFormatRaw
    }
}

/// ワークスペースフォルダ直下の ViewStereo_Settings.json ドキュメント
struct FolderSettingsDocument: Codable, Sendable {
    var version: Int = 1
    var updatedAt: Date
    var items: [String: FolderItemSettings]
}

/// フォルダ単位設定ファイルの読み書きと相対キー解決を担当するストア
enum WorkspaceFolderSettingsStore {
    static let filename = "ViewStereo_Settings.json"

    static func fileURL(in folder: URL) -> URL {
        folder.standardizedFileURL.appendingPathComponent(filename, isDirectory: false)
    }

    static func relativeKey(for fileURL: URL, in folder: URL) -> String? {
        let stdFolderPath = folder.standardizedFileURL.path
        let stdFilePath = fileURL.standardizedFileURL.path
        let prefix = stdFolderPath.hasSuffix("/") ? stdFolderPath : stdFolderPath + "/"
        guard stdFilePath.hasPrefix(prefix) else { return nil }
        let rel = String(stdFilePath.dropFirst(prefix.count))
        return rel.isEmpty ? nil : rel
    }

    static func load(from folder: URL) -> FolderSettingsDocument? {
        let url = fileURL(in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(FolderSettingsDocument.self, from: data)
        } catch {
            NSLog("[WorkspaceFolderSettings] Failed to load %@: %@", url.path, error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    static func save(_ document: FolderSettingsDocument, to folder: URL) throws -> URL {
        let stdFolder = folder.standardizedFileURL
        try FileManager.default.createDirectory(at: stdFolder, withIntermediateDirectories: true)
        let url = fileURL(in: stdFolder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try data.write(to: url, options: [.atomic])
        return url
    }
}
