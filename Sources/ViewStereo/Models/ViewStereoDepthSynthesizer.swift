import CoreGraphics
import CoreML
import Foundation
import StereoCore
import StereoStudioCore

/// ViewStereo 向け片側画像 AI 深度推定 ＆ DIBR 2D-3D コンバージョンシンセサイザー
/// コアの Core ML 深度推定・動画セッション・Metal DIBR は `StereoStudioCore.StudioVideoDepthSynthesizer` に委譲し、
/// 本クラスでは後方互換 API および `StereoCore.DisparitySample` を使った実視差較正を提供する。
public final class ViewStereoDepthSynthesizer: @unchecked Sendable {
    public static let shared = ViewStereoDepthSynthesizer()
    private let core = StudioVideoDepthSynthesizer.shared

    private init() {}

    public typealias DepthEngineType = StudioVideoDepthSynthesizer.DepthEngineType
    public typealias RawVideoDepthFrame = StudioVideoDepthSynthesizer.RawVideoDepthFrame

    // MARK: - Memory Management

    public func releaseCachedModels() {
        core.releaseCachedModels()
    }

    // MARK: - Model Resolution

    public func resolveDepthModelURL() -> (url: URL, engine: DepthEngineType)? {
        core.resolveDepthModelURL(preferredAppFolder: "ViewStereo")
    }

    public func resolveDepthModelURL(
        preferredEngine: StudioDepthEngine
    ) -> (url: URL, engine: StudioDepthEngine, isFallback: Bool)? {
        core.resolveDepthModelURL(preferredEngine: preferredEngine, preferredAppFolder: "ViewStereo")
    }

    // MARK: - Disparity Estimation Public API

    public func estimateDisparity(
        rgb: [UInt8],
        width: Int,
        height: Int,
        preferredEngine: StudioDepthEngine,
        releaseAfterInference: Bool
    ) -> (disparity: [Float], width: Int, height: Int, engineName: String, coreMLEngine: StudioDepthEngine?, elapsedMs: Double)? {
        core.estimateDisparity(
            rgb: rgb,
            width: width,
            height: height,
            preferredEngine: preferredEngine,
            releaseAfterInference: releaseAfterInference,
            preferredAppFolder: "ViewStereo"
        )
    }

    public func estimateDisparity(
        cgImage: CGImage,
        preferredEngine: StudioDepthEngine,
        releaseAfterInference: Bool
    ) -> (disparity: [Float], width: Int, height: Int, engineName: String, coreMLEngine: StudioDepthEngine?, elapsedMs: Double) {
        core.estimateDisparity(
            cgImage: cgImage,
            preferredEngine: preferredEngine,
            releaseAfterInference: releaseAfterInference,
            preferredAppFolder: "ViewStereo"
        )
    }

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

    public func prepareVideoEngine(
        preferredEngine: StudioDepthEngine
    ) -> (model: MLModel, engine: StudioDepthEngine, isFallback: Bool)? {
        core.prepareVideoEngine(preferredEngine: preferredEngine, preferredAppFolder: "ViewStereo")
    }

    public func makeVideoInferenceState(for model: MLModel, engine: StudioDepthEngine) -> AnyObject? {
        core.makeVideoInferenceState(for: model, engine: engine)
    }

    public func estimateRawVideoDepth(
        cgImage: CGImage,
        prepared: (model: MLModel, engine: StudioDepthEngine, isFallback: Bool)?,
        externalState: AnyObject?
    ) -> RawVideoDepthFrame {
        core.estimateRawVideoDepth(cgImage: cgImage, prepared: prepared, externalState: externalState)
    }

    // MARK: - Sparse Stereo Guided Calibration (実視差ガイド較正)

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
            return StudioVideoDepthSynthesizer.normalizeDisparity(calibrated)
        }

        return disparityMap
    }

    // MARK: - DIBR Stereo Synthesis & Image Utilities

    public static func sampleNormalizedDisparity(
        disparityMap: [Float],
        depthW: Int,
        depthH: Int,
        u: Float,
        v: Float,
        depthGamma: Double = 1.0,
        depthContrast: Double = 0.0
    ) -> Float {
        StudioVideoDepthSynthesizer.sampleNormalizedDisparity(
            disparityMap: disparityMap,
            depthW: depthW,
            depthH: depthH,
            u: u,
            v: v,
            depthGamma: depthGamma,
            depthContrast: depthContrast
        )
    }

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
        core.synthesizeStereoPair(
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
        )
    }

    public static func createCGImage(from rgb: [UInt8], width: Int, height: Int) -> CGImage? {
        StudioVideoDepthSynthesizer.createCGImage(from: rgb, width: width, height: height)
    }

    public static func resizeRGB(_ rgb: [UInt8], width: Int, height: Int, targetWidth tw: Int, targetHeight th: Int) -> [UInt8] {
        StudioVideoDepthSynthesizer.resizeRGB(rgb, width: width, height: height, targetWidth: tw, targetHeight: th)
    }
}
