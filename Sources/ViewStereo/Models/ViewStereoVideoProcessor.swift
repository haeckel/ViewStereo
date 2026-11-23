import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreML
import Foundation
import StereoCore
import StereoStudioCore

/// 動画 2D→3D 書き出しフォーマット（写真書き出しの立体視方式に準拠・空間写真/MPOを除く + 空間ビデオ）
public enum StereoVideoExportFormat: String, CaseIterable, Identifiable, Sendable {
    case stereoviewCard = "Stereoview Card"
    case sbs = "SBS"
    case lrrl = "LR/RL (4-Way)"
    case dubois = "Dubois"
    case colorAnaglyph = "Color Anaglyph"
    case grayAnaglyph = "Gray Anaglyph"
    case polarized = "Polarized"
    case twoD = "2D"
    case separateLR = "Separate L/R"
    case spatialVideo = "Spatial Video (MV-HEVC .mov)"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .spatialVideo: return "mov"
        default: return "mp4"
        }
    }

    public var suffix: String {
        switch self {
        case .stereoviewCard: return "_Card"
        case .sbs: return "_SBS"
        case .lrrl: return "_LRRL"
        case .dubois: return "_Dubois"
        case .colorAnaglyph: return "_ColorAnaglyph"
        case .grayAnaglyph: return "_GrayAnaglyph"
        case .polarized: return "_Polarized"
        case .twoD: return "_2D"
        case .separateLR: return ""
        case .spatialVideo: return "_Spatial"
        }
    }
}

/// 動画入力のソース解釈（通常の2D動画、または既存3D SBS動画からの片眼サルベージ）
public enum VideoInputStereoSource: String, CaseIterable, Identifiable, Sendable {
    case full2D = "2D Full Frame"
    case sbsLeft = "SBS → Left Eye"
    case sbsRight = "SBS → Right Eye"

    public var id: String { rawValue }
    public var localizedLabel: String {
        String(localized: String.LocalizationValue(rawValue))
    }
}

/// 読み込んだ動画クリップの基本メタデータ
public struct VideoClipMetadata: Sendable, Equatable {
    public let url: URL
    public let durationSeconds: Double
    public let naturalWidth: Int
    public let naturalHeight: Int
    public let nominalFPS: Double
    public let estimatedFrameCount: Int
    public let hasAudio: Bool
    public let isHDR: Bool
    public let isLikelySBS: Bool
}

/// 動画専用 Stateful 深度推論セッション
/// - Apple Depth Pro 2 の `MLState` をクリップ内で継続し、時間的フリッカーを抑制
/// - シーンカット（輝度 MAD / ヒストグラム急変）検出時に `MLState` と EMA 統計を即時リセット
/// - EMA（指数移動平均）による `(pLow, pHigh)` および `focusRatio` 平滑化で Depth Pumping を防止
public final class ViewStereoVideoDepthSession: @unchecked Sendable {
    private let synth = ViewStereoDepthSynthesizer.shared

    private var prepared: (model: MLModel, engine: StudioDepthEngine, isFallback: Bool)?
    private var mlState: AnyObject?

    private var prevLuma64x36: [UInt8]?
    private var prevHist16: [Float]?
    private var framesSinceLastCut: Int = 100
    private let minCutCooldownFrames: Int = 10
    private var wasInBlackout: Bool = false

    private var emaPLow: Float?
    private var emaPHigh: Float?
    private var lockedRange: (pLow: Float, pHigh: Float)?
    private var emaFocusRatio: Double?

    public private(set) var activeEngineName: String = ViewStereoDepthSynthesizer.DepthEngineType.visionNative.rawValue

    public init() {}

    /// 動画セッションを開始し、優先モデルをロード・初期 `MLState` を構築する
    public func startSession(preferredEngine: StudioDepthEngine) {
        endSession(releaseModel: false)
        prepared = synth.prepareVideoEngine(preferredEngine: preferredEngine)
        if let prep = prepared {
            mlState = synth.makeVideoInferenceState(for: prep.model, engine: prep.engine)
            activeEngineName = prep.isFallback ? "\(prep.engine.shortLabel) [Fallback]" : prep.engine.shortLabel
        } else {
            mlState = nil
            activeEngineName = ViewStereoDepthSynthesizer.DepthEngineType.visionNative.rawValue
        }
    }

    /// シーク時やシーンカット検出時に時間的状態（MLState・EMA・カット比較バッファ）をリセットする
    public func resetTemporalState() {
        if let prep = prepared {
            mlState = synth.makeVideoInferenceState(for: prep.model, engine: prep.engine)
        } else {
            mlState = nil
        }
        prevLuma64x36 = nil
        prevHist16 = nil
        framesSinceLastCut = 0
        wasInBlackout = false
        emaPLow = nil
        emaPHigh = nil
        emaFocusRatio = nil
    }

    /// 固定レンジキャッシュをクリアする
    public func clearLockedRange() {
        lockedRange = nil
    }

    /// 1 フレーム分の深度推論・カット検出・時間的正規化・ウィンドウダンピングを実行する
    public func processFrame(
        cgImage: CGImage,
        rgb24: [UInt8],
        width: Int,
        height: Int,
        targetDisparityPercent: Double,
        depthGamma: Double,
        temporalSmoothing: Double,
        lockDepthRange: Bool,
        autoCutDetection: Bool
    ) -> (disparityMap: [Float], depthW: Int, depthH: Int, focusRatio: Double, cutDetected: Bool, engineName: String) {
        // 1. シーンカット ＆ 暗転フェード復帰検出（クールダウン付きでフラッシュ誤検知を防止）
        let (currLuma, currHist, meanLuma) = Self.extractTinyLumaAndHist(rgb24: rgb24, width: width, height: height)
        var cutDetected = false
        let isBlackoutNow = meanLuma < 0.04
        if autoCutDetection {
            if isBlackoutNow {
                wasInBlackout = true
            } else if wasInBlackout {
                // 暗転フェード明けの復帰フレームでリセット
                cutDetected = true
                resetTemporalState()
            } else if framesSinceLastCut >= minCutCooldownFrames,
                      let pLuma = prevLuma64x36,
                      let pHist = prevHist16 {
                let mad = Self.meanAbsoluteLumaDiff(pLuma, currLuma)
                let histL1 = Self.l1HistDistance(pHist, currHist)
                if mad > 0.28 || histL1 > 0.45 {
                    cutDetected = true
                    resetTemporalState()
                }
            }
        }
        framesSinceLastCut = cutDetected ? 0 : (framesSinceLastCut + 1)
        prevLuma64x36 = currLuma
        prevHist16 = currHist

        // 1.5 有効映像領域 (ROI) の検出（黒帯レターボックス / ピラーボックスを除外）
        let roi = Self.detectActiveROI(rgb24: rgb24, width: width, height: height)

        // 2. 未正規化深度推論（Depth Pro 2 は継続中の MLState を渡す）
        let raw = synth.estimateRawVideoDepth(
            cgImage: cgImage,
            prepared: prepared,
            externalState: mlState
        )
        activeEngineName = raw.engineName

        // ROI 内ピクセルのみからパーセンタイルを再算出（黒帯が存在する場合の正規化狂いを防止）
        let (frameLow, frameHigh): (Float, Float)
        if roi.uMin > 0.01 || roi.uMax < 0.99 || roi.vMin > 0.01 || roi.vMax < 0.99 {
            (frameLow, frameHigh) = Self.computeROIPercentiles(
                raw: raw.rawDisparity,
                width: raw.width,
                height: raw.height,
                roi: roi,
                validMask: raw.validMask
            )
        } else {
            (frameLow, frameHigh) = (raw.pLow, raw.pHigh)
        }

        // 3. 時間的正規化（EMA または 固定レンジ）で Depth Pumping を防止
        let effLow: Float
        let effHigh: Float
        if lockDepthRange {
            if let locked = lockedRange {
                effLow = locked.pLow
                effHigh = locked.pHigh
            } else {
                lockedRange = (frameLow, frameHigh)
                effLow = frameLow
                effHigh = frameHigh
            }
        } else {
            lockedRange = nil
            let smoothClamped = max(0.0, min(1.0, temporalSmoothing))
            let alpha: Float = (emaPLow == nil || cutDetected) ? 1.0 : Float(max(0.02, 1.0 - smoothClamped * 0.94))
            let nextLow = (emaPLow == nil) ? frameLow : (alpha * frameLow + (1.0 - alpha) * emaPLow!)
            let nextHigh = (emaPHigh == nil) ? frameHigh : (alpha * frameHigh + (1.0 - alpha) * emaPHigh!)
            emaPLow = nextLow
            emaPHigh = max(nextLow + 1e-6, nextHigh)
            effLow = emaPLow!
            effHigh = emaPHigh!
        }

        let span = max(1e-6, effHigh - effLow)
        var normalized = [Float](repeating: 0.0, count: raw.rawDisparity.count)
        if let mask = raw.validMask, mask.count == raw.rawDisparity.count {
            for i in 0..<raw.rawDisparity.count {
                if mask[i] {
                    let c = min(max(raw.rawDisparity[i], effLow), effHigh)
                    normalized[i] = min(1.0, max(0.0, (c - effLow) / span))
                } else {
                    normalized[i] = 0.0 // 空マスクは最奥固定
                }
            }
        } else {
            for i in 0..<raw.rawDisparity.count {
                let v = raw.rawDisparity[i]
                let c = min(max(v.isFinite ? v : effLow, effLow), effHigh)
                normalized[i] = min(1.0, max(0.0, (c - effLow) / span))
            }
        }

        // 4. ゼロ視差面 (focusRatio) の計算とダンピング（ROI 領域内のみで算出）
        let rawFocus = Self.estimateSafeEdgeFocusRatio(
            disparityMap: normalized,
            depthW: raw.width,
            depthH: raw.height,
            depthGamma: depthGamma,
            roi: roi
        )
        let alphaW: Double = (emaFocusRatio == nil || cutDetected) ? 1.0 : max(0.02, 1.0 - max(0.0, min(1.0, temporalSmoothing)) * 0.95)
        let smoothedFocus = (emaFocusRatio == nil) ? rawFocus : (alphaW * rawFocus + (1.0 - alphaW) * emaFocusRatio!)
        emaFocusRatio = smoothedFocus

        return (normalized, raw.width, raw.height, smoothedFocus, cutDetected, raw.engineName)
    }

    /// セッション終了。必要に応じてモデルキャッシュを解放する
    public func endSession(releaseModel: Bool) {
        mlState = nil
        prepared = nil
        prevLuma64x36 = nil
        prevHist16 = nil
        emaPLow = nil
        emaPHigh = nil
        lockedRange = nil
        emaFocusRatio = nil
        if releaseModel {
            synth.releaseCachedModels()
        }
    }

    // MARK: - Scene Cut, ROI & Focus Helpers

    private struct ActiveROI {
        let uMin: Float
        let uMax: Float
        let vMin: Float
        let vMax: Float
    }

    private static func detectActiveROI(rgb24: [UInt8], width: Int, height: Int) -> ActiveROI {
        let full = ActiveROI(uMin: 0, uMax: 1, vMin: 0, vMax: 1)
        guard width >= 32, height >= 32, rgb24.count >= width * height * 3 else { return full }
        let threshold: Int = 10
        let sampleCols = 32
        let sampleRows = 24

        func rowIsBlack(_ y: Int) -> Bool {
            var sum = 0
            for i in 0..<sampleCols {
                let x = (i * (width - 1)) / max(1, sampleCols - 1)
                let idx = (y * width + x) * 3
                sum += (77 * Int(rgb24[idx]) + 150 * Int(rgb24[idx + 1]) + 29 * Int(rgb24[idx + 2])) >> 8
            }
            return (sum / sampleCols) < threshold
        }

        func colIsBlack(_ x: Int) -> Bool {
            var sum = 0
            for i in 0..<sampleRows {
                let y = (i * (height - 1)) / max(1, sampleRows - 1)
                let idx = (y * width + x) * 3
                sum += (77 * Int(rgb24[idx]) + 150 * Int(rgb24[idx + 1]) + 29 * Int(rgb24[idx + 2])) >> 8
            }
            return (sum / sampleRows) < threshold
        }

        let maxCropY = height / 4
        let maxCropX = width / 4
        var top = 0
        while top < maxCropY && rowIsBlack(top) { top += 2 }
        var bot = height - 1
        while bot > height - 1 - maxCropY && rowIsBlack(bot) { bot -= 2 }
        var left = 0
        while left < maxCropX && colIsBlack(left) { left += 2 }
        var right = width - 1
        while right > width - 1 - maxCropX && colIsBlack(right) { right -= 2 }

        guard right - left >= width / 2, bot - top >= height / 2 else { return full }
        return ActiveROI(
            uMin: Float(left) / Float(width),
            uMax: Float(right + 1) / Float(width),
            vMin: Float(top) / Float(height),
            vMax: Float(bot + 1) / Float(height)
        )
    }

    private static func computeROIPercentiles(
        raw: [Float],
        width: Int,
        height: Int,
        roi: ActiveROI,
        validMask: [Bool]?
    ) -> (Float, Float) {
        guard width > 0, height > 0, raw.count >= width * height else { return (0.0, 1.0) }
        let x0 = max(0, Int(roi.uMin * Float(width)))
        let x1 = min(width, Int(roi.uMax * Float(width)))
        let y0 = max(0, Int(roi.vMin * Float(height)))
        let y1 = min(height, Int(roi.vMax * Float(height)))
        let stepX = max(1, (x1 - x0) / 128)
        let stepY = max(1, (y1 - y0) / 128)

        var samples = [Float]()
        samples.reserveCapacity(16384)
        for y in stride(from: y0, to: y1, by: stepY) {
            let row = y * width
            for x in stride(from: x0, to: x1, by: stepX) {
                let idx = row + x
                if let mask = validMask, !mask[idx] { continue }
                let v = raw[idx]
                if v.isFinite { samples.append(v) }
            }
        }
        guard !samples.isEmpty else { return (0.0, 1.0) }
        samples.sort()
        let pLow = samples[max(0, min(samples.count - 1, Int(Float(samples.count) * 0.02)))]
        let pHigh = samples[max(0, min(samples.count - 1, Int(Float(samples.count) * 0.98)))]
        return (pLow, max(pLow + 1e-6, pHigh))
    }

    private static func estimateSafeEdgeFocusRatio(
        disparityMap: [Float],
        depthW: Int,
        depthH: Int,
        depthGamma: Double,
        roi: ActiveROI
    ) -> Double {
        guard depthW > 0, depthH > 0, disparityMap.count >= depthW * depthH else { return 0.72 }
        var edgeMax: Float = 0.0
        var centerWeightedSum: Double = 0.0
        var weightSum: Double = 0.0

        let uSpan = max(0.1, roi.uMax - roi.uMin)
        let vSpan = max(0.1, roi.vMax - roi.vMin)

        for gy in 0..<12 {
            let lv = 0.02 + 0.96 * Float(gy) / 11.0
            let v = roi.vMin + lv * vSpan
            for gx in 0..<16 {
                let lu = 0.02 + 0.96 * Float(gx) / 15.0
                let u = roi.uMin + lu * uSpan
                let d = ViewStereoDepthSynthesizer.sampleNormalizedDisparity(
                    disparityMap: disparityMap,
                    depthW: depthW,
                    depthH: depthH,
                    u: u,
                    v: v,
                    depthGamma: depthGamma
                )
                let isEdge = (lu <= 0.08 || lu >= 0.92 || lv <= 0.08 || lv >= 0.92)
                if isEdge {
                    if d > edgeMax { edgeMax = d }
                } else {
                    let dx = Double(lu - 0.5)
                    let dy = Double(lv - 0.5)
                    let w = max(0.1, 1.0 - (dx * dx + dy * dy) * 2.0)
                    centerWeightedSum += Double(d) * w
                    weightSum += w
                }
            }
        }
        let centerAvg = weightSum > 0 ? (centerWeightedSum / weightSum) : 0.55
        return min(0.95, max(0.35, max(Double(edgeMax) * 0.96, centerAvg * 1.15)))
    }

    private static func extractTinyLumaAndHist(rgb24: [UInt8], width: Int, height: Int) -> ([UInt8], [Float], Float) {
        let tw = 64
        let th = 36
        var luma = [UInt8](repeating: 0, count: tw * th)
        var hist = [Float](repeating: 0, count: 16)
        guard width > 0, height > 0, rgb24.count >= width * height * 3 else {
            return (luma, hist, 0.5)
        }
        let invTotal = 1.0 / Float(tw * th)
        var lumaSum: Int = 0
        for ty in 0..<th {
            let sy = min(height - 1, (ty * height) / th)
            for tx in 0..<tw {
                let sx = min(width - 1, (tx * width) / tw)
                let idx = (sy * width + sx) * 3
                let yVal = (77 * Int(rgb24[idx]) + 150 * Int(rgb24[idx + 1]) + 29 * Int(rgb24[idx + 2])) >> 8
                let u8 = UInt8(clamping: yVal)
                luma[ty * tw + tx] = u8
                lumaSum += Int(u8)
                let bin = min(15, Int(u8) >> 4)
                hist[bin] += invTotal
            }
        }
        let meanLuma = Float(lumaSum) / (Float(tw * th) * 255.0)
        return (luma, hist, meanLuma)
    }

    private static func meanAbsoluteLumaDiff(_ a: [UInt8], _ b: [UInt8]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum: Int = 0
        for i in 0..<a.count {
            sum += abs(Int(a[i]) - Int(b[i]))
        }
        return Float(sum) / (Float(a.count) * 255.0)
    }

    private static func l1HistDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in 0..<a.count {
            sum += abs(a[i] - b[i])
        }
        return sum * 0.5 // 0.0 ~ 1.0
    }
}

/// 動画 2D→3D 読み込み・プレビュー生成・オフライン書き出しプロセッサ
public final class ViewStereoVideoProcessor: @unchecked Sendable {
    public static let shared = ViewStereoVideoProcessor()
    private init() {}

    /// 動画ファイルの基本メタデータを非同期取得する
    public func loadMetadata(url: URL) async -> VideoClipMetadata? {
        let asset = AVURLAsset(url: url)
        do {
            let durationCM = try await asset.load(.duration)
            let durationSec = max(0.0, CMTimeGetSeconds(durationCM))
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let vTrack = videoTracks.first else { return nil }

            let naturalSize = try await vTrack.load(.naturalSize)
            let preferredTransform = try await vTrack.load(.preferredTransform)
            let transformedSize = naturalSize.applying(preferredTransform)
            let w = max(2, Int(abs(transformedSize.width).rounded()))
            let h = max(2, Int(abs(transformedSize.height).rounded()))

            let nominalFPSRaw = try await vTrack.load(.nominalFrameRate)
            let fps = nominalFPSRaw > 1.0 ? Double(nominalFPSRaw) : 30.0
            let estFrames = max(1, Int((durationSec * fps).rounded()))

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let isHDR = vTrack.hasMediaCharacteristic(.containsHDRVideo)
            let isLikelySBS = (Double(w) / Double(max(1, h))) >= 2.2
            return VideoClipMetadata(
                url: url,
                durationSeconds: durationSec,
                naturalWidth: w,
                naturalHeight: h,
                nominalFPS: fps,
                estimatedFrameCount: estFrames,
                hasAudio: !audioTracks.isEmpty,
                isHDR: isHDR,
                isLikelySBS: isLikelySBS
            )
        } catch {
            print("[ViewStereoVideoProcessor] Failed to load metadata: \(error.localizedDescription)")
            return nil
        }
    }

    /// 既存 SBS 動画の片眼（左半分または右半分）をクロップ抽出する
    nonisolated public static func extractSourceEye(
        rgb24: [UInt8],
        width: Int,
        height: Int,
        source: VideoInputStereoSource
    ) -> (rgb: [UInt8], width: Int, height: Int) {
        guard source != .full2D, width >= 4, height >= 2 else {
            return (rgb24, width, height)
        }
        let halfW = max(2, (width / 2) & ~1)
        let startX = (source == .sbsRight) ? (width - halfW) : 0
        var out = [UInt8](repeating: 0, count: halfW * height * 3)
        let srcStride = width * 3
        let dstStride = halfW * 3
        rgb24.withUnsafeBufferPointer { srcBuf in
            out.withUnsafeMutableBufferPointer { dstBuf in
                guard let sBase = srcBuf.baseAddress, let dBase = dstBuf.baseAddress else { return }
                for y in 0..<height {
                    memcpy(dBase + y * dstStride, sBase + y * srcStride + startX * 3, dstStride)
                }
            }
        }
        return (out, halfW, height)
    }

    /// 任意時刻のプレビューフレームをデコードして 24-bit RGB バッファで返す
    public func decodePreviewFrame(
        url: URL,
        atSeconds: Double,
        maxDimension: Int = 1280,
        inputSource: VideoInputStereoSource = .full2D
    ) async -> (rgb: [UInt8], cgImage: CGImage, width: Int, height: Int, actualSeconds: Double)? {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.04, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.04, preferredTimescale: 600)
            if maxDimension > 0 {
                let effectiveMax = (inputSource == .full2D) ? maxDimension : maxDimension * 2
                gen.maximumSize = CGSize(width: effectiveMax, height: effectiveMax)
            }

            let reqTime = CMTime(seconds: max(0.0, atSeconds), preferredTimescale: 600)
            var actual = reqTime
            guard let cgImg = try? gen.copyCGImage(at: reqTime, actualTime: &actual),
                  let rawRGB = Self.extractRGB24(from: cgImg) else {
                return nil
            }
            if inputSource == .full2D {
                return (rawRGB, cgImg, cgImg.width, cgImg.height, max(0.0, CMTimeGetSeconds(actual)))
            }
            let cropped = Self.extractSourceEye(rgb24: rawRGB, width: cgImg.width, height: cgImg.height, source: inputSource)
            guard let croppedCG = ViewStereoDepthSynthesizer.createCGImage(from: cropped.rgb, width: cropped.width, height: cropped.height) else {
                return nil
            }
            return (cropped.rgb, croppedCG, cropped.width, cropped.height, max(0.0, CMTimeGetSeconds(actual)))
        }.value
    }

    /// 動画 2D→3D フル変換 ＆ 書き出し（写真書き出し準拠の全立体視方式 + Spatial Video MV-HEVC）
    func exportVideo(
        sourceURL: URL,
        outputURL: URL,
        metadata: VideoClipMetadata,
        format: StereoVideoExportFormat,
        preferredEngine: StudioDepthEngine,
        virtualDepthBasePercent: Double,
        depthGamma: Double,
        temporalSmoothing: Double,
        lockDepthRange: Bool,
        autoCutDetection: Bool,
        isSwapped: Bool,
        inputSource: VideoInputStereoSource = .full2D,
        preserveHDR: Bool = false,
        cardConfig: StereoCardMountConfig = StereoCardMountConfig(),
        toneOptions: VintageRestorationOptions = VintageRestorationOptions(),
        detailOptions: StereoDetailRestorationOptions = StereoDetailRestorationOptions(),
        colorOptions: StereoColorizationOptions = StereoColorizationOptions(),
        releaseAfterExport: Bool,
        onProgress: @escaping @MainActor (Double, Int, Int, Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let vTrack = videoTracks.first else {
            throw NSError(domain: "ViewStereoVideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "映像トラックが見つかりません"])
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = audioTracks.first

        let reader = try AVAssetReader(asset: asset)

        // AVAssetReaderVideoCompositionOutput で preferredTransform 自動正立化 ＋ HDR保持(HLG)/SDR(Rec.709)切り替え
        let useHDR = preserveHDR && metadata.isHDR
        let videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        videoComposition.colorPrimaries = useHDR ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = useHDR ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = useHDR ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2
        let videoOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [vTrack], videoSettings: videoOutputSettings)
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw NSError(domain: "ViewStereoVideoProcessor", code: -2, userInfo: [NSLocalizedDescriptionKey: "AVAssetReader 映像出力を追加できませんでした"])
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput? = nil
        if let aTrack = audioTrack {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: audioSettings)
            aOut.alwaysCopiesSampleData = false
            if reader.canAdd(aOut) {
                reader.add(aOut)
                audioOutput = aOut
            }
        }

        let srcW = (inputSource == .full2D) ? metadata.naturalWidth : max(2, (metadata.naturalWidth / 2) & ~1)
        let srcH = metadata.naturalHeight
        let outSize: CGSize
        switch format {
        case .stereoviewCard:
            let dummy = [UInt8](repeating: 0, count: srcW * srcH * 3)
            let cardProbe = StereoCardMountRenderer.renderCardRGB(
                leftRGB: dummy, rightRGB: dummy, printWidth: srcW, printHeight: srcH,
                config: cardConfig, mountContext: nil
            )
            outSize = CGSize(width: cardProbe.width, height: cardProbe.height)
        case .sbs:
            outSize = CGSize(width: srcW * 2, height: srcH)
        case .lrrl:
            outSize = CGSize(width: srcW * 2, height: srcH * 2)
        case .dubois, .colorAnaglyph, .grayAnaglyph, .polarized, .twoD, .separateLR, .spatialVideo:
            outSize = CGSize(width: srcW, height: srcH)
        }

        let isSeparate = (format == .separateLR)
        let separateLeftURL: URL
        let separateRightURL: URL
        if isSeparate {
            let dir = outputURL.deletingLastPathComponent()
            let stem = outputURL.deletingPathExtension().lastPathComponent
            let ext = format.fileExtension
            separateLeftURL = dir.appendingPathComponent("\(stem)_L.\(ext)")
            separateRightURL = dir.appendingPathComponent("\(stem)_R.\(ext)")
        } else {
            separateLeftURL = outputURL
            separateRightURL = outputURL
        }

        let exporter = VideoExporter()
        let exporterR: VideoExporter? = isSeparate ? VideoExporter() : nil
        let session = ViewStereoVideoDepthSession()
        session.startSession(preferredEngine: preferredEngine)

        defer {
            session.endSession(releaseModel: releaseAfterExport)
        }

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            var leftDoneURL: URL? = nil
            var rightDoneURL: URL? = isSeparate ? nil : separateLeftURL
            let doneLock = NSLock()

            let resumeOnce: (Result<URL, Error>) -> Void = { result in
                doneLock.lock()
                defer { doneLock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            exporter.startVideoPipelineExport(
                to: separateLeftURL,
                size: outSize,
                expectedFrameCount: metadata.estimatedFrameCount,
                isSpatial: format == .spatialVideo,
                codec: .hevc,
                fov: 55.0,
                projectionMode: .rectilinear,
                hasAudio: audioOutput != nil,
                preserveHDR: useHDR
            ) { writtenURL in
                guard let url = writtenURL else {
                    resumeOnce(.failure(CancellationError()))
                    return
                }
                doneLock.lock()
                leftDoneURL = url
                let ready = (rightDoneURL != nil)
                doneLock.unlock()
                if ready {
                    resumeOnce(.success(url))
                }
            }

            exporterR?.startVideoPipelineExport(
                to: separateRightURL,
                size: outSize,
                expectedFrameCount: metadata.estimatedFrameCount,
                isSpatial: false,
                codec: .hevc,
                fov: 55.0,
                projectionMode: .rectilinear,
                hasAudio: audioOutput != nil,
                preserveHDR: useHDR
            ) { writtenURL in
                guard let url = writtenURL else {
                    resumeOnce(.failure(CancellationError()))
                    return
                }
                doneLock.lock()
                rightDoneURL = url
                let ready = (leftDoneURL != nil)
                doneLock.unlock()
                if ready {
                    resumeOnce(.success(leftDoneURL ?? url))
                }
            }

            guard reader.startReading() else {
                exporter.cancelExport()
                exporterR?.cancelExport()
                let err = reader.error ?? NSError(domain: "ViewStereoVideoProcessor", code: -3, userInfo: [NSLocalizedDescriptionKey: "動画の読み取りを開始できませんでした"])
                resumeOnce(.failure(err))
                return
            }

            Task.detached(priority: .userInitiated) {
                let startClock = CFAbsoluteTimeGetCurrent()
                var frameIndex = 0
                let estTotal = max(1, metadata.estimatedFrameCount)

                var pendingVideoSample: CMSampleBuffer? = videoOutput.copyNextSampleBuffer()
                var pendingAudioSample: CMSampleBuffer? = audioOutput?.copyNextSampleBuffer()

                let vStartPTS = pendingVideoSample.map { CMSampleBufferGetPresentationTimeStamp($0) }
                let aStartPTS = pendingAudioSample.map { CMSampleBufferGetPresentationTimeStamp($0) }
                let sessionStartPTS: CMTime
                switch (vStartPTS, aStartPTS) {
                case let (v?, a?) where v.isValid && a.isValid:
                    sessionStartPTS = CMTimeCompare(v, a) <= 0 ? v : a
                case let (v?, _) where v.isValid:
                    sessionStartPTS = v
                case let (_, a?) where a.isValid:
                    sessionStartPTS = a
                default:
                    sessionStartPTS = .zero
                }
                exporter.startSessionIfNeeded(at: sessionStartPTS)
                exporterR?.startSessionIfNeeded(at: sessionStartPTS)

                // 音声コピー用の独立並行タスク
                let firstAudioToWrite = pendingAudioSample
                pendingAudioSample = nil
                let audioTask = Task.detached(priority: .userInitiated) {
                    guard let aOut = audioOutput else { return }
                    var currentAudio = firstAudioToWrite
                    while !Task.isCancelled {
                        guard let aSample = currentAudio else { break }
                        while (!exporter.isAudioWriterReadyForMoreMediaData || (exporterR != nil && !exporterR!.isAudioWriterReadyForMoreMediaData)) && !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 2_000_000)
                        }
                        if Task.isCancelled { break }
                        _ = exporter.appendAudioSampleBuffer(aSample)
                        _ = exporterR?.appendAudioSampleBuffer(aSample)
                        currentAudio = aOut.copyNextSampleBuffer()
                    }
                    exporter.markAudioFinished()
                    exporterR?.markAudioFinished()
                }

                // 映像フレーム変換ループ（Adaptor の CVPixelBufferPool を再利用）
                while !Task.isCancelled {
                    let currentVideoSample: CMSampleBuffer?
                    if let pending = pendingVideoSample {
                        currentVideoSample = pending
                        pendingVideoSample = nil
                    } else {
                        currentVideoSample = videoOutput.copyNextSampleBuffer()
                    }
                    guard let sampleBuffer = currentVideoSample else { break }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                          let (rawRGB24, rawW, rawH) = Self.extractRGB24(from: imageBuffer) else {
                        continue
                    }
                    let (rgb24, w, h) = Self.extractSourceEye(rgb24: rawRGB24, width: rawW, height: rawH, source: inputSource)
                    guard let cgImg = ViewStereoDepthSynthesizer.createCGImage(from: rgb24, width: w, height: h) else {
                        continue
                    }

                    let depthOut = session.processFrame(
                        cgImage: cgImg,
                        rgb24: rgb24,
                        width: w,
                        height: h,
                        targetDisparityPercent: virtualDepthBasePercent,
                        depthGamma: depthGamma,
                        temporalSmoothing: temporalSmoothing,
                        lockDepthRange: lockDepthRange,
                        autoCutDetection: autoCutDetection
                    )

                    let (rawSynthL, rawSynthR) = ViewStereoDepthSynthesizer.shared.synthesizeStereoPair(
                        baseRGB: rgb24,
                        width: w,
                        height: h,
                        disparityMap: depthOut.disparityMap,
                        depthW: depthOut.depthW,
                        depthH: depthOut.depthH,
                        targetDisparityPercent: virtualDepthBasePercent,
                        depthGamma: depthGamma,
                        focusRatio: depthOut.focusRatio
                    )
                    let restoredPair: (left: [UInt8], right: [UInt8])
                    if !toneOptions.isIdentity || !detailOptions.isIdentity || !colorOptions.isIdentity {
                        restoredPair = ViewStereoViewModel.applyVintagePipeline(
                            left: rawSynthL,
                            right: rawSynthR,
                            width: w,
                            height: h,
                            toneOptions: toneOptions,
                            detailOptions: detailOptions,
                            colorOptions: colorOptions
                        )
                    } else {
                        restoredPair = (rawSynthL, rawSynthR)
                    }
                    let leftRGB = isSwapped ? restoredPair.right : restoredPair.left
                    let rightRGB = isSwapped ? restoredPair.left : restoredPair.right

                    while (!exporter.isVideoWriterReadyForMoreMediaData || (exporterR != nil && !exporterR!.isVideoWriterReadyForMoreMediaData)) && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 2_000_000)
                    }
                    if Task.isCancelled { break }

                    switch format {
                    case .spatialVideo:
                        if let pbL = exporter.createPooledARGBPixelBuffer(fromRGB: leftRGB, width: w, height: h),
                           let pbR = exporter.createPooledARGBPixelBuffer(fromRGB: rightRGB, width: w, height: h) {
                            _ = exporter.appendSpatialPixelBuffers(left: pbL, right: pbR, at: pts)
                        }

                    case .stereoviewCard:
                        let card = StereoCardMountRenderer.renderCardRGB(
                            leftRGB: leftRGB, rightRGB: rightRGB, printWidth: w, printHeight: h,
                            config: cardConfig, mountContext: nil
                        )
                        if let pb = exporter.createPooledARGBPixelBuffer(fromRGB: card.rgb, width: card.width, height: card.height) {
                            _ = exporter.appendPixelBuffer(pb, at: pts)
                        }

                    case .sbs:
                        let sbs = ViewStereoViewModel.combineSBS(left: leftRGB, right: rightRGB, width: w, height: h)
                        if let pb = exporter.createPooledARGBPixelBuffer(fromRGB: sbs, width: w * 2, height: h) {
                            _ = exporter.appendPixelBuffer(pb, at: pts)
                        }

                    case .lrrl:
                        let grid = ViewStereoViewModel.combineLRRL(left: leftRGB, right: rightRGB, width: w, height: h)
                        if let pb = exporter.createPooledARGBPixelBuffer(fromRGB: grid, width: w * 2, height: h * 2) {
                            _ = exporter.appendPixelBuffer(pb, at: pts)
                        }

                    case .dubois, .colorAnaglyph, .grayAnaglyph:
                        let anaType: AnaglyphType = (format == .dubois) ? .dubois : (format == .colorAnaglyph ? .color : .gray)
                        let ana = ViewStereoViewModel.makeAnaglyph(left: leftRGB, right: rightRGB, width: w, height: h, type: anaType)
                        if let pb = exporter.createPooledARGBPixelBuffer(fromRGB: ana, width: w, height: h) {
                            _ = exporter.appendPixelBuffer(pb, at: pts)
                        }

                    case .polarized:
                        let pol = ViewStereoViewModel.makePolarized(left: leftRGB, right: rightRGB, width: w, height: h)
                        if let pb = exporter.createPooledARGBPixelBuffer(fromRGB: pol, width: w, height: h) {
                            _ = exporter.appendPixelBuffer(pb, at: pts)
                        }

                    case .twoD:
                        if let pb = exporter.createPooledARGBPixelBuffer(fromRGB: leftRGB, width: w, height: h) {
                            _ = exporter.appendPixelBuffer(pb, at: pts)
                        }

                    case .separateLR:
                        if let pbL = exporter.createPooledARGBPixelBuffer(fromRGB: leftRGB, width: w, height: h),
                           let pbR = exporterR?.createPooledARGBPixelBuffer(fromRGB: rightRGB, width: w, height: h) {
                            _ = exporter.appendPixelBuffer(pbL, at: pts)
                            _ = exporterR?.appendPixelBuffer(pbR, at: pts)
                        }
                    }

                    frameIndex += 1
                    if frameIndex == 1 || frameIndex % 5 == 0 || frameIndex >= estTotal {
                        let elapsed = max(0.001, CFAbsoluteTimeGetCurrent() - startClock)
                        let fps = Double(frameIndex) / elapsed
                        let prog = min(0.99, Double(frameIndex) / Double(estTotal))
                        await onProgress(prog, frameIndex, estTotal, fps)
                    }
                }

                if Task.isCancelled {
                    audioTask.cancel()
                    reader.cancelReading()
                    exporter.cancelExport()
                    exporterR?.cancelExport()
                    try? FileManager.default.removeItem(at: separateLeftURL)
                    if isSeparate {
                        try? FileManager.default.removeItem(at: separateRightURL)
                    }
                    resumeOnce(.failure(CancellationError()))
                    return
                }

                await audioTask.value
                await onProgress(1.0, frameIndex, max(frameIndex, estTotal), Double(frameIndex) / max(0.001, CFAbsoluteTimeGetCurrent() - startClock))
                exporter.finishVideoPipelineExport()
                exporterR?.finishVideoPipelineExport()
            }
        }
    }

    // MARK: - Disk Space Estimation Helpers

    /// 解像度・尺・フォーマットから書き出し推定ファイルサイズ（バイト）を算出する
    public static func estimateOutputFileSizeBytes(metadata: VideoClipMetadata, format: StereoVideoExportFormat) -> Int64 {
        let pixels = Double(metadata.naturalWidth * metadata.naturalHeight)
        let resFactor = max(0.35, pixels / (1920.0 * 1080.0))
        let fpsFactor = max(0.5, metadata.nominalFPS / 30.0)
        let baseMbps: Double
        switch format {
        case .spatialVideo:   baseMbps = 32.0
        case .stereoviewCard: baseMbps = 38.0
        case .sbs:            baseMbps = 40.0
        case .lrrl:           baseMbps = 65.0
        case .separateLR:     baseMbps = 44.0
        case .dubois, .colorAnaglyph, .grayAnaglyph, .polarized, .twoD:
            baseMbps = 20.0
        }
        let totalMbps = baseMbps * resFactor * fpsFactor + (metadata.hasAudio ? 0.256 : 0.0)
        let bytesPerSec = (totalMbps * 1_000_000.0) / 8.0
        return Int64(max(1_000_000.0, bytesPerSec * max(1.0, metadata.durationSeconds)))
    }

    /// 出力先ボリュームの空き容量（バイト）を取得する
    public static func availableDiskSpaceBytes(at url: URL) -> Int64? {
        let dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let vals = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let imp = vals?.volumeAvailableCapacityForImportantUsage {
            return imp
        }
        if let cap = vals?.volumeAvailableCapacity {
            return Int64(cap)
        }
        return nil
    }

    // MARK: - Pixel Extraction & Layout Composition Helpers

    public static func extractRGB24(from cgImage: CGImage) -> [UInt8]? {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: bInfo
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            let s = i * 4
            let d = i * 3
            rgb[d] = rgba[s]
            rgb[d + 1] = rgba[s + 1]
            rgb[d + 2] = rgba[s + 2]
        }
        return rgb
    }

    private static func extractRGB24(from pixelBuffer: CVPixelBuffer) -> ([UInt8], Int, Int)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let srcPtr = base.assumingMemoryBound(to: UInt8.self)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        // kCVPixelFormatType_32BGRA → RGB24
        for y in 0..<h {
            let rowSrc = srcPtr.advanced(by: y * bpr)
            let rowDst = y * w * 3
            for x in 0..<w {
                let s = x * 4
                let d = rowDst + x * 3
                rgb[d] = rowSrc[s + 2]     // R
                rgb[d + 1] = rowSrc[s + 1] // G
                rgb[d + 2] = rowSrc[s]     // B
            }
        }
        return (rgb, w, h)
    }

    private static func composeSBSRGB(
        left: [UInt8],
        right: [UInt8],
        width w: Int,
        height h: Int,
        halfWidth: Bool
    ) -> (rgb: [UInt8], width: Int, height: Int) {
        if !halfWidth {
            let outW = w * 2
            var out = [UInt8](repeating: 0, count: outW * h * 3)
            let rowBytes = w * 3
            for y in 0..<h {
                let srcRow = y * rowBytes
                let dstRow = y * outW * 3
                out[dstRow..<(dstRow + rowBytes)] = left[srcRow..<(srcRow + rowBytes)]
                out[(dstRow + rowBytes)..<(dstRow + rowBytes * 2)] = right[srcRow..<(srcRow + rowBytes)]
            }
            return (out, outW, h)
        } else {
            let eyeW = max(1, w / 2)
            let lHalf = ViewStereoDepthSynthesizer.resizeRGB(left, width: w, height: h, targetWidth: eyeW, targetHeight: h)
            let rHalf = ViewStereoDepthSynthesizer.resizeRGB(right, width: w, height: h, targetWidth: eyeW, targetHeight: h)
            let outW = eyeW * 2
            var out = [UInt8](repeating: 0, count: outW * h * 3)
            let rowBytes = eyeW * 3
            for y in 0..<h {
                let srcRow = y * rowBytes
                let dstRow = y * outW * 3
                out[dstRow..<(dstRow + rowBytes)] = lHalf[srcRow..<(srcRow + rowBytes)]
                out[(dstRow + rowBytes)..<(dstRow + rowBytes * 2)] = rHalf[srcRow..<(srcRow + rowBytes)]
            }
            return (out, outW, h)
        }
    }
}
