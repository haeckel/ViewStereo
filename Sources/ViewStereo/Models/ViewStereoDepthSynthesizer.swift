import AppKit
import Accelerate
import CoreGraphics
import CoreML
import Foundation
import Metal
import StereoCore
import StereoStudioCore
import Vision

/// ViewStereo 向け片側画像 AI 深度推定 ＆ DIBR 2D-3D コンバージョンシンセサイザー
/// 状態の良い片側画像から、過大視差・貼り間違い・片側損傷のない高品位な新しいステレオペアを再合成する。
public final class ViewStereoDepthSynthesizer: @unchecked Sendable {
    public static let shared = ViewStereoDepthSynthesizer()

    private let stateLock = NSLock()
    private var cachedModel: MLModel? = nil
    private var cachedVNModel: VNCoreMLModel? = nil
    private var loadedModelURL: URL? = nil

    private init() {}

    /// 単眼深度推定エンジン種別
    public enum DepthEngineType: String, CaseIterable, Identifiable, Sendable {
        case depthAnythingV2 = "Depth Anything V2 (Core ML)"
        case depthPro = "Apple Depth Pro (Core ML)"
        case visionNative = "Apple Vision Neural Depth"

        public var id: String { rawValue }
    }

    /// 深度推定＋DIBR合成の結果
    public struct SynthesisResult: Sendable {
        public let leftRGB: [UInt8]
        public let rightRGB: [UInt8]
        public let disparityMap: [Float] // 0.0=奥 ~ 1.0=手前 (正規化)
        public let depthWidth: Int
        public let depthHeight: Int
        public let engineUsed: DepthEngineType
        public let inferenceTimeMs: Double
        public let synthesisTimeMs: Double
    }

    // MARK: - Model Resolution

    /// 利用可能な Core ML 深度モデルの URL を探索する
    public func resolveDepthModelURL() -> (url: URL, engine: DepthEngineType)? {
        let fm = FileManager.default

        // 1. ViewStereo 内部またはバンドルリソース
        if let u = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") {
            return (u, .depthAnythingV2)
        }
        if let u = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlpackage") {
            return (u, .depthAnythingV2)
        }
        #if SWIFT_PACKAGE
        if let u = Bundle.module.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") {
            return (u, .depthAnythingV2)
        }
        if let u = Bundle.module.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlpackage") {
            return (u, .depthAnythingV2)
        }
        #endif

        // 2. StudioModelLocator によるシリーズ横断探索 (DepthStereo / SplatStereo / StereoStudio)
        let candidates = [
            "Models/DepthAnythingV2SmallF16.mlmodelc",
            "Models/DepthAnythingV2SmallF16.mlpackage",
            "Models/DepthAnything_v2_large.mlmodelc",
            "Models/DepthAnything_v2_large.mlpackage",
            "Models/DepthAnythingV3Mono.mlmodelc",
            "Models/DepthAnythingV3Mono.mlpackage",
            "Models/DepthPro.mlmodelc",
            "Models/DepthPro.mlpackage"
        ]

        for sub in candidates {
            if let located = StudioModelLocator.locateExistingItem(
                relativeSubpath: sub,
                preferredAppFolder: "ViewStereo",
                additionalFolders: ["DepthStereo", "SplatStereo", "StereoStudio"]
            ) {
                let engine: DepthEngineType = sub.contains("DepthPro") ? .depthPro : .depthAnythingV2
                return (located.url, engine)
            }
        }

        return nil
    }

    // MARK: - Core ML Model Execution

    private func loadMLModel(url: URL) throws -> MLModel {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let existing = cachedModel, loadedModelURL == url {
            return existing
        }

        let compiledURL: URL
        if url.pathExtension.lowercased() == "mlmodelc" {
            compiledURL = url
        } else {
            let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("ViewStereoModelCache", isDirectory: true)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            compiledURL = cacheDir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).mlmodelc", isDirectory: true)
            if !FileManager.default.fileExists(atPath: compiledURL.path) {
                let temp = try MLModel.compileModel(at: url)
                try? FileManager.default.removeItem(at: compiledURL)
                try FileManager.default.moveItem(at: temp, to: compiledURL)
            }
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: compiledURL, configuration: config)
        cachedModel = model
        cachedVNModel = try? VNCoreMLModel(for: model)
        loadedModelURL = url
        return model
    }

    /// RGBバッファ (24-bit) から直接正規化 Disparity を推論する
    public func estimateDisparity(
        rgb: [UInt8],
        width: Int,
        height: Int
    ) -> (disparity: [Float], width: Int, height: Int, engine: DepthEngineType, elapsedMs: Double)? {
        guard let cgImg = Self.createCGImage(from: rgb, width: width, height: height) else {
            return nil
        }
        return estimateDisparity(cgImage: cgImg)
    }

    /// 単眼画像 (CGImage) から正規化 Disparity (0.0=奥 ~ 1.0=手前) を推論する
    public func estimateDisparity(
        cgImage: CGImage
    ) -> (disparity: [Float], width: Int, height: Int, engine: DepthEngineType, elapsedMs: Double) {
        let t0 = CFAbsoluteTimeGetCurrent()

        if let (url, engineType) = resolveDepthModelURL(),
           let model = try? loadMLModel(url: url) {
            // Core ML (Depth Anything V2 or Depth Pro)
            if let vnModel = (stateLock.withLock { cachedVNModel }) {
                if let res = try? runVisionCoreMLInference(vnModel: vnModel, cgImage: cgImage) {
                    let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                    return (res.disparity, res.width, res.height, engineType, elapsed)
                }
            }
            if let res = try? runDirectCoreMLInference(model: model, cgImage: cgImage) {
                let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                return (res.disparity, res.width, res.height, engineType, elapsed)
            }
        }

        // フォールバック: Apple Vision ネイティブ深度推定
        let res = runAppleVisionNativeDepth(cgImage: cgImage)
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        return (res.disparity, res.width, res.height, .visionNative, elapsed)
    }

    private func runVisionCoreMLInference(
        vnModel: VNCoreMLModel,
        cgImage: CGImage
    ) throws -> (disparity: [Float], width: Int, height: Int)? {
        var resultValues: [Float]? = nil
        var outW = 0
        var outH = 0

        let request = VNCoreMLRequest(model: vnModel) { req, _ in
            guard let observations = req.results as? [VNCoreMLFeatureValueObservation],
                  let feature = observations.first?.featureValue else {
                return
            }
            if let pb = feature.imageBufferValue {
                let (vals, w, h) = Self.extractFloatsFromPixelBuffer(pb)
                resultValues = vals; outW = w; outH = h
            } else if let ma = feature.multiArrayValue {
                let (vals, w, h) = Self.extractFloatsFromMultiArray(ma)
                resultValues = vals; outW = w; outH = h
            }
        }
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let vals = resultValues, outW > 0, outH > 0 else { return nil }
        return (Self.normalizeDisparity(vals), outW, outH)
    }

    private func runDirectCoreMLInference(
        model: MLModel,
        cgImage: CGImage
    ) throws -> (disparity: [Float], width: Int, height: Int)? {
        let inputDesc = model.modelDescription.inputDescriptionsByName
        let targetW: Int
        let targetH: Int
        if let imgDesc = inputDesc["image"]?.imageConstraint {
            targetW = imgDesc.pixelsWide
            targetH = imgDesc.pixelsHigh
        } else {
            targetW = 518
            targetH = 518
        }

        let inputFeature = try MLFeatureValue(
            cgImage: cgImage,
            pixelsWide: targetW,
            pixelsHigh: targetH,
            pixelFormatType: kCVPixelFormatType_32BGRA,
            options: nil
        )
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": inputFeature])
        let prediction = try model.prediction(from: provider)

        for name in prediction.featureNames {
            if let fv = prediction.featureValue(for: name) {
                if let ma = fv.multiArrayValue {
                    let (vals, w, h) = Self.extractFloatsFromMultiArray(ma)
                    if w > 0, h > 0 {
                        return (Self.normalizeDisparity(vals), w, h)
                    }
                } else if let pb = fv.imageBufferValue {
                    let (vals, w, h) = Self.extractFloatsFromPixelBuffer(pb)
                    if w > 0, h > 0 {
                        return (Self.normalizeDisparity(vals), w, h)
                    }
                }
            }
        }
        return nil
    }

    /// Core ML 未導入時の即時フォールバック: Apple Vision ネイティブ深度
    private func runAppleVisionNativeDepth(
        cgImage: CGImage
    ) -> (disparity: [Float], width: Int, height: Int) {
        let w = cgImage.width
        let h = cgImage.height
        let targetW = min(512, max(128, w / 4))
        let targetH = min(512, max(128, h / 4))
        let total = targetW * targetH

        // 垂直線形グラデーション（上0.1=奥, 下0.6=手前）をベースとする
        var depth = [Float](repeating: 0, count: total)
        for y in 0..<targetH {
            let v = Float(y) / Float(max(1, targetH - 1))
            let baseDisp = 0.15 + v * 0.45
            for x in 0..<targetW {
                depth[y * targetW + x] = baseDisp
            }
        }

        // 人物セグメンテーションによる前景ボーナス加算
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let personReq = VNGeneratePersonSegmentationRequest()
        personReq.qualityLevel = .balanced
        if (try? handler.perform([personReq])) != nil,
           let mask = personReq.results?.first {
            let pb = mask.pixelBuffer
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let mw = CVPixelBufferGetWidth(pb)
            let mh = CVPixelBufferGetHeight(pb)
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let ptr = base.assumingMemoryBound(to: Float.self)
                for y in 0..<targetH {
                    let my = min(mh - 1, (y * mh) / targetH)
                    for x in 0..<targetW {
                        let mx = min(mw - 1, (x * mw) / targetW)
                        let pWeight = ptr[my * mw + mx]
                        if pWeight > 0.1 {
                            depth[y * targetW + x] += pWeight * 0.40
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }

        // Attention Saliency（主被写体注目度）の加算
        let salReq = VNGenerateAttentionBasedSaliencyImageRequest()
        if (try? handler.perform([salReq])) != nil,
           let salObs = salReq.results?.first {
            let pb = salObs.pixelBuffer
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let sw = CVPixelBufferGetWidth(pb)
            let sh = CVPixelBufferGetHeight(pb)
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let ptr = base.assumingMemoryBound(to: Float.self)
                for y in 0..<targetH {
                    let sy = min(sh - 1, (y * sh) / targetH)
                    for x in 0..<targetW {
                        let sx = min(sw - 1, (x * sw) / targetW)
                        let sVal = ptr[sy * sw + sx]
                        if sVal > 0.2 {
                            depth[y * targetW + x] += sVal * 0.25
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }

        return (Self.normalizeDisparity(depth), targetW, targetH)
    }

    // MARK: - Sparse Stereo Guided Calibration (実視差ガイド較正)

    /// 元ペアの SIFT インライア視差サンプルを用いて、単眼AI深度マップの遠近スケールを較正する
    public static func calibrateWithSparseStereo(
        disparityMap: [Float],
        depthW: Int,
        depthH: Int,
        sparseSamples: [DisparitySample],
        imageWidth: Double,
        imageHeight: Double
    ) -> [Float] {
        guard sparseSamples.count >= 12, depthW > 0, depthH > 0, imageWidth > 0, imageHeight > 0 else {
            return disparityMap
        }

        // 各サンプル点における (AI視差 d_ai, 実測視差 p_real) のペアを収集
        var pairs: [(ai: Double, real: Double)] = []
        pairs.reserveCapacity(sparseSamples.count)

        for s in sparseSamples {
            let u = min(depthW - 1, max(0, Int((s.x / imageWidth) * Double(depthW))))
            let v = min(depthH - 1, max(0, Int((s.y / imageHeight) * Double(depthH))))
            let dAI = Double(disparityMap[v * depthW + u])
            // 実測視差 s.parallax (正視規約: 手前ほど負、奥ほど正の場合があるので正規化)
            pairs.append((ai: dAI, real: -s.parallax))
        }

        guard pairs.count >= 10 else { return disparityMap }

        // ロバスト中央値/線形回帰 (実測視差とAI視差のスケール関係を学習)
        let n = Double(pairs.count)
        let meanAI = pairs.reduce(0.0) { $0 + $1.ai } / n
        let meanReal = pairs.reduce(0.0) { $0 + $1.real } / n

        var cov = 0.0, varAI = 0.0
        for p in pairs {
            let dai = p.ai - meanAI
            let dreal = p.real - meanReal
            cov += dai * dreal
            varAI += dai * dai
        }

        guard varAI > 1e-6 else { return disparityMap }
        let slope = cov / varAI

        // 正の相関（AIと実測視差の向きが一致）がある場合のみ、AI深度を微調整
        if slope > 0.05 {
            let intercept = meanReal - slope * meanAI
            var calibrated = [Float](repeating: 0, count: disparityMap.count)
            for i in 0..<disparityMap.count {
                let v = slope * Double(disparityMap[i]) + intercept
                calibrated[i] = Float(v)
            }
            return normalizeDisparity(calibrated)
        }

        return disparityMap
    }

    // MARK: - DIBR Stereo Synthesis (対称ステレオペア合成)

    /// 単眼RGBバッファと深度マップから、指定の視差率（快適帯域）で左右ステレオペアを合成する
    public func synthesizeStereoPair(
        baseRGB: [UInt8],
        width: Int,
        height: Int,
        disparityMap: [Float],
        depthW: Int,
        depthH: Int,
        targetDisparityPercent: Double = 3.0,
        depthGamma: Double = 1.0,
        depthContrast: Double = 0.0,
        focusRatio: Double = 0.20 // ゼロ視差面 (手前20%を画面窓に接地)
    ) -> (leftRGB: [UInt8], rightRGB: [UInt8]) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let count = width * height
        guard baseRGB.count >= count * 3, depthW > 0, depthH > 0 else {
            return (baseRGB, baseRGB)
        }

        // 1. 最大両眼視差量 (ピクセル単位)
        // targetDisparityPercent (例 3.0%) -> 画面幅に対する最大視差 B px
        let maxBaselinePx = Float(width) * Float(max(0.2, min(8.0, targetDisparityPercent)) / 100.0)
        let halfBaseline = maxBaselinePx * 0.5

        // 2. 深度マップのガンマ・S字コントラスト・フォーカス面の適用テーブル
        let focusVal = Float(max(0.05, min(0.95, focusRatio)))

        // 3. 左右対称 DIBR ワーピングバッファの確保
        var leftRGB = [UInt8](repeating: 0, count: count * 3)
        var rightRGB = [UInt8](repeating: 0, count: count * 3)

        // 深度マップを高速サンプリングするためのヘルパー
        func sampleDisparity(u: Float, v: Float) -> Float {
            let x = min(Float(depthW - 1), max(0.0, u * Float(depthW)))
            let y = min(Float(depthH - 1), max(0.0, v * Float(depthH)))
            let x0 = Int(x)
            let y0 = Int(y)
            let x1 = min(depthW - 1, x0 + 1)
            let y1 = min(depthH - 1, y0 + 1)
            let fx = x - Float(x0)
            let fy = y - Float(y0)

            let row0 = y0 * depthW
            let row1 = y1 * depthW
            let d00 = disparityMap[row0 + x0]
            let d10 = disparityMap[row0 + x1]
            let d01 = disparityMap[row1 + x0]
            let d11 = disparityMap[row1 + x1]

            var d = (1.0 - fy) * ((1.0 - fx) * d00 + fx * d10) + fy * ((1.0 - fx) * d01 + fx * d11)

            // ガンマ補正
            if abs(depthGamma - 1.0) > 0.01 {
                d = pow(max(0.0001, d), Float(1.0 / max(0.2, depthGamma)))
            }
            // コントラスト
            if abs(depthContrast) > 0.01 {
                let s = d * d * (3.0 - 2.0 * d)
                d = (1.0 - Float(depthContrast)) * d + Float(depthContrast) * s
            }
            return min(1.0, max(0.0, d))
        }

        // 高速並列行スキャンによる対称 1D DIBR レイマーチング
        let fWidth = Float(width)
        let fHeight = Float(height)

        DispatchQueue.concurrentPerform(iterations: height) { y in
            let v = Float(y) / fHeight
            let rowBase = y * width * 3

            for x in 0..<width {
                let u = Float(x) / fWidth
                let d = sampleDisparity(u: u, v: v)
                // ゼロ視差面からのオフセット: 手前(d > focusVal)は飛び出し、奥(d < focusVal)は引き込み
                let dispOffset = (d - focusVal) * halfBaseline

                // 左眼: +dispOffset, 右眼: -dispOffset
                let srcXL = Float(x) - dispOffset
                let srcXR = Float(x) + dispOffset

                // 左眼ピクセルのサンプリング
                let clXL = min(Float(width - 1), max(0.0, srcXL))
                let ixL0 = Int(clXL)
                let ixL1 = min(width - 1, ixL0 + 1)
                let fxL = clXL - Float(ixL0)
                let lIdx0 = (y * width + ixL0) * 3
                let lIdx1 = (y * width + ixL1) * 3
                let dstL = rowBase + x * 3

                leftRGB[dstL] = UInt8(clamping: Int(Float(baseRGB[lIdx0]) * (1.0 - fxL) + Float(baseRGB[lIdx1]) * fxL))
                leftRGB[dstL + 1] = UInt8(clamping: Int(Float(baseRGB[lIdx0 + 1]) * (1.0 - fxL) + Float(baseRGB[lIdx1 + 1]) * fxL))
                leftRGB[dstL + 2] = UInt8(clamping: Int(Float(baseRGB[lIdx0 + 2]) * (1.0 - fxL) + Float(baseRGB[lIdx1 + 2]) * fxL))

                // 右眼ピクセルのサンプリング
                let clXR = min(Float(width - 1), max(0.0, srcXR))
                let ixR0 = Int(clXR)
                let ixR1 = min(width - 1, ixR0 + 1)
                let fxR = clXR - Float(ixR0)
                let rIdx0 = (y * width + ixR0) * 3
                let rIdx1 = (y * width + ixR1) * 3
                let dstR = rowBase + x * 3

                rightRGB[dstR] = UInt8(clamping: Int(Float(baseRGB[rIdx0]) * (1.0 - fxR) + Float(baseRGB[rIdx1]) * fxR))
                rightRGB[dstR + 1] = UInt8(clamping: Int(Float(baseRGB[rIdx0 + 1]) * (1.0 - fxR) + Float(baseRGB[rIdx1 + 1]) * fxR))
                rightRGB[dstR + 2] = UInt8(clamping: Int(Float(baseRGB[rIdx0 + 2]) * (1.0 - fxR) + Float(baseRGB[rIdx1 + 2]) * fxR))
            }
        }

        return (leftRGB, rightRGB)
    }

    // MARK: - Utilities

    public static func createCGImage(from rgb: [UInt8], width: Int, height: Int) -> CGImage? {
        guard rgb.count >= width * height * 3, width > 0, height > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let cfData = CFDataCreate(kCFAllocatorDefault, rgb, rgb.count)!
        guard let provider = CGDataProvider(data: cfData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: width * 3,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// RGB 画像のリサイズ (Bilinear)
    public static func resizeRGB(_ rgb: [UInt8], width: Int, height: Int, targetWidth tw: Int, targetHeight th: Int) -> [UInt8] {
        guard width > 0, height > 0, tw > 0, th > 0, rgb.count >= width * height * 3 else { return [] }
        if width == tw && height == th { return rgb }

        var out = [UInt8](repeating: 0, count: tw * th * 3)
        let scaleX = Float(width - 1) / Float(max(1, tw - 1))
        let scaleY = Float(height - 1) / Float(max(1, th - 1))

        DispatchQueue.concurrentPerform(iterations: th) { y in
            let srcY = Float(y) * scaleY
            let y0 = Int(srcY)
            let y1 = min(height - 1, y0 + 1)
            let fy = srcY - Float(y0)
            let rowDst = y * tw * 3

            for x in 0..<tw {
                let srcX = Float(x) * scaleX
                let x0 = Int(srcX)
                let x1 = min(width - 1, x0 + 1)
                let fx = srcX - Float(x0)

                let idx00 = (y0 * width + x0) * 3
                let idx10 = (y0 * width + x1) * 3
                let idx01 = (y1 * width + x0) * 3
                let idx11 = (y1 * width + x1) * 3
                let dst = rowDst + x * 3

                for c in 0..<3 {
                    let v00 = Float(rgb[idx00 + c])
                    let v10 = Float(rgb[idx10 + c])
                    let v01 = Float(rgb[idx01 + c])
                    let v11 = Float(rgb[idx11 + c])
                    let top = (1.0 - fx) * v00 + fx * v10
                    let bot = (1.0 - fx) * v01 + fx * v11
                    out[dst + c] = UInt8(clamping: Int((1.0 - fy) * top + fy * bot))
                }
            }
        }
        return out
    }

    private static func normalizeDisparity(_ raw: [Float]) -> [Float] {
        guard !raw.isEmpty else { return [] }
        var minVal = Float.greatestFiniteMagnitude
        var maxVal = -Float.greatestFiniteMagnitude
        for v in raw {
            if v.isFinite {
                if v < minVal { minVal = v }
                if v > maxVal { maxVal = v }
            }
        }
        let range = maxVal - minVal
        guard range > 1e-6 else {
            return [Float](repeating: 0.5, count: raw.count)
        }
        var out = [Float](repeating: 0, count: raw.count)
        for i in 0..<raw.count {
            let v = raw[i]
            if v.isFinite {
                out[i] = (v - minVal) / range
            } else {
                out[i] = 0.0
            }
        }
        return out
    }

    private static func extractFloatsFromMultiArray(_ ma: MLMultiArray) -> (values: [Float], width: Int, height: Int) {
        let shape = ma.shape.map { $0.intValue }
        guard shape.count >= 2 else { return ([], 0, 0) }
        let h = shape[shape.count - 2]
        let w = shape[shape.count - 1]
        let total = w * h
        var result = [Float](repeating: 0, count: total)

        let ptr32 = ma.dataPointer.assumingMemoryBound(to: Float.self)
        if ma.dataType == .float32 {
            for i in 0..<total {
                result[i] = ptr32[i]
            }
        } else if ma.dataType == .float16 {
            let ptr16 = ma.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<total {
                result[i] = Float(ptr16[i])
            }
        }
        return (result, w, h)
    }

    private static func extractFloatsFromPixelBuffer(_ pb: CVPixelBuffer) -> (values: [Float], width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let total = w * h
        var result = [Float](repeating: 0, count: total)

        guard let base = CVPixelBufferGetBaseAddress(pb) else { return ([], 0, 0) }
        let format = CVPixelBufferGetPixelFormatType(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)

        if format == kCVPixelFormatType_DepthFloat32 || format == kCVPixelFormatType_DisparityFloat32 || format == kCVPixelFormatType_OneComponent32Float {
            for y in 0..<h {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: Float.self)
                for x in 0..<w {
                    result[y * w + x] = row[x]
                }
            }
        } else if format == kCVPixelFormatType_DepthFloat16 || format == kCVPixelFormatType_DisparityFloat16 || format == kCVPixelFormatType_OneComponent16Half {
            for y in 0..<h {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: Float16.self)
                for x in 0..<w {
                    result[y * w + x] = Float(row[x])
                }
            }
        } else if format == kCVPixelFormatType_OneComponent8 {
            for y in 0..<h {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    result[y * w + x] = Float(row[x]) / 255.0
                }
            }
        }
        return (result, w, h)
    }
}
