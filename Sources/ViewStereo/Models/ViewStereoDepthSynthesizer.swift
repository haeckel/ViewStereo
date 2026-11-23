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
/// 全9種の単眼深度推定 Core ML エンジン（Depth Anything V2/V3 / MoGe-2 / Apple Depth Pro / Depth Pro 2）および
/// Apple Vision ネイティブ深度に対応し、状態の良い片側画像から新しいステレオペアを再合成する。
///
/// ViewStereo 統一視差規約: `0.0 = 奥 (無限遠 / 最遠背景) 〜 1.0 = 手前 (最近接前景)`
public final class ViewStereoDepthSynthesizer: @unchecked Sendable {
    public static let shared = ViewStereoDepthSynthesizer()

    private let stateLock = NSLock()
    private var cachedModel: MLModel? = nil
    private var cachedVNModel: VNCoreMLModel? = nil
    private var loadedModelURL: URL? = nil
    private var loadedComputeUnits: MLComputeUnits? = nil

    private init() {}

    /// 単眼深度推定エンジン種別（互換維持用サマリー型）
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

    // MARK: - Memory Management

    /// キャッシュ中の Core ML モデルをメモリから解放する
    public func releaseCachedModels() {
        stateLock.lock()
        cachedModel = nil
        cachedVNModel = nil
        loadedModelURL = nil
        loadedComputeUnits = nil
        stateLock.unlock()
    }

    // MARK: - Model Resolution

    /// 互換用: デフォルト優先エンジンでモデル URL を探索する
    public func resolveDepthModelURL() -> (url: URL, engine: DepthEngineType)? {
        guard let res = resolveDepthModelURL(preferredEngine: .depthAnythingV2Small) else {
            return nil
        }
        let compat: DepthEngineType = res.engine.isAppleEngine ? .depthPro : .depthAnythingV2
        return (res.url, compat)
    }

    /// 指定の優先エンジン（未導入時は他のインストール済みエンジンへフォールバック）のモデル URL を探索する
    public func resolveDepthModelURL(
        preferredEngine: StudioDepthEngine
    ) -> (url: URL, engine: StudioDepthEngine, isFallback: Bool)? {
        // 1. 優先エンジンを検索（バンドル + シリーズ横断共有フォルダ）
        if let url = locateModelURL(for: preferredEngine) {
            return (url, preferredEngine, false)
        }

        // 2. 優先エンジンが未導入の場合、インストール済みの他エンジンから安全な順でフォールバック
        let fallbackOrder: [StudioDepthEngine] = [
            .depthAnythingV2Small,
            .depthPro2Large,
            .depthPro2Base,
            .depthPro2Small,
            .depthAnythingV3Mono,
            .depthAnythingV2Large,
            .moge2ViTL,
            .moge2ViTB,
            .depthPro
        ]
        for candidate in fallbackOrder where candidate != preferredEngine {
            if let url = locateModelURL(for: candidate) {
                return (url, candidate, true)
            }
        }

        return nil
    }

    private func locateModelURL(for engine: StudioDepthEngine) -> URL? {
        // バンドル内チェック
        for fileName in engine.candidateFileNames {
            let ns = fileName as NSString
            let base = (ns.lastPathComponent as NSString).deletingPathExtension
            let ext = ns.pathExtension
            if !base.isEmpty, !ext.isEmpty {
                if let u = Bundle.main.url(forResource: base, withExtension: ext) {
                    return u
                }
                #if SWIFT_PACKAGE
                if let u = Bundle.module.url(forResource: base, withExtension: ext) {
                    return u
                }
                #endif
            }
        }

        // StudioModelLocator によるシリーズ横断探索 (ViewStereo / DepthStereo / PanorStereo / SplatStereo / StereoStudio)
        return engine.locateInstalledModel(preferredAppFolder: "ViewStereo")?.url
    }

    // MARK: - Core ML Model Loading

    private func loadMLModel(url: URL, engine: StudioDepthEngine) throws -> MLModel {
        let targetUnits: MLComputeUnits = engine.prefersCPUAndGPU ? .cpuAndGPU : .all

        stateLock.lock()
        if let existing = cachedModel, loadedModelURL == url, loadedComputeUnits == targetUnits {
            stateLock.unlock()
            return existing
        }
        stateLock.unlock()

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
        config.computeUnits = targetUnits
        let model = try MLModel(contentsOf: compiledURL, configuration: config)

        stateLock.lock()
        cachedModel = model
        cachedVNModel = (engine == .depthAnythingV2Small || engine == .depthAnythingV2Large)
            ? (try? VNCoreMLModel(for: model))
            : nil
        loadedModelURL = url
        loadedComputeUnits = targetUnits
        stateLock.unlock()

        return model
    }

    // MARK: - Disparity Estimation Public API

    /// 優先エンジンとメモリ自動解放ポリシーを指定して RGB バッファから正規化 Disparity (0.0=奥 ~ 1.0=手前) を推論する
    public func estimateDisparity(
        rgb: [UInt8],
        width: Int,
        height: Int,
        preferredEngine: StudioDepthEngine,
        releaseAfterInference: Bool
    ) -> (disparity: [Float], width: Int, height: Int, engineName: String, coreMLEngine: StudioDepthEngine?, elapsedMs: Double)? {
        guard let cgImg = Self.createCGImage(from: rgb, width: width, height: height) else {
            return nil
        }
        return estimateDisparity(
            cgImage: cgImg,
            preferredEngine: preferredEngine,
            releaseAfterInference: releaseAfterInference
        )
    }

    /// 優先エンジンとメモリ自動解放ポリシーを指定して CGImage から正規化 Disparity (0.0=奥 ~ 1.0=手前) を推論する
    public func estimateDisparity(
        cgImage: CGImage,
        preferredEngine: StudioDepthEngine,
        releaseAfterInference: Bool
    ) -> (disparity: [Float], width: Int, height: Int, engineName: String, coreMLEngine: StudioDepthEngine?, elapsedMs: Double) {
        let t0 = CFAbsoluteTimeGetCurrent()

        defer {
            if releaseAfterInference {
                releaseCachedModels()
            }
        }

        if let resolved = resolveDepthModelURL(preferredEngine: preferredEngine),
           let model = try? loadMLModel(url: resolved.url, engine: resolved.engine) {
            if let res = runEngineSpecificInference(model: model, engine: resolved.engine, cgImage: cgImage) {
                let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                let label = resolved.isFallback
                    ? "\(resolved.engine.shortLabel) [Fallback]"
                    : resolved.engine.shortLabel
                return (res.disparity, res.width, res.height, label, resolved.engine, elapsed)
            }
        }

        // フォールバック: Apple Vision ネイティブ深度推定
        let res = runAppleVisionNativeDepth(cgImage: cgImage)
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        return (res.disparity, res.width, res.height, DepthEngineType.visionNative.rawValue, nil, elapsed)
    }

    /// 後方互換用: RGB バッファから推論
    public func estimateDisparity(
        rgb: [UInt8],
        width: Int,
        height: Int
    ) -> (disparity: [Float], width: Int, height: Int, engine: DepthEngineType, elapsedMs: Double)? {
        guard let res = estimateDisparity(
            rgb: rgb,
            width: width,
            height: height,
            preferredEngine: .depthAnythingV2Small,
            releaseAfterInference: false
        ) else {
            return nil
        }
        let compatEngine: DepthEngineType
        if let ml = res.coreMLEngine {
            compatEngine = ml.isAppleEngine ? .depthPro : .depthAnythingV2
        } else {
            compatEngine = .visionNative
        }
        return (res.disparity, res.width, res.height, compatEngine, res.elapsedMs)
    }

    /// 後方互換用: CGImage から推論
    public func estimateDisparity(
        cgImage: CGImage
    ) -> (disparity: [Float], width: Int, height: Int, engine: DepthEngineType, elapsedMs: Double) {
        let res = estimateDisparity(
            cgImage: cgImage,
            preferredEngine: .depthAnythingV2Small,
            releaseAfterInference: false
        )
        let compatEngine: DepthEngineType
        if let ml = res.coreMLEngine {
            compatEngine = ml.isAppleEngine ? .depthPro : .depthAnythingV2
        } else {
            compatEngine = .visionNative
        }
        return (res.disparity, res.width, res.height, compatEngine, res.elapsedMs)
    }

    /// 動画セッション向け：未正規化（大きいほど手前）の生視差データとパーセンタイル範囲
    public struct RawVideoDepthFrame: Sendable {
        public let rawDisparity: [Float]
        public let width: Int
        public let height: Int
        public let pLow: Float
        public let pHigh: Float
        public let validMask: [Bool]?
        public let engineName: String
        public let coreMLEngine: StudioDepthEngine?
    }

    /// 動画セッション用モデル解決＆ロード（動画処理中はモデルをキャッシュ常駐させる）
    public func prepareVideoEngine(
        preferredEngine: StudioDepthEngine
    ) -> (model: MLModel, engine: StudioDepthEngine, isFallback: Bool)? {
        guard let resolved = resolveDepthModelURL(preferredEngine: preferredEngine),
              let model = try? loadMLModel(url: resolved.url, engine: resolved.engine) else {
            return nil
        }
        return (model, resolved.engine, resolved.isFallback)
    }

    /// Depth Pro 2 動画セッション用の MLState を新規生成（macOS 15+）
    public func makeVideoInferenceState(for model: MLModel, engine: StudioDepthEngine) -> AnyObject? {
        if #available(macOS 15.0, *), engine.isDepthPro2Engine {
            return model.makeState()
        }
        return nil
    }

    /// 動画フレーム1枚分の未正規化視差値とパーセンタイルを推論する（Depth Pumping 防止のため正規化はセッション側で行う）
    public func estimateRawVideoDepth(
        cgImage: CGImage,
        prepared: (model: MLModel, engine: StudioDepthEngine, isFallback: Bool)?,
        externalState: AnyObject?
    ) -> RawVideoDepthFrame {
        if let prep = prepared {
            let label = prep.isFallback ? "\(prep.engine.shortLabel) [Fallback]" : prep.engine.shortLabel
            do {
                switch prep.engine {
                case .depthPro2Small, .depthPro2Base, .depthPro2Large:
                    let raw = try runDepthPro2RawInference(model: prep.model, cgImage: cgImage, externalState: externalState)
                    let (pLow, pHigh) = Self.computeRobustPercentiles(raw.values, positiveOnly: true)
                    return RawVideoDepthFrame(rawDisparity: raw.values, width: raw.width, height: raw.height, pLow: pLow, pHigh: pHigh, validMask: nil, engineName: label, coreMLEngine: prep.engine)

                case .depthPro:
                    let rawMeters = try runDepthProRawMeters(model: prep.model, cgImage: cgImage)
                    let invDisp = rawMeters.values.map { m -> Float in
                        let c: Float = (m.isFinite && m > 0.01) ? m : 100.0
                        return 1.0 / c
                    }
                    let (pLow, pHigh) = Self.computeRobustPercentiles(invDisp, positiveOnly: true)
                    return RawVideoDepthFrame(rawDisparity: invDisp, width: rawMeters.width, height: rawMeters.height, pLow: pLow, pHigh: pHigh, validMask: nil, engineName: label, coreMLEngine: prep.engine)

                case .moge2ViTB, .moge2ViTL:
                    let defaultSize = (prep.engine == .moge2ViTL) ? 1104 : 504
                    let res = try runMoGeRawInference(model: prep.model, cgImage: cgImage, defaultSize: defaultSize)
                    var validSamples = [Float]()
                    let step = max(1, res.invDisp.count / 65536)
                    for i in stride(from: 0, to: res.invDisp.count, by: step) where res.validMask[i] {
                        validSamples.append(res.invDisp[i])
                    }
                    let (pLow, pHigh) = Self.computeRobustPercentiles(validSamples.isEmpty ? res.invDisp : validSamples, positiveOnly: true)
                    return RawVideoDepthFrame(rawDisparity: res.invDisp, width: res.width, height: res.height, pLow: pLow, pHigh: pHigh, validMask: res.validMask, engineName: label, coreMLEngine: prep.engine)

                case .depthAnythingV3Mono:
                    let res = try runUniversalDepthInference(model: prep.model, cgImage: cgImage, isDirectDepth: true, defaultSize: 504)
                    return RawVideoDepthFrame(rawDisparity: res.disparity, width: res.width, height: res.height, pLow: 0.0, pHigh: 1.0, validMask: nil, engineName: label, coreMLEngine: prep.engine)

                case .depthAnythingV2Small, .depthAnythingV2Large:
                    if let vnModel = (stateLock.withLock { cachedVNModel }),
                       let visionRes = try? runVisionCoreMLInference(vnModel: vnModel, cgImage: cgImage) {
                        return RawVideoDepthFrame(rawDisparity: visionRes.disparity, width: visionRes.width, height: visionRes.height, pLow: 0.0, pHigh: 1.0, validMask: nil, engineName: label, coreMLEngine: prep.engine)
                    }
                    let res = try runUniversalDepthInference(model: prep.model, cgImage: cgImage, isDirectDepth: false, defaultSize: 518)
                    return RawVideoDepthFrame(rawDisparity: res.disparity, width: res.width, height: res.height, pLow: 0.0, pHigh: 1.0, validMask: nil, engineName: label, coreMLEngine: prep.engine)
                }
            } catch {
                print("[ViewStereoDepthSynthesizer] Video inference fallback (\(label)): \(error.localizedDescription)")
            }
        }

        let vis = runAppleVisionNativeDepth(cgImage: cgImage)
        return RawVideoDepthFrame(rawDisparity: vis.disparity, width: vis.width, height: vis.height, pLow: 0.0, pHigh: 1.0, validMask: nil, engineName: DepthEngineType.visionNative.rawValue, coreMLEngine: nil)
    }

    // MARK: - Engine-Specific Core ML Inference Dispatch

    private func runEngineSpecificInference(
        model: MLModel,
        engine: StudioDepthEngine,
        cgImage: CGImage
    ) -> (disparity: [Float], width: Int, height: Int)? {
        do {
            switch engine {
            case .depthPro2Small, .depthPro2Base, .depthPro2Large:
                return try runDepthPro2Inference(model: model, cgImage: cgImage)

            case .depthPro:
                return try runDepthProInference(model: model, cgImage: cgImage)

            case .moge2ViTB, .moge2ViTL:
                let defaultSize = (engine == .moge2ViTL) ? 1104 : 504
                return try runMoGeInference(model: model, cgImage: cgImage, defaultSize: defaultSize)

            case .depthAnythingV3Mono:
                return try runUniversalDepthInference(model: model, cgImage: cgImage, isDirectDepth: true, defaultSize: 504)

            case .depthAnythingV2Small, .depthAnythingV2Large:
                if let vnModel = (stateLock.withLock { cachedVNModel }),
                   let visionRes = try? runVisionCoreMLInference(vnModel: vnModel, cgImage: cgImage) {
                    return visionRes
                }
                return try runUniversalDepthInference(model: model, cgImage: cgImage, isDirectDepth: false, defaultSize: 518)
            }
        } catch {
            print("[ViewStereoDepthSynthesizer] Inference error (\(engine.shortLabel)): \(error.localizedDescription)")
            return nil
        }
    }

    /// Apple Depth Pro 2 (inverse_depth 出力、外部 MLState またはフレッシュな MLState を使用)
    private func runDepthPro2Inference(
        model: MLModel,
        cgImage: CGImage,
        externalState: AnyObject? = nil
    ) throws -> (disparity: [Float], width: Int, height: Int) {
        let raw = try runDepthPro2RawInference(model: model, cgImage: cgImage, externalState: externalState)
        // inverse_depth は値が大きいほど手前 → 正値の2%~98%パーセンタイル正規化で [0=奥, 1=手前] に統一
        let norm = Self.normalizePositiveDisparityRobust(raw.values)
        return (norm, raw.width, raw.height)
    }

    private func runDepthPro2RawInference(
        model: MLModel,
        cgImage: CGImage,
        externalState: AnyObject?
    ) throws -> (values: [Float], width: Int, height: Int) {
        let inputDescs = model.modelDescription.inputDescriptionsByName
        let frameDesc = inputDescs["frame"]?.multiArrayConstraint
        let shape = frameDesc?.shape.map { $0.intValue } ?? []
        let targetH = shape.count >= 4 && shape[2] > 0 ? shape[2] : 480
        let targetW = shape.count >= 4 && shape[3] > 0 ? shape[3] : 854
        let dataType = frameDesc?.dataType ?? .float16

        let frameArray = try Self.createRGBMultiArray(
            from: cgImage,
            width: targetW,
            height: targetH,
            shape: [1, 3, NSNumber(value: targetH), NSNumber(value: targetW)],
            dataType: dataType,
            isNHWC: false
        )

        let inputProvider = try MLDictionaryFeatureProvider(dictionary: [
            "frame": MLFeatureValue(multiArray: frameArray)
        ])

        let prediction: MLFeatureProvider
        if #available(macOS 15.0, *) {
            let state = (externalState as? MLState) ?? model.makeState()
            prediction = try model.prediction(from: inputProvider, using: state)
        } else {
            prediction = try model.prediction(from: inputProvider)
        }

        var extracted: (values: [Float], width: Int, height: Int)?
        if prediction.featureNames.contains("inverse_depth"),
           let fVal = prediction.featureValue(for: "inverse_depth") {
            if let ma = fVal.multiArrayValue {
                extracted = Self.extractChannelFloats(from: ma, channelIndex: 0)
            } else if let pb = fVal.imageBufferValue {
                extracted = Self.extractFloatsFromPixelBuffer(pb)
            }
        }
        if extracted == nil {
            for name in prediction.featureNames {
                if let ma = prediction.featureValue(for: name)?.multiArrayValue, ma.shape.count >= 2 {
                    extracted = Self.extractChannelFloats(from: ma, channelIndex: 0)
                    break
                }
            }
        }

        guard let raw = extracted, raw.width > 0, raw.height > 0 else {
            throw NSError(domain: "ViewStereoDepthSynthesizer", code: -41, userInfo: [NSLocalizedDescriptionKey: "Missing inverse_depth output from Depth Pro 2"])
        }
        return raw
    }

    private func runDepthProRawMeters(
        model: MLModel,
        cgImage: CGImage
    ) throws -> (values: [Float], width: Int, height: Int) {
        let targetW = 1536
        let targetH = 1536
        let origW = Float(cgImage.width)

        let pixelBuffer = try Self.createResizedPixelBuffer(from: cgImage, width: targetW, height: targetH)
        let origWidthDesc = model.modelDescription.inputDescriptionsByName["originalWidth"]
        let origWidthType = origWidthDesc?.multiArrayConstraint?.dataType ?? .float16
        let origWidthArray = try MLMultiArray(shape: [1, 1, 1, 1], dataType: origWidthType)
        origWidthArray[[0, 0, 0, 0] as [NSNumber]] = NSNumber(value: origW)

        let inputProvider = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: pixelBuffer),
            "originalWidth": MLFeatureValue(multiArray: origWidthArray)
        ])
        let prediction = try model.prediction(from: inputProvider)

        guard let depthMetersMA = prediction.featureValue(for: "depthMeters")?.multiArrayValue else {
            throw NSError(domain: "ViewStereoDepthSynthesizer", code: -21, userInfo: [NSLocalizedDescriptionKey: "Missing depthMeters output from DepthPro"])
        }

        return Self.extractChannelFloats(from: depthMetersMA, channelIndex: 0)
    }

    private func runMoGeRawInference(
        model: MLModel,
        cgImage: CGImage,
        defaultSize: Int
    ) throws -> (invDisp: [Float], validMask: [Bool], width: Int, height: Int) {
        let inputProvider = try Self.prepareUniversalInputProvider(for: model, cgImage: cgImage, defaultSize: defaultSize)
        let prediction = try model.prediction(from: inputProvider)
        let outNames = prediction.featureNames

        var depthData: (values: [Float], width: Int, height: Int)?
        if outNames.contains("depth"), let fVal = prediction.featureValue(for: "depth") {
            if let ma = fVal.multiArrayValue {
                depthData = Self.extractChannelFloats(from: ma, channelIndex: 0)
            } else if let pb = fVal.imageBufferValue {
                depthData = Self.extractFloatsFromPixelBuffer(pb)
            }
        }
        if depthData == nil, outNames.contains("points"),
           let pointsMA = prediction.featureValue(for: "points")?.multiArrayValue {
            depthData = Self.extractChannelFloats(from: pointsMA, channelIndex: 2)
        }
        if depthData == nil {
            for name in outNames {
                if let ma = prediction.featureValue(for: name)?.multiArrayValue, ma.shape.count >= 2 {
                    depthData = Self.extractChannelFloats(from: ma, channelIndex: 0)
                    break
                }
            }
        }

        guard let extracted = depthData, extracted.width > 0, extracted.height > 0 else {
            throw NSError(domain: "ViewStereoDepthSynthesizer", code: -30, userInfo: [NSLocalizedDescriptionKey: "Missing depth/points output from MoGe-2"])
        }

        let w = extracted.width
        let h = extracted.height
        var maskValues: [Float]? = nil
        if outNames.contains("mask"), let maskMA = prediction.featureValue(for: "mask")?.multiArrayValue {
            let exMask = Self.extractChannelFloats(from: maskMA, channelIndex: 0)
            if exMask.width == w && exMask.height == h {
                maskValues = exMask.values
            } else if exMask.width > 0 && exMask.height > 0 {
                maskValues = Self.resizeFloatMap(exMask.values, srcW: exMask.width, srcH: exMask.height, dstW: w, dstH: h)
            }
        }

        let count = extracted.values.count
        var invDisp = [Float](repeating: 0, count: count)
        var validMask = [Bool](repeating: false, count: count)
        for i in 0..<count {
            let m = extracted.values[i]
            let maskOk = (maskValues == nil) || (maskValues![i] >= 0.5)
            if maskOk && m.isFinite && m > 0.005 && m < 10000.0 {
                invDisp[i] = 1.0 / m
                validMask[i] = true
            }
        }
        return (invDisp, validMask, w, h)
    }

    private static func computeRobustPercentiles(_ raw: [Float], positiveOnly: Bool) -> (Float, Float) {
        let step = max(1, raw.count / 65536)
        var samples = [Float]()
        samples.reserveCapacity(raw.count / step + 1)
        var idx = 0
        while idx < raw.count {
            let v = raw[idx]
            if v.isFinite && (!positiveOnly || v > 0) {
                samples.append(v)
            }
            idx += step
        }
        guard !samples.isEmpty else { return (0.0, 1.0) }
        samples.sort()
        let pLow = samples[max(0, min(samples.count - 1, Int(Float(samples.count) * 0.02)))]
        let pHigh = samples[max(0, min(samples.count - 1, Int(Float(samples.count) * 0.98)))]
        return (pLow, max(pLow + 1e-6, pHigh))
    }

    /// Apple Depth Pro (1536x1536 CVPixelBuffer + originalWidth → depthMeters [m])
    private func runDepthProInference(
        model: MLModel,
        cgImage: CGImage
    ) throws -> (disparity: [Float], width: Int, height: Int) {
        let targetW = 1536
        let targetH = 1536
        let origW = Float(cgImage.width)

        let pixelBuffer = try Self.createResizedPixelBuffer(from: cgImage, width: targetW, height: targetH)
        let origWidthDesc = model.modelDescription.inputDescriptionsByName["originalWidth"]
        let origWidthType = origWidthDesc?.multiArrayConstraint?.dataType ?? .float16
        let origWidthArray = try MLMultiArray(shape: [1, 1, 1, 1], dataType: origWidthType)
        origWidthArray[[0, 0, 0, 0] as [NSNumber]] = NSNumber(value: origW)

        let inputProvider = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: pixelBuffer),
            "originalWidth": MLFeatureValue(multiArray: origWidthArray)
        ])
        let prediction = try model.prediction(from: inputProvider)

        guard let depthMetersMA = prediction.featureValue(for: "depthMeters")?.multiArrayValue else {
            throw NSError(domain: "ViewStereoDepthSynthesizer", code: -21, userInfo: [NSLocalizedDescriptionKey: "Missing depthMeters output from DepthPro"])
        }

        let extracted = Self.extractChannelFloats(from: depthMetersMA, channelIndex: 0)
        // depthMeters [m] (小さいほど手前) → 1.0 / meters (大きいほど手前) へ逆数変換し 2%~98% 正規化
        let disp = Self.normalizeMetricDepthToDisparity(extracted.values)
        return (disp, extracted.width, extracted.height)
    }

    /// MoGe-2 (ViT-B / ViT-L Normal): メトリック深度 + 空マスク (<0.5を0.0=最奥へピン留め) + 法線レリーフ
    private func runMoGeInference(
        model: MLModel,
        cgImage: CGImage,
        defaultSize: Int
    ) throws -> (disparity: [Float], width: Int, height: Int) {
        let inputProvider = try Self.prepareUniversalInputProvider(for: model, cgImage: cgImage, defaultSize: defaultSize)
        let prediction = try model.prediction(from: inputProvider)
        let outNames = prediction.featureNames

        var depthData: (values: [Float], width: Int, height: Int)?
        if outNames.contains("depth"), let fVal = prediction.featureValue(for: "depth") {
            if let ma = fVal.multiArrayValue {
                depthData = Self.extractChannelFloats(from: ma, channelIndex: 0)
            } else if let pb = fVal.imageBufferValue {
                depthData = Self.extractFloatsFromPixelBuffer(pb)
            }
        }
        if depthData == nil, outNames.contains("points"),
           let pointsMA = prediction.featureValue(for: "points")?.multiArrayValue {
            depthData = Self.extractChannelFloats(from: pointsMA, channelIndex: 2)
        }
        if depthData == nil {
            for name in outNames {
                if let ma = prediction.featureValue(for: name)?.multiArrayValue, ma.shape.count >= 2 {
                    depthData = Self.extractChannelFloats(from: ma, channelIndex: 0)
                    break
                }
            }
        }

        guard let extracted = depthData, extracted.width > 0, extracted.height > 0 else {
            throw NSError(domain: "ViewStereoDepthSynthesizer", code: -30, userInfo: [NSLocalizedDescriptionKey: "Missing depth/points output from MoGe-2"])
        }

        let w = extracted.width
        let h = extracted.height

        var maskValues: [Float]? = nil
        if outNames.contains("mask"), let maskMA = prediction.featureValue(for: "mask")?.multiArrayValue {
            let exMask = Self.extractChannelFloats(from: maskMA, channelIndex: 0)
            if exMask.width == w && exMask.height == h {
                maskValues = exMask.values
            } else if exMask.width > 0 && exMask.height > 0 {
                maskValues = Self.resizeFloatMap(exMask.values, srcW: exMask.width, srcH: exMask.height, dstW: w, dstH: h)
            }
        }

        var normalZValues: [Float]? = nil
        if outNames.contains("normal"), let normalMA = prediction.featureValue(for: "normal")?.multiArrayValue {
            let exNormalZ = Self.extractChannelFloats(from: normalMA, channelIndex: 2)
            if exNormalZ.width == w && exNormalZ.height == h {
                normalZValues = exNormalZ.values
            } else if exNormalZ.width > 0 && exNormalZ.height > 0 {
                normalZValues = Self.resizeFloatMap(exNormalZ.values, srcW: exNormalZ.width, srcH: exNormalZ.height, dstW: w, dstH: h)
            }
        }

        let disp = Self.normalizeMoGeDepthToDisparity(extracted.values, maskValues: maskValues, normalZValues: normalZValues)
        return (disp, w, h)
    }

    /// 汎用 Core ML 推論（DA3 Mono-Large 直接深度 / DAv2 Large 相対視差）
    private func runUniversalDepthInference(
        model: MLModel,
        cgImage: CGImage,
        isDirectDepth: Bool,
        defaultSize: Int
    ) throws -> (disparity: [Float], width: Int, height: Int) {
        let inputProvider = try Self.prepareUniversalInputProvider(for: model, cgImage: cgImage, defaultSize: defaultSize)
        let prediction = try model.prediction(from: inputProvider)

        var extracted: (values: [Float], width: Int, height: Int)?
        var matchedOutputName = ""
        let preferredNames = ["depth", "depthOutput", "disparity", "predicted_depth", "output"]
        for name in preferredNames where prediction.featureNames.contains(name) {
            if let fVal = prediction.featureValue(for: name) {
                if let pb = fVal.imageBufferValue {
                    extracted = Self.extractFloatsFromPixelBuffer(pb)
                    matchedOutputName = name
                    break
                } else if let ma = fVal.multiArrayValue {
                    extracted = Self.extractChannelFloats(from: ma, channelIndex: 0)
                    matchedOutputName = name
                    break
                }
            }
        }

        if extracted == nil {
            for name in prediction.featureNames {
                if let fVal = prediction.featureValue(for: name) {
                    if let pb = fVal.imageBufferValue {
                        extracted = Self.extractFloatsFromPixelBuffer(pb)
                        matchedOutputName = name
                        break
                    } else if let ma = fVal.multiArrayValue, ma.shape.count >= 2 {
                        extracted = Self.extractChannelFloats(from: ma, channelIndex: 0)
                        matchedOutputName = name
                        break
                    }
                }
            }
        }

        guard let raw = extracted, raw.width > 0, raw.height > 0 else {
            throw NSError(domain: "ViewStereoDepthSynthesizer", code: -31, userInfo: [NSLocalizedDescriptionKey: "Core ML モデルから深度出力を取得できませんでした"])
        }

        var disparity: [Float]
        if isDirectDepth && matchedOutputName != "disparity" {
            // DA3 直接深度 (小さいほど手前, 大きいほど奥) → 対数変換＋反転して [0=奥, 1=手前] へ
            disparity = Self.normalizeDA3DirectDepthToDisparity(raw.values)
            if prediction.featureNames.contains("sky"),
               let skyMA = prediction.featureValue(for: "sky")?.multiArrayValue {
                let skyData = Self.extractChannelFloats(from: skyMA, channelIndex: 0)
                let skyMap: [Float]
                if skyData.width == raw.width && skyData.height == raw.height {
                    skyMap = skyData.values
                } else if skyData.width > 0 && skyData.height > 0 {
                    skyMap = Self.resizeFloatMap(skyData.values, srcW: skyData.width, srcH: skyData.height, dstW: raw.width, dstH: raw.height)
                } else {
                    skyMap = []
                }
                if skyMap.count == disparity.count {
                    for i in 0..<disparity.count where skyMap[i] > 0.5 {
                        disparity[i] = 0.0 // ViewStereo: 0.0 = 無限遠 (空)
                    }
                }
            }
        } else {
            disparity = Self.normalizeDisparity(raw.values)
        }

        return (disparity, raw.width, raw.height)
    }

    private func runVisionCoreMLInference(
        vnModel: VNCoreMLModel,
        cgImage: CGImage
    ) throws -> (disparity: [Float], width: Int, height: Int)? {
        var resultValues: [Float]? = nil
        var outW = 0
        var outH = 0

        let request = VNCoreMLRequest(model: vnModel) { req, _ in
            if let pixelObs = req.results?.first as? VNPixelBufferObservation {
                let (vals, w, h) = Self.extractFloatsFromPixelBuffer(pixelObs.pixelBuffer)
                resultValues = vals; outW = w; outH = h
                return
            }
            if let observations = req.results as? [VNCoreMLFeatureValueObservation],
               let feature = observations.first?.featureValue {
                if let pb = feature.imageBufferValue {
                    let (vals, w, h) = Self.extractFloatsFromPixelBuffer(pb)
                    resultValues = vals; outW = w; outH = h
                } else if let ma = feature.multiArrayValue {
                    let (vals, w, h) = Self.extractChannelFloats(from: ma, channelIndex: 0)
                    resultValues = vals; outW = w; outH = h
                }
            }
        }
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let vals = resultValues, outW > 0, outH > 0 else { return nil }
        return (Self.normalizeDisparity(vals), outW, outH)
    }

    /// Core ML 未導入時の即時フォールバック: Apple Vision ネイティブ深度 (0.0=奥 ~ 1.0=手前)
    private func runAppleVisionNativeDepth(
        cgImage: CGImage
    ) -> (disparity: [Float], width: Int, height: Int) {
        let w = cgImage.width
        let h = cgImage.height
        let targetW = min(512, max(128, w / 4))
        let targetH = min(512, max(128, h / 4))
        let total = targetW * targetH

        // 垂直線形グラデーション（上0.15=奥, 下0.60=手前）をベースとする
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
            let extracted = Self.extractFloatsFromPixelBuffer(mask.pixelBuffer)
            if extracted.width > 0, extracted.height > 0 {
                let resized = Self.resizeFloatMap(extracted.values, srcW: extracted.width, srcH: extracted.height, dstW: targetW, dstH: targetH)
                for i in 0..<min(total, resized.count) {
                    if resized[i] > 0.1 {
                        depth[i] += resized[i] * 0.40
                    }
                }
            }
        }

        // Attention Saliency（主被写体注目度）の加算
        let salReq = VNGenerateAttentionBasedSaliencyImageRequest()
        if (try? handler.perform([salReq])) != nil,
           let salObs = salReq.results?.first {
            let extracted = Self.extractFloatsFromPixelBuffer(salObs.pixelBuffer)
            if extracted.width > 0, extracted.height > 0 {
                let resized = Self.resizeFloatMap(extracted.values, srcW: extracted.width, srcH: extracted.height, dstW: targetW, dstH: targetH)
                for i in 0..<min(total, resized.count) {
                    if resized[i] > 0.2 {
                        depth[i] += resized[i] * 0.25
                    }
                }
            }
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

        var pairs: [(ai: Double, real: Double)] = []
        pairs.reserveCapacity(sparseSamples.count)

        for s in sparseSamples {
            let u = min(depthW - 1, max(0, Int((s.x / imageWidth) * Double(depthW))))
            let v = min(depthH - 1, max(0, Int((s.y / imageHeight) * Double(depthH))))
            let dAI = Double(disparityMap[v * depthW + u])
            pairs.append((ai: dAI, real: -s.parallax))
        }

        guard pairs.count >= 10 else { return disparityMap }

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

    /// 正規化視差マップをバイリニア補間＋ガンマ/コントラスト補正して [0.0=奥, 1.0=手前] の値を返す
    public static func sampleNormalizedDisparity(
        disparityMap: [Float],
        depthW: Int,
        depthH: Int,
        u: Float,
        v: Float,
        depthGamma: Double = 1.0,
        depthContrast: Double = 0.0
    ) -> Float {
        guard depthW > 0, depthH > 0, disparityMap.count >= depthW * depthH else { return 0.5 }
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

        if abs(depthGamma - 1.0) > 0.01 {
            d = pow(max(0.0001, d), Float(1.0 / max(0.2, depthGamma)))
        }
        if abs(depthContrast) > 0.01 {
            let s = d * d * (3.0 - 2.0 * d)
            d = (1.0 - Float(depthContrast)) * d + Float(depthContrast) * s
        }
        return min(1.0, max(0.0, d))
    }

    /// 単眼RGBバッファと正規化視差マップ (0.0=奥 ~ 1.0=手前) から、左右ステレオペアを合成する
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
        focusRatio: Double = 0.75
    ) -> (leftRGB: [UInt8], rightRGB: [UInt8]) {
        let count = width * height
        guard baseRGB.count >= count * 3, depthW > 0, depthH > 0 else {
            return (baseRGB, baseRGB)
        }

        if count >= 65536,
           let gpuResult = ViewStereoMetalDIBR.shared.synthesizeStereoPair(
               baseRGB: baseRGB,
               width: width,
               height: height,
               disparityMap: disparityMap,
               depthW: depthW,
               depthH: depthH,
               targetDisparityPercent: targetDisparityPercent,
               depthGamma: depthGamma,
               depthContrast: depthContrast,
               focusRatio: focusRatio
           ) {
            return gpuResult
        }

        let maxBaselinePx = Float(width) * Float(max(0.2, min(8.0, targetDisparityPercent)) / 100.0)
        let halfBaseline = maxBaselinePx * 0.5
        let focusVal = Float(max(0.0, min(1.0, focusRatio)))

        var leftRGB = [UInt8](repeating: 0, count: count * 3)
        var rightRGB = [UInt8](repeating: 0, count: count * 3)

        let fWidth = Float(width)
        let fHeight = Float(height)

        DispatchQueue.concurrentPerform(iterations: height) { y in
            let v = Float(y) / fHeight
            let rowBase = y * width * 3

            for x in 0..<width {
                let u = Float(x) / fWidth
                let d = Self.sampleNormalizedDisparity(
                    disparityMap: disparityMap,
                    depthW: depthW,
                    depthH: depthH,
                    u: u,
                    v: v,
                    depthGamma: depthGamma,
                    depthContrast: depthContrast
                )
                // 手前(d > focusVal)は飛び出し、奥(d < focusVal)は引き込み
                let dispOffset = (d - focusVal) * halfBaseline

                let srcXL = Float(x) - dispOffset
                let srcXR = Float(x) + dispOffset

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

    // MARK: - Disparity Normalization (すべて 0.0=奥 〜 1.0=手前 に統一)

    /// 相対視差 (大きいほど手前) の正規化 → [0.0=奥, 1.0=手前]
    private static func normalizeDisparity(_ raw: [Float]) -> [Float] {
        guard !raw.isEmpty else { return [] }
        var minVal = Float.greatestFiniteMagnitude
        var maxVal = -Float.greatestFiniteMagnitude
        for v in raw where v.isFinite {
            if v < minVal { minVal = v }
            if v > maxVal { maxVal = v }
        }
        let range = maxVal - minVal
        guard range > 1e-6 else {
            return [Float](repeating: 0.5, count: raw.count)
        }
        return raw.map { v in
            v.isFinite ? min(1.0, max(0.0, (v - minVal) / range)) : 0.0
        }
    }

    /// Depth Pro 2 (`inverse_depth`: 正値が大きくなるほど手前) → 2%〜98% ロバスト正規化 [0.0=奥, 1.0=手前]
    private static func normalizePositiveDisparityRobust(_ raw: [Float]) -> [Float] {
        guard !raw.isEmpty else { return [] }
        let step = max(1, raw.count / 65536)
        var samples = [Float]()
        samples.reserveCapacity(raw.count / step + 1)
        var idx = 0
        while idx < raw.count {
            let v = raw[idx]
            if v.isFinite && v > 0 { samples.append(v) }
            idx += step
        }
        guard !samples.isEmpty else { return normalizeDisparity(raw) }
        samples.sort()
        let pLow = samples[max(0, min(samples.count - 1, Int(Float(samples.count) * 0.02)))]
        let pHigh = samples[max(0, min(samples.count - 1, Int(Float(samples.count) * 0.98)))]
        let span: Float = (pHigh - pLow) > 1e-6 ? (pHigh - pLow) : 1.0

        return raw.map { v in
            let clamped = min(max(v.isFinite ? v : pLow, pLow), pHigh)
            return min(1.0, max(0.0, (clamped - pLow) / span))
        }
    }

    /// Apple Depth Pro (`depthMeters`: 小さいほど手前, 大きいほど奥) → 逆数視差変換 [0.0=奥, 1.0=手前]
    private static func normalizeMetricDepthToDisparity(_ meters: [Float]) -> [Float] {
        guard !meters.isEmpty else { return [] }
        var invDisp = [Float](repeating: 0, count: meters.count)
        for i in 0..<meters.count {
            let m = meters[i]
            let clipped: Float = (m.isFinite && m > 0.01) ? m : 100.0
            invDisp[i] = 1.0 / clipped
        }
        return normalizePositiveDisparityRobust(invDisp)
    }

    /// MoGe-2 専用: メトリック深度 + 空マスク (<0.5を0.0=最奥固定) + 法線Nzによる立体丸み → [0.0=奥, 1.0=手前]
    private static func normalizeMoGeDepthToDisparity(
        _ depthMeters: [Float],
        maskValues: [Float]?,
        normalZValues: [Float]?
    ) -> [Float] {
        let count = depthMeters.count
        guard count > 0 else { return [] }

        var isValid = [Bool](repeating: true, count: count)
        var rawDisp = [Float](repeating: 0, count: count)
        var samples = [Float]()
        samples.reserveCapacity(min(count, 65536))
        let step = max(1, count / 65536)

        for i in 0..<count {
            let m = depthMeters[i]
            let maskOk = (maskValues == nil) || (maskValues![i] >= 0.5)
            if maskOk && m.isFinite && m > 0.005 && m < 10000.0 {
                let disp = 1.0 / m
                rawDisp[i] = disp
                if i % step == 0 { samples.append(disp) }
            } else {
                isValid[i] = false
                rawDisp[i] = 0.0
            }
        }

        guard !samples.isEmpty else {
            return normalizeMetricDepthToDisparity(depthMeters)
        }

        samples.sort()
        let pLow = samples[max(0, min(samples.count - 1, Int(Float(samples.count) * 0.02)))]
        let pHigh = samples[max(0, min(samples.count - 1, Int(Float(samples.count) * 0.98)))]
        let span: Float = (pHigh - pLow) > 1e-6 ? (pHigh - pLow) : 1.0

        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            if isValid[i] {
                let clamped = min(max(rawDisp[i], pLow), pHigh)
                var d = (clamped - pLow) / span // 0.0=奥, 1.0=手前
                if let nzArr = normalZValues {
                    let nz = abs(nzArr[i])
                    if nz.isFinite && nz <= 1.05 {
                        let relief = (nz - 0.5) * 0.022 * d
                        d = min(1.0, max(0.0, d + relief))
                    }
                }
                out[i] = d
            } else {
                // 空・無限遠マスク領域は 0.0 (最奥) に厳密固定
                out[i] = 0.0
            }
        }
        return out
    }

    /// Depth Anything 3 Mono 専用: 指数膨張した直接深度 (小さい=手前, 大きい=奥) → log反転 [0.0=奥, 1.0=手前]
    private static func normalizeDA3DirectDepthToDisparity(_ directDepth: [Float]) -> [Float] {
        guard !directDepth.isEmpty else { return [] }
        let count = directDepth.count
        var logVals = [Float](repeating: 0, count: count)
        var samples = [Float]()
        let step = max(1, count / 65536)
        samples.reserveCapacity(count / step + 1)

        for i in 0..<count {
            let z = directDepth[i]
            let lv: Float = (z.isFinite && z > 1e-4) ? logf(z) : 10.0
            logVals[i] = lv
            if i % step == 0 { samples.append(lv) }
        }
        samples.sort()
        let pLow = samples[max(0, min(samples.count - 1, Int(Float(samples.count) * 0.01)))]
        let pHigh = samples[max(0, min(samples.count - 1, Int(Float(samples.count) * 0.98)))]
        let span: Float = (pHigh - pLow) > 1e-6 ? (pHigh - pLow) : 1.0

        return logVals.map { lv in
            let clamped = min(max(lv, pLow), pHigh)
            // logDepth は小さいほど手前なので 1.0 - norm で 0.0=奥 ~ 1.0=手前 へ
            return min(1.0, max(0.0, 1.0 - (clamped - pLow) / span))
        }
    }

    // MARK: - Core ML Input & Tensor Helpers

    private static func prepareUniversalInputProvider(
        for model: MLModel,
        cgImage: CGImage,
        defaultSize: Int
    ) throws -> MLDictionaryFeatureProvider {
        let inputDescs = model.modelDescription.inputDescriptionsByName
        let preferredInputNames = ["image", "colorImage", "input", "pixel_values", "x"]
        var primaryName = preferredInputNames.first { inputDescs[$0] != nil }
        if primaryName == nil {
            primaryName = inputDescs.first(where: { $0.value.type == .image || $0.value.type == .multiArray })?.key
        }
        guard let inputName = primaryName, let desc = inputDescs[inputName] else {
            throw NSError(domain: "ViewStereoDepthSynthesizer", code: -32, userInfo: [NSLocalizedDescriptionKey: "Core ML モデルの入力定義が見つかりません"])
        }

        var dict = [String: Any]()
        if desc.type == .image {
            let targetW = max(64, desc.imageConstraint?.pixelsWide ?? defaultSize)
            let targetH = max(64, desc.imageConstraint?.pixelsHigh ?? defaultSize)
            let pixelBuffer = try createResizedPixelBuffer(from: cgImage, width: targetW, height: targetH)
            dict[inputName] = MLFeatureValue(pixelBuffer: pixelBuffer)
        } else if desc.type == .multiArray, let constraint = desc.multiArrayConstraint {
            let shape = constraint.shape.map { $0.intValue }
            let targetW: Int
            let targetH: Int
            let isNHWC: Bool
            if shape.count == 4 {
                if shape[3] == 3 && shape[1] > 3 {
                    isNHWC = true
                    targetH = shape[1] > 0 ? shape[1] : defaultSize
                    targetW = shape[2] > 0 ? shape[2] : defaultSize
                } else {
                    isNHWC = false
                    targetH = shape[2] > 0 ? shape[2] : defaultSize
                    targetW = shape[3] > 0 ? shape[3] : defaultSize
                }
            } else if shape.count == 3 {
                isNHWC = (shape[2] == 3 && shape[0] > 3)
                targetH = isNHWC ? shape[0] : shape[1]
                targetW = isNHWC ? shape[1] : shape[2]
            } else {
                isNHWC = false
                targetW = defaultSize
                targetH = defaultSize
            }
            let multiArray = try createRGBMultiArray(
                from: cgImage,
                width: targetW,
                height: targetH,
                shape: constraint.shape,
                dataType: constraint.dataType,
                isNHWC: isNHWC
            )
            dict[inputName] = MLFeatureValue(multiArray: multiArray)
        } else {
            throw NSError(domain: "ViewStereoDepthSynthesizer", code: -33, userInfo: [NSLocalizedDescriptionKey: "未対応の Core ML 入力型です"])
        }
        return try MLDictionaryFeatureProvider(dictionary: dict)
    }

    private static func createResizedPixelBuffer(from cgImage: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pbOpt: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pbOpt
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pbOpt else {
            throw NSError(domain: "ViewStereoDepthSynthesizer", code: -34, userInfo: [NSLocalizedDescriptionKey: "CVPixelBuffer の確保に失敗しました"])
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "ViewStereoDepthSynthesizer", code: -34, userInfo: [NSLocalizedDescriptionKey: "CVPixelBuffer ベースアドレス取得失敗"])
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bInfo
        ) else {
            throw NSError(domain: "ViewStereoDepthSynthesizer", code: -34, userInfo: [NSLocalizedDescriptionKey: "CGContext 生成失敗"])
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    private static func createRGBMultiArray(
        from cgImage: CGImage,
        width: Int,
        height: Int,
        shape: [NSNumber],
        dataType: MLMultiArrayDataType,
        isNHWC: Bool
    ) throws -> MLMultiArray {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: bInfo
        ) else {
            throw NSError(domain: "ViewStereoDepthSynthesizer", code: -35, userInfo: [NSLocalizedDescriptionKey: "MultiArray 用 CGContext 生成失敗"])
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let resolvedShape: [NSNumber] = shape.isEmpty
            ? [1, 3, NSNumber(value: height), NSNumber(value: width)]
            : shape
        let multiArray = try MLMultiArray(shape: resolvedShape, dataType: dataType)
        let strides = multiArray.strides.map { $0.intValue }
        let inv255: Float = 1.0 / 255.0

        let cStride: Int
        let yStride: Int
        let xStride: Int
        if strides.count == 4 {
            if isNHWC {
                yStride = strides[1]; xStride = strides[2]; cStride = strides[3]
            } else {
                cStride = strides[1]; yStride = strides[2]; xStride = strides[3]
            }
        } else if strides.count == 3 {
            if isNHWC {
                yStride = strides[0]; xStride = strides[1]; cStride = strides[2]
            } else {
                cStride = strides[0]; yStride = strides[1]; xStride = strides[2]
            }
        } else {
            cStride = width * height; yStride = width; xStride = 1
        }

        if dataType == .float16 {
            let ptr = multiArray.dataPointer.assumingMemoryBound(to: Float16.self)
            for y in 0..<height {
                let rowRGBA = y * width * 4
                let rowOut = y * yStride
                for x in 0..<width {
                    let px = rowRGBA + x * 4
                    let baseOut = rowOut + x * xStride
                    ptr[baseOut] = Float16(Float(rgba[px]) * inv255)
                    ptr[baseOut + cStride] = Float16(Float(rgba[px + 1]) * inv255)
                    ptr[baseOut + 2 * cStride] = Float16(Float(rgba[px + 2]) * inv255)
                }
            }
        } else {
            let ptr = multiArray.dataPointer.assumingMemoryBound(to: Float.self)
            for y in 0..<height {
                let rowRGBA = y * width * 4
                let rowOut = y * yStride
                for x in 0..<width {
                    let px = rowRGBA + x * 4
                    let baseOut = rowOut + x * xStride
                    ptr[baseOut] = Float(rgba[px]) * inv255
                    ptr[baseOut + cStride] = Float(rgba[px + 1]) * inv255
                    ptr[baseOut + 2 * cStride] = Float(rgba[px + 2]) * inv255
                }
            }
        }
        return multiArray
    }

    private static func extractChannelFloats(
        from ma: MLMultiArray,
        channelIndex: Int = 0
    ) -> (values: [Float], width: Int, height: Int) {
        let shape = ma.shape.map { $0.intValue }
        let strides = ma.strides.map { $0.intValue }

        let height: Int
        let width: Int
        let cStride: Int
        let yStride: Int
        let xStride: Int
        let channels: Int

        if shape.count == 4 {
            if shape[3] <= 4 && shape[1] > 4 {
                channels = shape[3]; height = shape[1]; width = shape[2]
                yStride = strides[1]; xStride = strides[2]; cStride = strides[3]
            } else {
                channels = shape[1]; height = shape[2]; width = shape[3]
                cStride = strides[1]; yStride = strides[2]; xStride = strides[3]
            }
        } else if shape.count == 3 {
            if shape[2] <= 4 && shape[0] > 4 {
                channels = shape[2]; height = shape[0]; width = shape[1]
                yStride = strides[0]; xStride = strides[1]; cStride = strides[2]
            } else {
                channels = shape[0]; height = shape[1]; width = shape[2]
                cStride = strides[0]; yStride = strides[1]; xStride = strides[2]
            }
        } else if shape.count == 2 {
            channels = 1; height = shape[0]; width = shape[1]
            cStride = 0; yStride = strides[0]; xStride = strides[1]
        } else {
            return ([], 0, 0)
        }

        guard width > 0, height > 0 else { return ([], 0, 0) }
        let targetC = max(0, min(max(1, channels) - 1, channelIndex))
        let cOffset = targetC * cStride
        var out = [Float](repeating: 0, count: width * height)

        if ma.dataType == .float16 {
            let ptr = ma.dataPointer.assumingMemoryBound(to: Float16.self)
            for y in 0..<height {
                let rowBase = cOffset + y * yStride
                let dstRow = y * width
                for x in 0..<width {
                    out[dstRow + x] = Float(ptr[rowBase + x * xStride])
                }
            }
        } else if ma.dataType == .float32 {
            let ptr = ma.dataPointer.assumingMemoryBound(to: Float.self)
            for y in 0..<height {
                let rowBase = cOffset + y * yStride
                let dstRow = y * width
                for x in 0..<width {
                    out[dstRow + x] = ptr[rowBase + x * xStride]
                }
            }
        } else {
            for y in 0..<height {
                let rowBase = cOffset + y * yStride
                let dstRow = y * width
                for x in 0..<width {
                    let idx = rowBase + x * xStride
                    if idx < ma.count {
                        out[dstRow + x] = ma[idx].floatValue
                    }
                }
            }
        }
        return (out, width, height)
    }

    private static func extractFloatsFromPixelBuffer(_ pb: CVPixelBuffer) -> (values: [Float], width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let total = w * h
        var result = [Float](repeating: 0, count: total)

        guard let base = CVPixelBufferGetBaseAddress(pb), w > 0, h > 0 else { return ([], 0, 0) }
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

    private static func resizeFloatMap(_ src: [Float], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [Float] {
        guard srcW > 0, srcH > 0, dstW > 0, dstH > 0 else { return [] }
        if srcW == dstW && srcH == dstH { return src }
        var dst = [Float](repeating: 0, count: dstW * dstH)
        for y in 0..<dstH {
            let fy = Float(y) * Float(srcH - 1) / Float(max(1, dstH - 1))
            let y0 = Int(fy)
            let y1 = min(srcH - 1, y0 + 1)
            let wy = fy - Float(y0)
            for x in 0..<dstW {
                let fx = Float(x) * Float(srcW - 1) / Float(max(1, dstW - 1))
                let x0 = Int(fx)
                let x1 = min(srcW - 1, x0 + 1)
                let wx = fx - Float(x0)
                let v00 = src[y0 * srcW + x0]
                let v10 = src[y0 * srcW + x1]
                let v01 = src[y1 * srcW + x0]
                let v11 = src[y1 * srcW + x1]
                let top = v00 * (1.0 - wx) + v10 * wx
                let bot = v01 * (1.0 - wx) + v11 * wx
                dst[y * dstW + x] = top * (1.0 - wy) + bot * wy
            }
        }
        return dst
    }

    // MARK: - Image Utilities

    public static func createCGImage(from rgb: [UInt8], width: Int, height: Int) -> CGImage? {
        guard rgb.count >= width * height * 3, width > 0, height > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let cfData = CFDataCreate(kCFAllocatorDefault, rgb, rgb.count),
              let provider = CGDataProvider(data: cfData) else { return nil }
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
}
