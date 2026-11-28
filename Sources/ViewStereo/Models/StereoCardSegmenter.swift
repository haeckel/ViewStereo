import AppKit
import CoreGraphics
import CoreML
import CoreText
import Foundation
import StereoCore
import StereoStudioCore
import Vision

/// Core ML (StereoCardSeg v2 + SAM 2.1 Tiny) を用いたステレオカードの台紙・左右写真領域自動セグメンテーション
final class StereoCardSegmenter: @unchecked Sendable {
    static let shared = StereoCardSegmenter()

    private let inputWidth = 512
    private let inputHeight = 256
    let samSize = 1024
    let samMaskSize = 256

    struct ArchShapeParams: Sendable {
        var topRxRatio: Double = 0.26
        var topRyRatio: Double = 0.14
        var botRxRatio: Double = 0.0
        var botRyRatio: Double = 0.0
        var topArchExp: Double = 2.0
    }

    /// 元ステレオカードの台紙・印画枠・地色・傾き・マスク情報（デジタル・リマウント & インク転写 & OCR 用）
    struct OriginalCardMountContext: Sendable {
        let cardRGB: [UInt8]
        let cardWidth: Int
        let cardHeight: Int
        let leftBox: (x0: Int, y0: Int, x1: Int, y1: Int)
        let rightBox: (x0: Int, y0: Int, x1: Int, y1: Int)
        let maskL: [Bool]
        let maskR: [Bool]
        let maskWidth: Int
        let maskHeight: Int
        let skewAngleRad: Double
        let sampledCardRGB: (r: UInt8, g: UInt8, b: UInt8)
        let archParams: ArchShapeParams
        let unmaskedLeftRGB: [UInt8]
        let unmaskedRightRGB: [UInt8]
        let unmaskedAlphaL: [UInt8]
        let unmaskedAlphaR: [UInt8]
        let unmaskedWidth: Int
        let unmaskedHeight: Int
    }

    private var cachedModel: MLModel? = nil
    var cachedSam2Encoder: MLModel? = nil
    var cachedSam2Prompt: MLModel? = nil
    var cachedSam2Decoder: MLModel? = nil
    var cachedSam2EncoderCPU: MLModel? = nil
    var cachedSam2PromptCPU: MLModel? = nil
    var cachedSam2DecoderCPU: MLModel? = nil
    var interactiveEmbeddingCache: SAMImageEmbeddingCache? = nil
    var latestArchParams = ArchShapeParams()
    private var latestCardLuma: Double? = nil
    var latestMountContext: OriginalCardMountContext? = nil
    private var latestFullCardAlphaL: [UInt8]? = nil
    private var latestFullCardAlphaR: [UInt8]? = nil
    private var _latestGateReport: SegV3GateReport? = nil
    let lock = NSLock()

    private init() {}

    /// 直近のカードで推定した台紙の輝度（平行化後の残留台紙帯トリミングに使用）
    var currentCardLuma: Double? {
        lock.lock()
        defer { lock.unlock() }
        return latestCardLuma
    }

    var currentArchParams: ArchShapeParams {
        lock.lock()
        defer { lock.unlock() }
        return latestArchParams
    }

    var currentMountContext: OriginalCardMountContext? {
        lock.lock()
        defer { lock.unlock() }
        return latestMountContext
    }

    var currentFullCardAlphas: (left: [UInt8], right: [UInt8])? {
        lock.lock()
        defer { lock.unlock() }
        guard let l = latestFullCardAlphaL, let r = latestFullCardAlphaR else { return nil }
        return (l, r)
    }

    var latestGateReport: SegV3GateReport? {
        lock.lock()
        defer { lock.unlock() }
        return _latestGateReport
    }

    func clearCurrentContext() {
        lock.lock()
        latestArchParams = ArchShapeParams()
        latestCardLuma = nil
        latestMountContext = nil
        latestFullCardAlphaL = nil
        latestFullCardAlphaR = nil
        _latestGateReport = nil
        lock.unlock()
    }

    var isModelAvailable: Bool {
        resolveModelURL(name: "StereoCardSeg") != nil
    }

    /// モデルを解決してロード（未導入時は nil）
    func loadModel(name: String, cache: inout MLModel?, computeUnitsOverride: MLComputeUnits? = nil) -> MLModel? {
        lock.lock()
        defer { lock.unlock() }
        if computeUnitsOverride == nil, let existing = cache { return existing }
        guard let url = resolveModelURL(name: name) else { return nil }

        do {
            let compiledURL: URL
            if url.pathExtension == "mlpackage" || url.pathExtension == "mlmodel" {
                compiledURL = try MLModel.compileModel(at: url)
            } else {
                compiledURL = url
            }
            let config = MLModelConfiguration()
            if let forced = computeUnitsOverride {
                config.computeUnits = forced
            } else if name == "StereoCardSeg" {
                config.computeUnits = .cpuAndNeuralEngine
            } else if name == "SAM2_1TinyMaskDecoderFLOAT16" {
                // MIL conv_transpose の ANE コンパイル失敗＋フォールバック遅延を回避
                config.computeUnits = .cpuAndGPU
            } else {
                config.computeUnits = .all
            }
            let model: MLModel
            do {
                model = try MLModel(contentsOf: compiledURL, configuration: config)
            } catch {
                if computeUnitsOverride == nil && name == "StereoCardSeg" {
                    let fallbackCfg = MLModelConfiguration()
                    fallbackCfg.computeUnits = .all
                    model = try MLModel(contentsOf: compiledURL, configuration: fallbackCfg)
                } else {
                    throw error
                }
            }
            cache = model
            return model
        } catch {
            return nil
        }
    }

    private func resolveModelURL(name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            return u
        }
        if let u = Bundle.main.url(forResource: name, withExtension: "mlpackage") {
            return u
        }
        #if SWIFT_PACKAGE
        if let u = Bundle.module.url(forResource: name, withExtension: "mlmodelc") {
            return u
        }
        if let u = Bundle.module.url(forResource: name, withExtension: "mlpackage") {
            return u
        }
        #endif
        if let located = StudioModelLocator.locateExistingItem(
            relativeSubpath: "Models/\(name).mlmodelc",
            preferredAppFolder: "ViewStereo"
        ) ?? StudioModelLocator.locateExistingItem(
            relativeSubpath: "Models/\(name).mlmodelc",
            preferredAppFolder: "StereoWindow"
        ) {
            return located.url
        }
        if let located = StudioModelLocator.locateExistingItem(
            relativeSubpath: "Models/\(name).mlpackage",
            preferredAppFolder: "ViewStereo"
        ) ?? StudioModelLocator.locateExistingItem(
            relativeSubpath: "Models/\(name).mlpackage",
            preferredAppFolder: "StereoWindow"
        ) {
            return located.url
        }
        return nil
    }

    /// セグメンテーション推論（U-Net / SAM / MountAnalyzer）用に下部コーナーの鮮烈な赤色透かしスタンプを周囲背景で補間無害化する。
    /// 1870s 朱赤・オレンジ台紙の誤爆を防ぐため、上半分台紙代表色との差・下部コーナー限定・面積上限 (4.5%) を厳格に検査し、
    /// かつ元の `rgb` 自体は一切変更せず推論専用コピーを返す。
    private func neutralizeRedWatermarkForSegmentation(
        rgb: [UInt8],
        width w: Int,
        height h: Int,
        fallbackCGImage: CGImage
    ) -> (rgb: [UInt8], cgImage: CGImage) {
        let pixelCount = w * h
        guard w >= 32, h >= 32, rgb.count >= pixelCount * 3 else {
            return (rgb, fallbackCGImage)
        }

        // 上半分（スタンプのない左右台紙帯 y∈[15%..45%], x∈[4%..9%]∪[91%..96%]）から台紙代表色をサンプリング
        var cardRs: [Double] = [], cardGs: [Double] = [], cardBs: [Double] = []
        let mY0 = Int(Double(h) * 0.15), mY1 = Int(Double(h) * 0.45)
        let mLX0 = Int(Double(w) * 0.04), mLX1 = Int(Double(w) * 0.09)
        let mRX0 = Int(Double(w) * 0.91), mRX1 = Int(Double(w) * 0.96)
        let mStepY = max(1, (mY1 - mY0) / 16)
        let mStepX = max(1, (mLX1 - mLX0) / 8)
        rgb.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            var y = mY0
            while y < mY1 {
                for (xa, xb) in [(mLX0, mLX1), (mRX0, mRX1)] {
                    var x = xa
                    while x < xb {
                        let i = (y * w + x) * 3
                        let r = Double(base[i]), g = Double(base[i + 1]), b = Double(base[i + 2])
                        let luma = (r + g + b) / 3.0
                        if luma > 25.0 && luma < 242.0 {
                            cardRs.append(r); cardGs.append(g); cardBs.append(b)
                        }
                        x += mStepX
                    }
                }
                y += mStepY
            }
        }
        let hasMarginCard: Bool
        let cardRef: (r: Double, g: Double, b: Double)
        if cardRs.count >= 12 {
            cardRs.sort(); cardGs.sort(); cardBs.sort()
            let mid = cardRs.count / 2
            cardRef = (cardRs[mid], cardGs[mid], cardBs[mid])
            hasMarginCard = true
        } else {
            cardRef = (0, 0, 0)
            hasMarginCard = false
        }

        var isRed = [Bool](repeating: false, count: pixelCount)
        var redCount = 0
        let yMin = h / 2
        let xLeftMax = (w * 32) / 100
        let xRightMin = (w * 68) / 100

        rgb.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for y in yMin..<h {
                let row = y * w
                for x in 0..<w {
                    guard x <= xLeftMax || x >= xRightMin else { continue }
                    let idx = row + x
                    let off = idx * 3
                    let r = Int(base[off]), g = Int(base[off + 1]), b = Int(base[off + 2])
                    guard r >= 125 && (r - max(g, b)) >= 32 && r * 4 >= g * 5 else { continue }
                    if hasMarginCard {
                        let dCard = max(abs(Double(r) - cardRef.r), max(abs(Double(g) - cardRef.g), abs(Double(b) - cardRef.b)))
                        if dCard < 42.0 { continue }
                    }
                    isRed[idx] = true
                    redCount += 1
                }
            }
        }
        guard redCount >= 16, Double(redCount) <= Double(pixelCount) * 0.045 else {
            return (rgb, fallbackCGImage)
        }

        // 2px 膨張させて赤縁アンチエイリアスも確実に覆う
        var mask = isRed
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where isRed[row + x] {
                let y0 = max(0, y - 2), y1 = min(h - 1, y + 2)
                let x0 = max(0, x - 2), x1 = min(w - 1, x + 2)
                for yy in y0...y1 {
                    let rOff = yy * w
                    for xx in x0...x1 {
                        mask[rOff + xx] = true
                    }
                }
            }
        }

        var cleaned = rgb
        cleaned.withUnsafeMutableBufferPointer { dstPtr in
            rgb.withUnsafeBufferPointer { srcPtr in
                guard let dst = dstPtr.baseAddress, let src = srcPtr.baseAddress else { return }
                let searchMax = max(12, min(w, h) / 14)
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w where mask[row + x] {
                        var sumR = 0, sumG = 0, sumB = 0, hits = 0
                        // 左右外方向および上下方向から直近の非赤画素を収集
                        let dirs = [(1, 0), (-1, 0), (0, -1), (0, 1)]
                        for (dx, dy) in dirs {
                            var step = 1
                            while step <= searchMax {
                                let nx = x + dx * step
                                let ny = y + dy * step
                                if nx < 0 || nx >= w || ny < 0 || ny >= h { break }
                                if !mask[ny * w + nx] {
                                    let idx = (ny * w + nx) * 3
                                    sumR += Int(src[idx])
                                    sumG += Int(src[idx + 1])
                                    sumB += Int(src[idx + 2])
                                    hits += 1
                                    break
                                }
                                step += 1
                            }
                        }
                        if hits > 0 {
                            let di = (row + x) * 3
                            dst[di]     = UInt8(sumR / hits)
                            dst[di + 1] = UInt8(sumG / hits)
                            dst[di + 2] = UInt8(sumB / hits)
                        }
                    }
                }
            }
        }
        let cleanedCG = makeCGImage(from: cleaned, width: w, height: h) ?? fallbackCGImage
        return (cleaned, cleanedCG)
    }

    /// Core ML でステレオカード画像をセグメンテーションし、左右写真ペアを切り出す
    func extractPhotoPair(
        from inputRGB: [UInt8],
        width inputImgW: Int,
        height inputImgH: Int,
        mode: StereoCardCropper.ExtractionMode
    ) -> StereoCardCropper.CropResult? {
        clearCurrentContext()
        guard inputImgW >= 64, inputImgH >= 32, inputRGB.count >= inputImgW * inputImgH * 3,
              let model = loadModel(name: "StereoCardSeg", cache: &cachedModel),
              let rawCGImage = makeCGImage(from: inputRGB, width: inputImgW, height: inputImgH) else {
            return nil
        }

        // Stage 0 を含む 3段階カスケード解析は常に無加工の rawCGImage / inputRGB で 1 回だけ実行し、元画素を 100% 保持
        let mountAnalysis = StereoCardMountAnalyzer.analyze(cgImage: rawCGImage, rgb: inputRGB)
        let rgb: [UInt8]
        let baseCGImage: CGImage
        let width: Int
        let height: Int
        if let deskew = mountAnalysis?.deskew, deskew.hasScanMargin,
           deskew.width >= 64, deskew.height >= 32,
           deskew.deskewedRGB.count >= deskew.width * deskew.height * 3 {
            rgb = deskew.deskewedRGB
            width = deskew.width
            height = deskew.height
            baseCGImage = deskew.deskewedImage
        } else {
            rgb = inputRGB
            width = inputImgW
            height = inputImgH
            baseCGImage = rawCGImage
        }
        let tPipelineStart = CFAbsoluteTimeGetCurrent()

        do {
            var pixelBuffer: CVPixelBuffer?
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                inputWidth,
                inputHeight,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pb = pixelBuffer else {
                return nil
            }
            CVPixelBufferLockBaseAddress(pb, [])
            if let pxData = CVPixelBufferGetBaseAddress(pb) {
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                if let ctx = CGContext(
                    data: pxData,
                    width: inputWidth,
                    height: inputHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bpr,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
                ) {
                    ctx.interpolationQuality = .high
                    // v3 は赤スタンプ未中和の原画ドメインで学習済みのため baseCGImage をそのまま入力
                    ctx.draw(baseCGImage, in: CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight))
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])

            let tModelStart = CFAbsoluteTimeGetCurrent()
            let inputFeature = MLFeatureValue(pixelBuffer: pb)
            let provider = try MLDictionaryFeatureProvider(dictionary: ["image": inputFeature])
            let output = try model.prediction(from: provider)
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                return nil
            }
            let v3InferMs = (CFAbsoluteTimeGetCurrent() - tModelStart) * 1000.0

            let H = inputHeight
            let W = inputWidth
            let cCount = logits.shape.count >= 2 ? logits.shape[1].intValue : 2
            let strideC = logits.strides[1].intValue
            let strideY = logits.strides[2].intValue
            let strideX = logits.strides[3].intValue
            let isFloat16 = (logits.dataType == .float16)

            // Phase 2-5: v3 3クラス (0=Bg, 1=Left, 2=Right) + 3層フォールバックゲート
            if cCount >= 3 {
                let count = W * H
                var probBg = [Float](repeating: 0, count: count)
                var probL = [Float](repeating: 0, count: count)
                var probR = [Float](repeating: 0, count: count)
                var predClass = [UInt8](repeating: 0, count: count)

                if isFloat16 {
                    let ptr16 = logits.dataPointer.assumingMemoryBound(to: Float16.self)
                    for y in 0..<H {
                        let yOff = y * strideY
                        let row = y * W
                        for x in 0..<W {
                            let base = yOff + x * strideX
                            let v0 = Float(ptr16[base])
                            let v1 = Float(ptr16[base + strideC])
                            let v2 = Float(ptr16[base + strideC * 2])
                            let m = max(v0, max(v1, v2))
                            let e0 = expf(v0 - m), e1 = expf(v1 - m), e2 = expf(v2 - m)
                            let inv = 1.0 / max(1e-7, e0 + e1 + e2)
                            let p0 = e0 * inv, p1 = e1 * inv, p2 = e2 * inv
                            let idx = row + x
                            probBg[idx] = p0
                            probL[idx] = p1
                            probR[idx] = p2
                            if p1 >= p0 && p1 >= p2 {
                                predClass[idx] = 1
                            } else if p2 >= p0 && p2 >= p1 {
                                predClass[idx] = 2
                            } else {
                                predClass[idx] = 0
                            }
                        }
                    }
                } else {
                    let ptr32 = logits.dataPointer.assumingMemoryBound(to: Float.self)
                    for y in 0..<H {
                        let yOff = y * strideY
                        let row = y * W
                        for x in 0..<W {
                            let base = yOff + x * strideX
                            let v0 = ptr32[base]
                            let v1 = ptr32[base + strideC]
                            let v2 = ptr32[base + strideC * 2]
                            let m = max(v0, max(v1, v2))
                            let e0 = expf(v0 - m), e1 = expf(v1 - m), e2 = expf(v2 - m)
                            let inv = 1.0 / max(1e-7, e0 + e1 + e2)
                            let p0 = e0 * inv, p1 = e1 * inv, p2 = e2 * inv
                            let idx = row + x
                            probBg[idx] = p0
                            probL[idx] = p1
                            probR[idx] = p2
                            if p1 >= p0 && p1 >= p2 {
                                predClass[idx] = 1
                            } else if p2 >= p0 && p2 >= p1 {
                                predClass[idx] = 2
                            } else {
                                predClass[idx] = 0
                            }
                        }
                    }
                }

                let raw = StereoCardSegV3Gate.parseRawPrediction(
                    probBg: probBg, probL: probL, probR: probR, predClass: predClass, width: W, height: H
                )
                let tier1 = StereoCardSegV3Gate.evaluateTier1(raw: raw, origWidth: width, origHeight: height)
                let tier2 = StereoCardSegV3Gate.evaluateTier2(raw: raw)

                func runSAM2Fallback(tier3Metrics: SegV3Tier3Metrics?) -> StereoCardCropper.CropResult? {
                    let cleanSAM = neutralizeRedWatermarkForSegmentation(
                        rgb: rgb, width: width, height: height, fallbackCGImage: baseCGImage
                    )
                    var hints = StereoCardSegV3Gate.buildSAMSeedHints(from: raw)
                    var probPhotoV3 = [Float](repeating: 0, count: count)
                    for i in 0..<count {
                        probPhotoV3[i] = max(raw.probL[i], raw.probR[i])
                    }
                    var roughBoxL = hints.coreBoxL ?? raw.boxL
                    var roughBoxR = hints.coreBoxR ?? raw.boxR
                    if tier1.passed && (hints.coreBoxL == nil || hints.coreBoxR == nil) {
                        syncRoughBoundsY(rgb: cleanSAM.rgb, srcW: width, srcH: height, boxL: &roughBoxL, boxR: &roughBoxR, maskW: W, maskH: H)
                    }

                    lock.lock()
                    let fbCardLuma = latestCardLuma
                    lock.unlock()
                    let preLx0 = max(0, roughBoxL.minX * width / W)
                    let preLy0 = max(0, roughBoxL.minY * height / H)
                    let preLy1 = min(height, (roughBoxL.maxY + 1) * height / H)
                    let preRx1 = min(width, (roughBoxR.maxX + 1) * width / W)
                    let preRy0 = max(0, roughBoxR.minY * height / H)
                    let preRy1 = min(height, (roughBoxR.maxY + 1) * height / H)
                    let prelimRGB = Self.sampleLocalCardRGB(
                        rgb: cleanSAM.rgb, srcW: width, srcH: height,
                        yTop: min(preLy0, preRy0), yBot: max(preLy1, preRy1),
                        xLeft: preLx0, xRight: preRx1,
                        fallbackLuma: fbCardLuma
                    )

                    // 高信頼 Stage 1 外周連結台紙バリアが粗バウンディングボックス下端に深く侵入している場合、
                    // SAM 2.1 プロンプト Box の過剰膨張を防ぎ、連結バリア内の安全負点を補強する
                    if tier1.passed,
                       let barrier = mountAnalysis?.barrier,
                       barrier.model.confidence >= 0.40,
                       let cRGB = prelimRGB,
                       cleanSAM.rgb.count >= width * height * 3 {
                        func trimRoughBottomByBarrier(_ box: inout IntBox, isRight: Bool) {
                            let bhMask = box.maxY - box.minY + 1
                            let bwMask = box.maxX - box.minX + 1
                            guard bhMask >= 24, bwMask >= 16 else { return }
                            let origMaxY = box.maxY
                            let limitMaskY = max(box.minY + bhMask / 2, box.maxY - max(4, Int(Double(H) * 0.25)))
                            let x0Orig = max(0, box.minX * width / W)
                            let x1Orig = min(width, (box.maxX + 1) * width / W)
                            var my = box.maxY
                            while my > limitMaskY {
                                let sy = min(height - 2, max(0, (my * height + height / 2) / H))
                                if Self.isPureMountBarrierRow(
                                    rgb: cleanSAM.rgb, width: width, height: height,
                                    y: sy, x0: x0Orig, x1: x1Orig, isRightSide: isRight,
                                    scanningFromTop: false, cardRGB: cRGB, barrier: barrier,
                                    minConnRatio: 0.45, minRowConnRatio: 0.20
                                ) {
                                    my -= 1
                                } else {
                                    break
                                }
                            }
                            if origMaxY - my >= 3 && my > box.minY + 16 {
                                box.maxY = my
                                let negX = (box.minX + box.maxX) / 2
                                let negY = min(H - 1, my + 5)
                                let nNx = Double(negX) / Double(max(1, W - 1))
                                let nNy = Double(negY) / Double(max(1, H - 1))
                                if barrier.isConnectedBarrierAt(normX: nNx, normY: nNy) {
                                    let tooClose = hints.bgNegPoints.contains { abs($0.x - negX) < 12 && abs($0.y - negY) < 12 }
                                    if !tooClose {
                                        hints.bgNegPoints.append((x: negX, y: negY))
                                    }
                                }
                            }
                        }
                        trimRoughBottomByBarrier(&roughBoxL, isRight: false)
                        trimRoughBottomByBarrier(&roughBoxR, isRight: true)
                    }

                    var finalMaskL = raw.ccMaskL
                    var finalMaskR = raw.ccMaskR
                    var finalProbL: [Float]? = raw.probL
                    var finalProbR: [Float]? = raw.probR
                    var mw = W, mh = H
                    if let refined = refineWithSAM21Tiny(
                        cgImage: cleanSAM.cgImage,
                        rgb: cleanSAM.rgb,
                        cardRGB: prelimRGB,
                        barrier: mountAnalysis?.barrier,
                        srcW: width,
                        srcH: height,
                        boxL: roughBoxL,
                        boxR: roughBoxR,
                        refMaskL: raw.ccMaskL,
                        refMaskR: raw.ccMaskR,
                        probPhoto: probPhotoV3,
                        splitX: raw.splitX,
                        refW: W,
                        refH: H,
                        v3SeedHints: hints
                    ) {
                        finalMaskL = refined.maskL
                        finalMaskR = refined.maskR
                        finalProbL = refined.probL
                        finalProbR = refined.probR
                        mw = refined.w
                        mh = refined.h
                    }

                    let samCrop = finalizeExtractedPair(
                        rgb: rgb,
                        segRGB: cleanSAM.rgb,
                        width: width,
                        height: height,
                        finalMaskL: finalMaskL,
                        finalMaskR: finalMaskR,
                        probL: finalProbL,
                        probR: finalProbR,
                        mw: mw,
                        mh: mh,
                        mountAnalysis: mountAnalysis,
                        mode: mode
                    )
                    let totMs = (CFAbsoluteTimeGetCurrent() - tPipelineStart) * 1000.0
                    let rep = SegV3GateReport(
                        modelVersion: "v3",
                        decision: .fallback,
                        usedSAM2Fallback: true,
                        v3InferenceMs: v3InferMs,
                        totalElapsedMs: totMs,
                        tier1: tier1,
                        tier2: tier2,
                        tier3: tier3Metrics
                    )
                    lock.lock()
                    _latestGateReport = rep
                    lock.unlock()
                    NSLog("[StereoCardSegV3] decision=Fallback sam2=1 v3=%.2fms tot=%.1fms T1=%d(%@) T2=%@(%@) T3=%@",
                          v3InferMs, totMs, tier1.passed ? 1 : 0, tier1.reasons.joined(separator: ";"),
                          tier2.status.rawValue, tier2.reasons.joined(separator: ";"),
                          tier3Metrics?.reasons.joined(separator: ";") ?? "-")
                    return samCrop
                }

                if !tier1.passed || tier2.status == .fallback {
                    return runSAM2Fallback(tier3Metrics: nil)
                }

                // Pass / SoftWarn: SAM 2.1 をスキップして高速フィッティング + GPU 仕上げを実行し、第 3 層で整合性検証
                if let fastCrop = finalizeExtractedPair(
                    rgb: rgb,
                    segRGB: rgb,
                    width: width,
                    height: height,
                    finalMaskL: raw.ccMaskL,
                    finalMaskR: raw.ccMaskR,
                    probL: raw.probL,
                    probR: raw.probR,
                    mw: W,
                    mh: H,
                    mountAnalysis: mountAnalysis,
                    mode: mode
                ),
                   let postCtx = currentMountContext,
                   let postAlphas = currentFullCardAlphas {
                    let prelimTuple: (r: Double, g: Double, b: Double) = (
                        Double(postCtx.sampledCardRGB.r),
                        Double(postCtx.sampledCardRGB.g),
                        Double(postCtx.sampledCardRGB.b)
                    )
                    let tier3 = StereoCardSegV3Gate.evaluateTier3(
                        raw: raw,
                        refinedAlphaL: postAlphas.left,
                        refinedAlphaR: postAlphas.right,
                        cardRGB: postCtx.cardRGB,
                        cardW: postCtx.cardWidth,
                        cardH: postCtx.cardHeight,
                        prelimCardRGB: prelimTuple,
                        tier2: tier2
                    )
                    if tier3.passed {
                        let finalDecision: SegV3GateDecision = (tier2.status == .softWarn) ? .softWarn : .pass
                        let totMs = (CFAbsoluteTimeGetCurrent() - tPipelineStart) * 1000.0
                        let rep = SegV3GateReport(
                            modelVersion: "v3",
                            decision: finalDecision,
                            usedSAM2Fallback: false,
                            v3InferenceMs: v3InferMs,
                            totalElapsedMs: totMs,
                            tier1: tier1,
                            tier2: tier2,
                            tier3: tier3
                        )
                        lock.lock()
                        _latestGateReport = rep
                        lock.unlock()
                        NSLog("[StereoCardSegV3] decision=%@ sam2=0 v3=%.2fms tot=%.1fms core=%.3f b75=%.1f%% ent=%.3f iou=(%.2f,%.2f) edge=(avg=%.2f,worst=%.2f[%@])",
                              finalDecision.rawValue, v3InferMs, totMs,
                              tier2.coreConfidence, tier2.boundaryLow75Ratio * 100.0, tier2.boundaryNormEntropy,
                              tier3.postIoUL, tier3.postIoUR, tier3.overallEdgeSupport, tier3.worstEdgeSupport, tier3.worstEdgeName)
                        return fastCrop
                    } else {
                        return runSAM2Fallback(tier3Metrics: tier3)
                    }
                } else {
                    return runSAM2Fallback(tier3Metrics: nil)
                }
            }

            // 後方互換 (2クラス v2 モデル): 赤スタンプ中和版 rgb/cgImage を遅延生成
            let cleanDeskew = neutralizeRedWatermarkForSegmentation(
                rgb: rgb, width: width, height: height, fallbackCGImage: baseCGImage
            )
            let segRGB = cleanDeskew.rgb
            let cgImage = cleanDeskew.cgImage

            // logits shape: [1, 2, H=256, W=512] (0=Card/Bg, 1=Photo)
            var probPhoto = [Float](repeating: 0, count: W * H)

            if isFloat16 {
                let ptr16 = logits.dataPointer.assumingMemoryBound(to: Float16.self)
                for y in 0..<H {
                    let yOff = y * strideY
                    for x in 0..<W {
                        let base = yOff + x * strideX
                        let v0 = Float(ptr16[base])
                        let v1 = Float(ptr16[base + strideC])
                        let m = max(v0, v1)
                        let e0 = expf(v0 - m), e1 = expf(v1 - m)
                        probPhoto[y * W + x] = e1 / (e0 + e1)
                    }
                }
            } else {
                let ptr32 = logits.dataPointer.assumingMemoryBound(to: Float.self)
                for y in 0..<H {
                    let yOff = y * strideY
                    for x in 0..<W {
                        let base = yOff + x * strideX
                        let v0 = ptr32[base]
                        let v1 = ptr32[base + strideC]
                        let m = max(v0, v1)
                        let e0 = expf(v0 - m), e1 = expf(v1 - m)
                        probPhoto[y * W + x] = e1 / (e0 + e1)
                    }
                }
            }

            // Stage 1 外周連結台紙バリアによる強制 0 マスク（安全策3: 外周・中央連結領域のみをマスクし、月写真の宇宙空間など内部の平坦領域を保護）
            if let barrier = mountAnalysis?.barrier, barrier.model.confidence >= 0.25 {
                for y in 0..<H {
                    let ny = Double(y) / Double(max(1, H - 1))
                    let row = y * W
                    for x in 0..<W {
                        let nx = Double(x) / Double(max(1, W - 1))
                        if barrier.isConnectedBarrierAt(normX: nx, normY: ny) {
                            probPhoto[row + x] = 0.0
                        }
                    }
                }
            }

            // 中央付近 x ∈ [40%..60%] で写真確率の列平均が最小になる列を左右セパレータとして検出
            let c0 = Int(Double(W) * 0.40)
            let c1 = Int(Double(W) * 0.60)
            var splitX = W / 2
            var bestColMean = Float.greatestFiniteMagnitude
            var colMeans = [Float](repeating: 0.0, count: W)
            for x in 0..<W {
                var sum: Float = 0
                for y in 0..<H {
                    sum += probPhoto[y * W + x]
                }
                let mean = sum / Float(H)
                colMeans[x] = mean
                if x >= c0 && x < c1 && mean < bestColMean {
                    bestColMean = mean
                    splitX = x
                }
            }

            // ゼロギャップ・細線セパレータ・左右非対称マージン密着カード対策:
            // U-Netの確率谷が浅い（bestColMean >= 0.60）場合、または谷が幾何中心からズレた対称継ぎ目がある場合に物理垂直境界線へスナップ
            if (bestColMean >= 0.60 || bestColMean >= 0.12), width >= 64, height >= 64, rgb.count >= width * height * 3 {
                let sy0 = Int(Double(height) * 0.22)
                let sy1 = max(sy0 + 8, Int(Double(height) * 0.78))
                let stepY = max(1, (sy1 - sy0) / 48)
                var sampleCount = 0
                var yCheck = sy0
                while yCheck < sy1 { sampleCount += 1; yCheck += stepY }

                if sampleCount >= 8 {
                    func evalSeamColumn(_ ux: Int) -> (bestContrast: Double, physAtBestContrast: Double, bestPhys: Double, contrastAtBestPhys: Double) {
                        var bestC = 0.0, physAtC = 0.0
                        var bestP = 0.0, contrastAtP = 0.0
                        rgb.withUnsafeBufferPointer { ptr in
                            guard let base = ptr.baseAddress else { return }
                            func lumaAt(_ px: Int, _ py: Int) -> Double {
                                let cx = min(width - 1, max(0, px))
                                let i = (py * width + cx) * 3
                                return (Double(base[i]) + Double(base[i + 1]) + Double(base[i + 2])) / 3.0
                            }
                            let sxA = max(3, min(width - 4, ux * width / W))
                            let sxB = max(sxA + 1, min(width - 3, (ux + 1) * width / W))
                            for sx in sxA..<sxB {
                                var sumContrast = 0.0
                                var sumVertDiff = 0.0
                                var sumL = 0.0
                                var lumas: [Double] = []
                                lumas.reserveCapacity(sampleCount)

                                var y = sy0
                                var prevL: Double? = nil
                                while y < sy1 {
                                    let lc = lumaAt(sx, y)
                                    let lL1 = lumaAt(sx - 1, y)
                                    let lR1 = lumaAt(sx + 1, y)
                                    let lL3 = lumaAt(sx - 3, y)
                                    let lR3 = lumaAt(sx + 3, y)
                                    // 細い仕切り線（暗線・明線）または左右画面間の急峻なステップの両方を捉える
                                    let thinContrast = abs(lc - 0.5 * (lL3 + lR3))
                                    let stepContrast = max(abs(lR1 - lL1), abs(lR3 - lL3) * 0.7)
                                    sumContrast += max(thinContrast, stepContrast)
                                    if let p = prevL {
                                        sumVertDiff += abs(lc - p)
                                    }
                                    prevL = lc
                                    sumL += lc
                                    lumas.append(lc)
                                    y += stepY
                                }

                                let avgContrast = sumContrast / Double(lumas.count)
                                let avgVertDiff = sumVertDiff / Double(max(1, lumas.count - 1))
                                let meanL = sumL / Double(lumas.count)
                                let consistentCnt = lumas.filter { abs($0 - meanL) <= 24.0 }.count
                                let consistentRatio = Double(consistentCnt) / Double(lumas.count)
                                let phys = (avgContrast / (avgVertDiff + 8.0)) * (0.4 + 0.6 * consistentRatio)

                                if avgContrast > bestC {
                                    bestC = avgContrast
                                    physAtC = phys
                                }
                                if phys > bestP {
                                    bestP = phys
                                    contrastAtP = avgContrast
                                }
                            }
                        }
                        return (bestC, physAtC, bestP, contrastAtP)
                    }

                    if bestColMean >= 0.60 {
                        let tight0 = max(c0, Int(Double(W) * 0.44))
                        let tight1 = min(c1, Int(Double(W) * 0.56))
                        if tight1 > tight0 + 2 {
                            var bestHybridScore = -1.0
                            var bestHybridX = splitX
                            var peakLineContrast = 0.0
                            let sigma = max(4.0, Double(W) * 0.045)

                            for x in tight0..<tight1 {
                                let res = evalSeamColumn(x)
                                let dx = Double(x - W / 2)
                                let centerPrior = exp(-(dx * dx) / (2.0 * sigma * sigma))
                                let probValley = max(0.0, 1.0 - Double(colMeans[x]))
                                let score = (res.bestPhys + probValley * 3.0) * centerPrior
                                if score > bestHybridScore {
                                    bestHybridScore = score
                                    bestHybridX = x
                                    peakLineContrast = res.contrastAtBestPhys
                                }
                            }

                            if peakLineContrast >= 4.0 || bestColMean >= 0.85 {
                                splitX = bestHybridX
                            }
                        }
                    } else if let outerL = (0..<W).first(where: { colMeans[$0] >= 0.35 }),
                              let outerR = (0..<W).reversed().first(where: { colMeans[$0] >= 0.35 }),
                              outerR > outerL + W / 3 {
                        // 左右非対称マージン＋密着カード向けの対称物理継ぎ目補正
                        let midU = (outerL + outerR) / 2
                        if abs(splitX - midU) >= 5 && midU >= c0 && midU < c1 {
                            var uNearC = 0.0
                            for ux in max(c0, splitX - 2)...min(c1 - 1, splitX + 2) {
                                uNearC = max(uNearC, evalSeamColumn(ux).bestContrast)
                            }
                            var midBestX = midU
                            var midBestC = 0.0
                            var midBestP = 0.0
                            for ux in max(c0, midU - 4)...min(c1 - 1, midU + 4) {
                                let res = evalSeamColumn(ux)
                                if res.bestContrast > midBestC {
                                    midBestC = res.bestContrast
                                    midBestP = res.physAtBestContrast
                                    midBestX = ux
                                }
                            }
                            if midBestC >= 40.0 && midBestP >= 1.20 && midBestC >= uNearC * 1.6 {
                                splitX = midBestX
                            }
                        }
                    }
                }
            }

            var rawMaskL = [Bool](repeating: false, count: W * H)
            var rawMaskR = [Bool](repeating: false, count: W * H)
            var probL = [Float](repeating: 0, count: W * H)
            var probR = [Float](repeating: 0, count: W * H)

            for y in 0..<H {
                for x in 0..<W {
                    let idx = y * W + x
                    let p = probPhoto[idx]
                    if x < splitX {
                        probL[idx] = p
                        if p >= 0.5 { rawMaskL[idx] = true }
                    } else {
                        probR[idx] = p
                        if p >= 0.5 { rawMaskR[idx] = true }
                    }
                }
            }

            // 孤立ノイズを除去し最大連結成分 + HV凸包で穴埋め
            let maskL = hvConvexFill(rawMaskL, w: W, h: H)
            let maskR = hvConvexFill(rawMaskR, w: W, h: H)
            let cntL = maskL.reduce(0) { $0 + ($1 ? 1 : 0) }
            let cntR = maskR.reduce(0) { $0 + ($1 ? 1 : 0) }

            // 台紙なし通常 SBS 画像等（左右領域がそれぞれ 10% 未満、または背景が 4% 未満）なら nil を返してフォールバック
            let total = Double(W * H)
            let ratioL = Double(cntL) / total
            let ratioR = Double(cntR) / total
            let ratioBg = 1.0 - ratioL - ratioR
            guard ratioL >= 0.10, ratioR >= 0.10, ratioBg >= 0.04 else {
                return nil
            }

            guard var roughBoxL = robustBoundingBox(mask: maskL, w: W, h: H),
                  var roughBoxR = robustBoundingBox(mask: maskR, w: W, h: H) else {
                return nil
            }
            // 台紙境界エッジへのスナップ + 帯域検証付き左右上下Y範囲同期
            refineVerticalBoundsInMask(rgb: segRGB, srcW: width, srcH: height, boxL: &roughBoxL, boxR: &roughBoxR, maskW: W, maskH: H)
            syncRoughBoundsY(rgb: segRGB, srcW: width, srcH: height, boxL: &roughBoxL, boxR: &roughBoxR, maskW: W, maskH: H)

            lock.lock()
            let prelimCardLuma = latestCardLuma
            lock.unlock()
            let preLx0 = max(0, roughBoxL.minX * width / W)
            let preLx1 = min(width, (roughBoxL.maxX + 1) * width / W)
            var preLy0 = max(0, roughBoxL.minY * height / H)
            let preLy1 = min(height, (roughBoxL.maxY + 1) * height / H)
            let preRx0 = max(0, roughBoxR.minX * width / W)
            let preRx1 = min(width, (roughBoxR.maxX + 1) * width / W)
            var preRy0 = max(0, roughBoxR.minY * height / H)
            let preRy1 = min(height, (roughBoxR.maxY + 1) * height / H)
            let prelimCardRGB = Self.sampleLocalCardRGB(
                rgb: segRGB, srcW: width, srcH: height,
                yTop: min(preLy0, preRy0), yBot: max(preLy1, preRy1),
                xLeft: preLx0, xRight: preRx1,
                fallbackLuma: prelimCardLuma
            )
            if let prelimCardRGB {
                let origPreLy0 = preLy0
                let origPreRy0 = preRy0
                Self.recoverOvercroppedTopEdgeRGB(
                    rgb: segRGB, srcW: width, srcH: height,
                    cLx0: preLx0, cLx1: preLx1, cLy0: &preLy0, cLy1: preLy1,
                    cRx0: preRx0, cRx1: preRx1, cRy0: &preRy0, cRy1: preRy1,
                    cardRGB: prelimCardRGB,
                    barrier: mountAnalysis?.barrier
                )
                if preLy0 < origPreLy0 {
                    roughBoxL.minY = min(roughBoxL.minY, max(0, preLy0 * H / height))
                }
                if preRy0 < origPreRy0 {
                    roughBoxR.minY = min(roughBoxR.minY, max(0, preRy0 * H / height))
                }
            }

            var finalMaskL = maskL
            var finalMaskR = maskR
            var finalProbL: [Float]? = nil
            var finalProbR: [Float]? = nil
            var mw = W
            var mh = H

            let refinedResult = refineWithSAM21Tiny(
                cgImage: cgImage,
                rgb: segRGB,
                cardRGB: prelimCardRGB,
                barrier: mountAnalysis?.barrier,
                srcW: width,
                srcH: height,
                boxL: roughBoxL,
                boxR: roughBoxR,
                refMaskL: maskL,
                refMaskR: maskR,
                probPhoto: probPhoto,
                splitX: splitX,
                refW: W,
                refH: H
            )

            if let refined = refinedResult {
                finalMaskL = refined.maskL
                finalMaskR = refined.maskR
                finalProbL = refined.probL
                finalProbR = refined.probR
                mw = refined.w
                mh = refined.h
            }

            return finalizeExtractedPair(
                rgb: rgb,
                segRGB: segRGB,
                width: width,
                height: height,
                finalMaskL: finalMaskL,
                finalMaskR: finalMaskR,
                probL: finalProbL,
                probR: finalProbR,
                mw: mw,
                mh: mh,
                mountAnalysis: mountAnalysis,
                mode: mode
            )
        } catch {
            return nil
        }
    }

    /// Core ML を使わず 3段階数理解析 (Stage 0/1/2) と同一の高精度境界精密化パイプラインでステレオカードを切り出す
    func extractPhotoPairHeuristic(
        from inputRGB: [UInt8],
        width inputImgW: Int,
        height inputImgH: Int,
        mode: StereoCardCropper.ExtractionMode
    ) -> StereoCardCropper.CropResult? {
        clearCurrentContext()
        guard inputImgW >= 64, inputImgH >= 32, inputRGB.count >= inputImgW * inputImgH * 3,
              let rawCGImage = makeCGImage(from: inputRGB, width: inputImgW, height: inputImgH) else {
            return nil
        }

        guard let mountAnalysis = StereoCardMountAnalyzer.analyze(cgImage: rawCGImage, rgb: inputRGB),
              mountAnalysis.barrier.model.confidence >= 0.25 else {
            return nil
        }

        let rgb: [UInt8]
        let baseCGImage: CGImage
        let width: Int
        let height: Int
        if mountAnalysis.deskew.hasScanMargin,
           mountAnalysis.deskew.width >= 64, mountAnalysis.deskew.height >= 32,
           mountAnalysis.deskew.deskewedRGB.count >= mountAnalysis.deskew.width * mountAnalysis.deskew.height * 3 {
            rgb = mountAnalysis.deskew.deskewedRGB
            width = mountAnalysis.deskew.width
            height = mountAnalysis.deskew.height
            baseCGImage = mountAnalysis.deskew.deskewedImage
        } else {
            rgb = inputRGB
            width = inputImgW
            height = inputImgH
            baseCGImage = rawCGImage
        }
        let cleanDeskew = neutralizeRedWatermarkForSegmentation(
            rgb: rgb, width: width, height: height, fallbackCGImage: baseCGImage
        )
        let segRGB = cleanDeskew.rgb

        let barrier = mountAnalysis.barrier
        let bw = barrier.width
        let bh = barrier.height
        guard bw >= 16, bh >= 16, barrier.connectedBarrierMask.count >= bw * bh else { return nil }

        // 1. segRGB の左右外周帯（スタンプ除外・上半身帯）から台紙代表色 refCardRGB を算出
        let refCardRGB: (r: Double, g: Double, b: Double) = {
            var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
            let yA = Int(Double(height) * 0.20), yB = Int(Double(height) * 0.55)
            let xLA = Int(Double(width) * 0.03), xLB = Int(Double(width) * 0.08)
            let xRA = Int(Double(width) * 0.92), xRB = Int(Double(width) * 0.97)
            let stY = max(1, (yB - yA) / 20), stX = max(1, (xLB - xLA) / 10)
            segRGB.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                var y = yA
                while y < yB {
                    for (xa, xb) in [(xLA, xLB), (xRA, xRB)] {
                        var x = xa
                        while x < xb {
                            let i = (y * width + x) * 3
                            let r = Double(base[i]), g = Double(base[i + 1]), b = Double(base[i + 2])
                            let l = (r + g + b) / 3.0
                            if l > 28.0 && l < 232.0 {
                                rs.append(r); gs.append(g); bs.append(b)
                            }
                            x += stX
                        }
                    }
                    y += stY
                }
            }
            if rs.count >= 12 {
                rs.sort(); gs.sort(); bs.sort()
                let m = rs.count / 2
                return (rs[m], gs[m], bs[m])
            }
            // フォールバック: barrier 確率上位画素の平均
            var sumR = 0.0, sumG = 0.0, sumB = 0.0, cnt = 0.0
            for by in (bh / 6)..<(bh / 2) {
                for bx in 0..<bw where barrier.probabilities[by * bw + bx] >= 0.80 {
                    let sx = min(width - 1, bx * width / bw)
                    let sy = min(height - 1, by * height / bh)
                    let i = (sy * width + sx) * 3
                    sumR += Double(segRGB[i]); sumG += Double(segRGB[i + 1]); sumB += Double(segRGB[i + 2])
                    cnt += 1.0
                }
            }
            if cnt > 0 { return (sumR / cnt, sumG / cnt, sumB / cnt) }
            return (195.0, 195.0, 195.0)
        }()

        // 2. 各列 x の前景率 colFg[x] 算出と左右外端 photoX0, photoX1 の決定
        var colFg = [Double](repeating: 0.0, count: bw)
        var colBar = [Double](repeating: 0.0, count: bw)
        var colCard = [Double](repeating: 0.0, count: bw)
        let yTopGrid = max(0, Int(Double(bh) * 0.18))
        let yBotGridL = min(bh, Int(Double(bh) * 0.80))
        let yBotGridR = min(bh, Int(Double(bh) * 0.66))

        segRGB.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for x in 0..<bw {
                let yBotG = (x < bw / 2) ? yBotGridL : yBotGridR
                guard yBotG > yTopGrid else { continue }
                let sx = min(width - 2, max(1, x * width / bw))
                var fgCnt = 0, barCnt = 0, cardCnt = 0, tot = 0
                for y in yTopGrid..<yBotG {
                    let idx = y * bw + x
                    let sy = min(height - 1, y * height / bh)
                    let off = (sy * width + sx) * 3
                    let offL = (sy * width + (sx - 1)) * 3
                    let offR = (sy * width + (sx + 1)) * 3
                    let r = Double(base[off]), g = Double(base[off + 1]), b = Double(base[off + 2])
                    let lC = (r + g + b) / 3.0
                    let lL = (Double(base[offL]) + Double(base[offL + 1]) + Double(base[offL + 2])) / 3.0
                    let lR = (Double(base[offR]) + Double(base[offR + 1]) + Double(base[offR + 2])) / 3.0
                    let dCard = max(abs(r - refCardRGB.r), max(abs(g - refCardRGB.g), abs(b - refCardRGB.b)))
                    let hDiff = max(abs(lC - lL), abs(lR - lC))
                    let isBar = barrier.connectedBarrierMask[idx]
                    if isBar { barCnt += 1 }
                    if dCard <= 22.0 { cardCnt += 1 }
                    if !isBar && barrier.probabilities[idx] < 0.50 && (dCard > 22.0 || hDiff > 10.0) {
                        fgCnt += 1
                    }
                    tot += 1
                }
                if tot > 0 {
                    colFg[x] = Double(fgCnt) / Double(tot)
                    colBar[x] = Double(barCnt) / Double(tot)
                    colCard[x] = Double(cardCnt) / Double(tot)
                }
            }
        }

        let minScanX = max(1, Int(Double(bw) * 0.03))
        let maxScanX = min(bw - 2, Int(Double(bw) * 0.97))
        var photoX0 = Int(Double(bw) * 0.08)
        if minScanX + 2 <= maxScanX {
            for x in minScanX...(maxScanX - 2) {
                if colFg[x] >= 0.30 && colFg[x + 1] >= 0.30 && colFg[x + 2] >= 0.30 {
                    photoX0 = x
                    break
                }
            }
        }
        var photoX1 = Int(Double(bw) * 0.92)
        if maxScanX - 2 >= minScanX {
            for x in stride(from: maxScanX, through: minScanX + 2, by: -1) {
                if colFg[x] >= 0.30 && colFg[x - 1] >= 0.30 && colFg[x - 2] >= 0.30 {
                    photoX1 = x
                    break
                }
            }
        }

        // 3. 中央分割区間 [splitLeftEnd, splitRightStart] の決定（常に中央 43%..57% を探索し、淡色右端に影響されない）
        let c0 = max(2, Int(Double(bw) * 0.43))
        let c1 = min(bw - 3, Int(Double(bw) * 0.57))
        var splitLeftEnd = bw / 2
        var splitRightStart = bw / 2

        var bestGapLen = 0, bestGapStart = 0
        var curLen = 0, curStart = 0
        for x in c0...c1 {
            let isGap = (colFg[x] <= 0.15) && (colBar[x] >= 0.45 || colCard[x] >= 0.65)
            if isGap {
                if curLen == 0 { curStart = x }
                curLen += 1
                if curLen > bestGapLen {
                    bestGapLen = curLen
                    bestGapStart = curStart
                }
            } else {
                curLen = 0
            }
        }

        if bestGapLen >= 2 {
            splitLeftEnd = bestGapStart
            splitRightStart = bestGapStart + bestGapLen
        } else {
            // 密着型カード: フル解像度 segRGB の垂直継ぎ目スコア最大列（中心 prior: bw/2, sigma: 0.055*bw）
            var seamX = bw / 2
            if width >= 64, height >= 64, segRGB.count >= width * height * 3 {
                let py0 = Int(Double(height) * 0.22)
                let py1 = max(py0 + 8, Int(Double(height) * 0.78))
                let stepY = max(1, (py1 - py0) / 48)
                var bestScore = -1.0
                let sigma = max(4.0, Double(bw) * 0.055)
                let midCenter = Double(bw) * 0.5
                segRGB.withUnsafeBufferPointer { ptr in
                    guard let base = ptr.baseAddress else { return }
                    func luma(_ px: Int, _ py: Int) -> Double {
                        let cx = min(width - 1, max(0, px))
                        let i = (py * width + cx) * 3
                        return (Double(base[i]) + Double(base[i + 1]) + Double(base[i + 2])) / 3.0
                    }
                    for ux in c0...c1 {
                        let sx = min(width - 4, max(3, ux * width / bw))
                        var sumC = 0.0, cnt = 0
                        var y = py0
                        while y < py1 {
                            let lc = luma(sx, y)
                            let lL1 = luma(sx - 1, y), lR1 = luma(sx + 1, y)
                            let lL3 = luma(sx - 3, y), lR3 = luma(sx + 3, y)
                            let thinC = abs(lc - 0.5 * (lL3 + lR3))
                            let stepC = max(abs(lR1 - lL1), abs(lR3 - lL3) * 0.7)
                            sumC += max(thinC, stepC)
                            cnt += 1
                            y += stepY
                        }
                        let avgC = cnt > 0 ? (sumC / Double(cnt)) : 0.0
                        let dx = Double(ux) - midCenter
                        let prior = exp(-(dx * dx) / (2.0 * sigma * sigma))
                        let score = avgC * prior
                        if score > bestScore {
                            bestScore = score
                            seamX = ux
                        }
                    }
                }
            }
            splitLeftEnd = seamX
            splitRightStart = seamX
        }

        // 4. 左右対称幅の救済（11603-7589 のような淡色端が反対側より 6% 以上狭い場合、真のバリア帯まで復元）
        func hasBarrierWall(from xA: Int, to xB: Int) -> Bool {
            let lo = max(0, min(xA, xB))
            let hi = min(bw - 1, max(xA, xB))
            guard hi - lo >= 2 else { return false }
            var streak = 0
            for x in lo...hi {
                var hits = 0, tot = 0
                for y in (bh / 5)..<(bh * 13 / 20) {
                    if barrier.connectedBarrierMask[y * bw + x] { hits += 1 }
                    tot += 1
                }
                if tot > 0 && Double(hits) / Double(tot) >= 0.55 {
                    streak += 1
                    if streak >= 3 { return true }
                } else {
                    streak = 0
                }
            }
            return false
        }

        let leftW = max(1, splitLeftEnd - photoX0)
        let rightW = max(1, photoX1 - splitRightStart + 1)
        if Double(rightW) < Double(leftW) * 0.94 {
            let candX1 = min(bw - 2, splitRightStart + leftW - 1)
            if candX1 > photoX1 && !hasBarrierWall(from: photoX1 + 1, to: candX1) {
                photoX1 = candX1
            }
        } else if Double(leftW) < Double(rightW) * 0.94 {
            let candX0 = max(1, splitLeftEnd - rightW)
            if candX0 < photoX0 && !hasBarrierWall(from: candX0, to: photoX0 - 1) {
                photoX0 = candX0
            }
        }

        let twin = mountAnalysis.twinWindow
        let useTwinSeed = twin.fitScore >= 0.40
        let rectL = twin.normalizedRect(isLeft: true)
        let rectR = twin.normalizedRect(isLeft: false)
        var rawMaskL = [Bool](repeating: false, count: bw * bh)
        var rawMaskR = [Bool](repeating: false, count: bw * bh)

        for y in 0..<bh {
            let ny = CGFloat(y) / CGFloat(max(1, bh - 1))
            let row = y * bw
            for x in 0..<bw {
                let idx = row + x
                if barrier.connectedBarrierMask[idx] || barrier.probabilities[idx] >= 0.58 {
                    continue
                }
                if x >= photoX0 && x < splitLeftEnd {
                    if !useTwinSeed || (ny >= rectL.minY - 0.08 && ny <= rectL.maxY + 0.08) {
                        rawMaskL[idx] = true
                    }
                } else if x >= splitRightStart && x <= photoX1 {
                    if !useTwinSeed || (ny >= rectR.minY - 0.08 && ny <= rectR.maxY + 0.08) {
                        rawMaskR[idx] = true
                    }
                }
            }
        }

        let maskL = hvConvexFill(rawMaskL, w: bw, h: bh)
        let maskR = hvConvexFill(rawMaskR, w: bw, h: bh)
        let total = Double(bw * bh)
        let cntL = maskL.reduce(0) { $0 + ($1 ? 1 : 0) }
        let cntR = maskR.reduce(0) { $0 + ($1 ? 1 : 0) }
        let ratioL = Double(cntL) / total
        let ratioR = Double(cntR) / total
        guard ratioL >= 0.10, ratioR >= 0.10, (1.0 - ratioL - ratioR) >= 0.04 else {
            return nil
        }

        return finalizeExtractedPair(
            rgb: rgb,
            segRGB: segRGB,
            width: width,
            height: height,
            finalMaskL: maskL,
            finalMaskR: maskR,
            mw: bw,
            mh: bh,
            mountAnalysis: mountAnalysis,
            mode: mode
        )
    }

    private func finalizeExtractedPair(
        rgb: [UInt8],
        segRGB: [UInt8],
        width: Int,
        height: Int,
        finalMaskL: [Bool],
        finalMaskR: [Bool],
        probL: [Float]? = nil,
        probR: [Float]? = nil,
        mw: Int,
        mh: Int,
        mountAnalysis: MountAnalysisOutput?,
        mode: StereoCardCropper.ExtractionMode
    ) -> StereoCardCropper.CropResult? {
            let invScaleX = Double(width) / Double(mw)
            let invScaleY = Double(height) / Double(mh)

            // 共通: 外枠バウンディングボックス・台紙地色・傾き角・アーチ形状の推定（OriginalMountContext 用）
            guard var boxL = robustBoundingBox(mask: finalMaskL, w: mw, h: mh),
                  var boxR = robustBoundingBox(mask: finalMaskR, w: mw, h: mh) else {
                return nil
            }
            trimOuterLabelBorders(rgb: segRGB, srcW: width, srcH: height, boxL: &boxL, boxR: &boxR, maskW: mw, maskH: mh)
            var archParams = estimateArchParams(maskL: finalMaskL, boxL: boxL, maskR: finalMaskR, boxR: boxR, w: mw, h: mh)
            lock.lock()
            let cardLuma = latestCardLuma
            lock.unlock()

            let rawLx0 = Double(boxL.minX) * invScaleX
            let rawLx1 = Double(boxL.maxX + 1) * invScaleX
            var rawLy0 = Double(boxL.minY) * invScaleY
            var rawLy1 = Double(boxL.maxY + 1) * invScaleY
            let insetLX = 1.0

            let rawRx0 = Double(boxR.minX) * invScaleX
            let rawRx1 = Double(boxR.maxX + 1) * invScaleX
            var rawRy0 = Double(boxR.minY) * invScaleY
            var rawRy1 = Double(boxR.maxY + 1) * invScaleY

            do {
                let (vl, vr) = refineVerticalBoundsPair(
                    rgb: segRGB, srcW: width, srcH: height,
                    left: (Int(rawLx0), Int(rawLx1), Int(rawLy0), Int(rawLy1)),
                    right: (Int(rawRx0), Int(rawRx1), Int(rawRy0), Int(rawRy1))
                )
                rawLy0 = Double(vl.y0); rawLy1 = Double(vl.y1 + 1)
                rawRy0 = Double(vr.y0); rawRy1 = Double(vr.y1 + 1)
            }
            let hasTopArch = archParams.topRxRatio >= 0.05 || archParams.topRyRatio >= 0.05
            let insetRX = 1.0
            let insetRY = 1.0
            let insetLY = 1.0
            let insetTopL = hasTopArch ? 0.0 : insetLY
            let insetTopR = hasTopArch ? 0.0 : insetRY

            var cLx0 = max(0, Int(floor(rawLx0 + insetLX)))
            var cLx1 = min(width, Int(ceil(rawLx1 - insetLX)))
            var cLy0 = max(0, Int(floor(rawLy0 + insetTopL)))
            var cLy1 = min(height, Int(floor(rawLy1 - insetLY)))

            var cRx0 = max(0, Int(floor(rawRx0 + insetRX)))
            var cRx1 = min(width, Int(ceil(rawRx1 - insetRX)))
            var cRy0 = max(0, Int(floor(rawRy0 + insetTopR)))
            var cRy1 = min(height, Int(floor(rawRy1 - insetRY)))

            trimHorizontalCardBorders(rgb: segRGB, srcW: width, srcH: height, x0: cLx0, x1: cLx1, y0: &cLy0, y1: &cLy1)
            trimHorizontalCardBorders(rgb: segRGB, srcW: width, srcH: height, x0: cRx0, x1: cRx1, y0: &cRy0, y1: &cRy1)

            let effectiveCardRGB = Self.sampleLocalCardRGB(
                rgb: segRGB, srcW: width, srcH: height,
                yTop: min(cLy0, cRy0), yBot: max(cLy1, cRy1),
                xLeft: cLx0, xRight: cRx1,
                fallbackLuma: cardLuma
            )

            if let effectiveCardRGB {
                Self.recoverOvercroppedTopEdgeRGB(
                    rgb: segRGB, srcW: width, srcH: height,
                    cLx0: cLx0, cLx1: cLx1, cLy0: &cLy0, cLy1: cLy1,
                    cRx0: cRx0, cRx1: cRx1, cRy0: &cRy0, cRy1: cRy1,
                    cardRGB: effectiveCardRGB,
                    barrier: mountAnalysis?.barrier
                )
                Self.recoverOvercroppedBottomEdgeRGB(
                    rgb: segRGB, srcW: width, srcH: height,
                    cLx0: cLx0, cLx1: cLx1, cLy0: cLy0, cLy1: &cLy1,
                    cRx0: cRx0, cRx1: cRx1, cRy0: cRy0, cRy1: &cRy1,
                    cardRGB: effectiveCardRGB,
                    barrier: mountAnalysis?.barrier
                )
            }

            Self.trimHorizontalCardAndCaptionBorders(
                rgb: segRGB, srcW: width, srcH: height,
                cLx0: cLx0, cLx1: cLx1, cLy0: &cLy0, cLy1: &cLy1,
                cRx0: cRx0, cRx1: cRx1, cRy0: &cRy0, cRy1: &cRy1,
                cardRGB: effectiveCardRGB,
                barrier: mountAnalysis?.barrier
            )
            if let effectiveCardRGB {
                Self.trimOuterCardColumnsRGB(
                    rgb: segRGB, srcW: width, srcH: height,
                    cLx0: &cLx0, cLx1: &cLx1, cLy0: cLy0, cLy1: cLy1,
                    cRx0: &cRx0, cRx1: &cRx1, cRy0: cRy0, cRy1: cRy1,
                    cardRGB: effectiveCardRGB
                )
                Self.recoverOvercroppedHorizontalEdgesRGB(
                    rgb: segRGB, srcW: width, srcH: height,
                    cLx0: &cLx0, cLx1: &cLx1, cLy0: cLy0, cLy1: cLy1,
                    cRx0: &cRx0, cRx1: &cRx1, cRy0: cRy0, cRy1: cRy1,
                    cardRGB: effectiveCardRGB,
                    barrier: mountAnalysis?.barrier
                )
                // 水平トリム・リカバリ後の最終段階で写真上端（空等）を再回復
                Self.recoverOvercroppedTopEdgeRGB(
                    rgb: segRGB, srcW: width, srcH: height,
                    cLx0: cLx0, cLx1: cLx1, cLy0: &cLy0, cLy1: cLy1,
                    cRx0: cRx0, cRx1: cRx1, cRy0: &cRy0, cRy1: cRy1,
                    cardRGB: effectiveCardRGB,
                    barrier: mountAnalysis?.barrier
                )
            }

            // 上端過剰クロップ防止セーフティガード（富士山頂・空等のグラデーション領域が台紙と誤認されて削られるのを防止）
            var topBorderEnd = 0
            do {
                let midLX = (cLx0 + cLx1) / 2
                let midRX = (cRx0 + cRx1) / 2
                while topBorderEnd < min(height / 8, 32) {
                    let offL = (topBorderEnd * width + midLX) * 3
                    let offR = (topBorderEnd * width + midRX) * 3
                    let lL = (Double(rgb[offL]) + Double(rgb[offL + 1]) + Double(rgb[offL + 2])) / 3.0
                    let lR = (Double(rgb[offR]) + Double(rgb[offR + 1]) + Double(rgb[offR + 2])) / 3.0
                    if max(lL, lR) <= 35.0 {
                        topBorderEnd += 1
                    } else {
                        break
                    }
                }
                if topBorderEnd > 0 {
                    let safeTop = topBorderEnd + 1
                    let fbLuma = cardLuma ?? 200.0
                    let refRGB = effectiveCardRGB ?? (r: fbLuma, g: fbLuma, b: fbLuma)
                    // topBorderEnd から cLy0 までの間に台紙色が支配的である場合、それは台紙余白なので cLy0 を safeTop に引き上げてはならない
                    func isCardBetween(y0: Int, y1: Int, x: Int) -> Bool {
                        guard y1 > y0 else { return false }
                        var cardCount = 0
                        let total = y1 - y0
                        for y in y0..<y1 {
                            let idx = (y * width + x) * 3
                            let r = Double(rgb[idx]), g = Double(rgb[idx + 1]), b = Double(rgb[idx + 2])
                            let dr = abs(r - refRGB.r)
                            let dg = abs(g - refRGB.g)
                            let db = abs(b - refRGB.b)
                            if max(dr, max(dg, db)) <= 30.0 {
                                cardCount += 1
                            }
                        }
                        return Double(cardCount) / Double(total) >= 0.50
                    }
                    if cLy0 > safeTop + 6 && !isCardBetween(y0: safeTop, y1: cLy0, x: midLX) {
                        let blockedByBarrier = mountAnalysis?.barrier.isMountBarrierRow(
                            normalizedY: CGFloat((safeTop + cLy0) / 2) / CGFloat(max(1, height - 1)),
                            normalizedXRange: 0.15...0.40,
                            threshold: 0.55
                        ) ?? false
                        if !blockedByBarrier { cLy0 = safeTop }
                    }
                    if cRy0 > safeTop + 6 && !isCardBetween(y0: safeTop, y1: cRy0, x: midRX) {
                        let blockedByBarrier = mountAnalysis?.barrier.isMountBarrierRow(
                            normalizedY: CGFloat((safeTop + cRy0) / 2) / CGFloat(max(1, height - 1)),
                            normalizedXRange: 0.60...0.85,
                            threshold: 0.55
                        ) ?? false
                        if !blockedByBarrier { cRy0 = safeTop }
                    }
                }
            }

            // Stage 1/2 外周連結バリアによる上端・下端残留台紙の押し出しガード
            if let analysis = mountAnalysis, analysis.barrier.model.confidence >= 0.25 {
                let barrier = analysis.barrier
                func pushPastBarrier(y0: Int, y1: Int, x0: Int, x1: Int, fromTop: Bool, isRight: Bool) -> Int {
                    if fromTop {
                        let limit = min(y1 - 48, y0 + max(8, Int(Double(height) * 0.10)))
                        var y = y0
                        while y < limit {
                            if Self.isPureMountBarrierRow(
                                rgb: segRGB, width: width, height: height,
                                y: y, x0: x0, x1: x1, isRightSide: false,
                                scanningFromTop: true, cardRGB: effectiveCardRGB, barrier: barrier,
                                minConnRatio: 0.40, minRowConnRatio: 0.15
                            ) {
                                y += 1
                            } else {
                                break
                            }
                        }
                        return y
                    } else {
                        let limit = max(y0 + 48, y1 - max(8, Int(Double(height) * 0.22)))
                        var curY1 = y1
                        while curY1 > limit {
                            let y = curY1 - 1
                            if Self.isPureMountBarrierRow(
                                rgb: segRGB, width: width, height: height,
                                y: y, x0: x0, x1: x1, isRightSide: isRight,
                                scanningFromTop: false, cardRGB: effectiveCardRGB, barrier: barrier,
                                minConnRatio: 0.45, minRowConnRatio: 0.20
                            ) {
                                curY1 = y
                            } else {
                                break
                            }
                        }
                        return curY1
                    }
                }
                cLy0 = pushPastBarrier(y0: cLy0, y1: cLy1, x0: cLx0, x1: cLx1, fromTop: true, isRight: false)
                cRy0 = pushPastBarrier(y0: cRy0, y1: cRy1, x0: cRx0, x1: cRx1, fromTop: true, isRight: false)
                if analysis.barrier.model.confidence >= 0.35 {
                    cLy1 = pushPastBarrier(y0: cLy0, y1: cLy1, x0: cLx0, x1: cLx1, fromTop: false, isRight: false)
                    cRy1 = pushPastBarrier(y0: cRy0, y1: cRy1, x0: cRx0, x1: cRx1, fromTop: false, isRight: true)
                }
            }

            // アーチ頂点精密検出（上部アーチがある場合、中央付近の列で台紙から写真への真の境界Yを検出）
            let isSquareByTwin = (mountAnalysis?.twinWindow.cutType == .square && (mountAnalysis?.twinWindow.fitScore ?? 0) >= 0.50)
            let effectiveHasTopArch = hasTopArch && !(isSquareByTwin && archParams.topRyRatio < 0.14)
            if effectiveHasTopArch, let card = effectiveCardRGB ?? (cardLuma.map { (r: $0, g: $0, b: $0) }) {
                let barrier = mountAnalysis?.barrier
                func detectApexY(x0: Int, x1: Int, currentY0: Int) -> Int {
                    let bw = x1 - x0
                    let midX = (x0 + x1) / 2
                    let scanX0 = max(0, midX - Int(Double(bw) * 0.08))
                    let scanX1 = min(width - 1, midX + Int(Double(bw) * 0.08))
                    guard scanX1 > scanX0 else { return currentY0 }
                    let step = max(1, (scanX1 - scanX0) / 9)
                    var apexYList: [Int] = []
                    let minY = max(topBorderEnd + 4, currentY0 - 14)
                    let maxY = min(height - 10, currentY0 + 35)
                    guard maxY > minY + 8 else { return currentY0 }
                    let runLen = 6
                    for x in stride(from: scanX0, through: scanX1, by: step) {
                        for y in minY..<(maxY - runLen) {
                            var nonCard = 0
                            for k in 0..<runLen {
                                let py = y + k
                                let idx = (py * width + x) * 3
                                let r = Double(rgb[idx]), g = Double(rgb[idx + 1]), b = Double(rgb[idx + 2])
                                let luma = (r + g + b) / 3.0
                                if py <= topBorderEnd + 2 && luma <= 35.0 {
                                    // 画像上端直後のスキャナ黒枠は写真ではない
                                    nonCard = 0
                                    break
                                }
                                // カード外縁の白スキャン余白（低彩度・高輝度）は写真ではない
                                let chroma = max(r, max(g, b)) - min(r, min(g, b))
                                if py < currentY0 && luma >= 232.0 && chroma <= 18.0 {
                                    nonCard = 0
                                    break
                                }
                                if let bMap = barrier, bMap.model.confidence >= 0.25,
                                   bMap.isConnectedBarrierAt(normX: Double(x) / Double(max(1, width - 1)), normY: Double(py) / Double(max(1, height - 1))) {
                                    // Stage 1 外周連結台紙バリア（および外縁ドロップシャドウ）上は写真頂点ではない
                                    nonCard = 0
                                    break
                                }
                                let dr = abs(r - card.r), dg = abs(g - card.g), db = abs(b - card.b)
                                if max(dr, max(dg, db)) > 26.0 {
                                    nonCard += 1
                                }
                            }
                            if nonCard >= runLen - 1 {
                                // y が currentY0 より上にある場合、y+runLen ..< currentY0 の間に台紙帯が挟まっていればカード外縁の誤認なので棄却
                                var hasCardGapBelow = false
                                if y + runLen < currentY0 {
                                    var cardGapCount = 0
                                    let checkEnd = currentY0
                                    let checkStart = y + runLen
                                    for gy in checkStart..<checkEnd {
                                        let gIdx = (gy * width + x) * 3
                                        let dr = abs(Double(rgb[gIdx]) - card.r)
                                        let dg = abs(Double(rgb[gIdx + 1]) - card.g)
                                        let db = abs(Double(rgb[gIdx + 2]) - card.b)
                                        if max(dr, max(dg, db)) <= 24.0 {
                                            cardGapCount += 1
                                        }
                                    }
                                    if cardGapCount >= max(3, (checkEnd - checkStart) / 2) {
                                        hasCardGapBelow = true
                                    }
                                }
                                if !hasCardGapBelow {
                                    apexYList.append(y)
                                    break
                                }
                            }
                        }
                    }
                    if apexYList.count >= 3 {
                        apexYList.sort()
                        return apexYList[apexYList.count / 2]
                    }
                    return currentY0
                }
                let apexL = detectApexY(x0: cLx0, x1: cLx1, currentY0: cLy0)
                let apexR = detectApexY(x0: cRx0, x1: cRx1, currentY0: cRy0)
                if abs(apexL - apexR) >= 4 {
                    let topApex = min(apexL, apexR)
                    cLy0 = topApex
                    cRy0 = topApex
                } else {
                    cLy0 = apexL
                    cRy0 = apexR
                }
            }

            // SAM 2.1（高充填率通過済み）の実上端が、外周台紙バリア外の写真上空を捉えているのに
            // 行統計トリムで下に削られた場合は上端を保護して引き戻す
            if probL != nil {
                let samTopL = max(topBorderEnd, Int(floor(Double(boxL.minY) * invScaleY)))
                if samTopL < cLy0 {
                    let midX = (cLx0 + cLx1) / 2
                    let midY = (samTopL + cLy0) / 2
                    let isBar = mountAnalysis?.barrier.isConnectedBarrierAt(
                        normX: Double(midX) / Double(max(1, width - 1)),
                        normY: Double(midY) / Double(max(1, height - 1))
                    ) ?? false
                    if !isBar {
                        cLy0 = samTopL
                    }
                }
            }
            if probR != nil {
                let samTopR = max(topBorderEnd, Int(floor(Double(boxR.minY) * invScaleY)))
                if samTopR < cRy0 {
                    let midX = (cRx0 + cRx1) / 2
                    let midY = (samTopR + cRy0) / 2
                    let isBar = mountAnalysis?.barrier.isConnectedBarrierAt(
                        normX: Double(midX) / Double(max(1, width - 1)),
                        normY: Double(midY) / Double(max(1, height - 1))
                    ) ?? false
                    if !isBar {
                        cRy0 = samTopR
                    }
                }
            }
            if abs(cLy0 - cRy0) <= max(6, Int(Double(height) * 0.015)) {
                let topSynced = min(cLy0, cRy0)
                cLy0 = topSynced
                cRy0 = topSynced
            }

            let lw = cLx1 - cLx0, lh = cLy1 - cLy0
            let rw = cRx1 - cRx0, rh = cRy1 - cRy0
            var cw = min(lw, rw), ch = min(lh, rh)
            guard cw >= max(64, Int(Double(width) * 0.25)),
                  ch >= max(64, Int(Double(height) * 0.40)) else {
                return nil
            }

            // 中央セパレータ（内側エッジ cLx1, cRx0）を基準にして外側の余分な枠を切り落とす
            let startLX = max(0, cLx1 - cw)
            let startLY: Int
            let startRX = min(width - cw, cRx0)
            let startRY: Int
            if hasTopArch {
                // 上部アーチカードではアーチ頂点 (y0) を幾何学的基準として上端揃えにする
                startLY = cLy0
                startRY = cRy0
            } else {
                startLY = cLy0 + (lh - ch) / 2
                startRY = cRy0 + (rh - ch) / 2
            }

            let commonSkewAngle = Self.estimateSkewAngle(maskL: finalMaskL, boxL: boxL, maskR: finalMaskR, boxR: boxR, w: mw, h: mh)
            let centerLX = Double(startLX) + Double(cw) * 0.5
            let centerLY = Double(startLY) + Double(ch) * 0.5
            let centerRX = Double(startRX) + Double(cw) * 0.5
            let centerRY = Double(startRY) + Double(ch) * 0.5

            var fullOutL = cropRotatedRGB(rgb, srcW: width, srcH: height, centerX: centerLX, centerY: centerLY, width: cw, height: ch, angleRad: commonSkewAngle)
            var fullOutR = cropRotatedRGB(rgb, srcW: width, srcH: height, centerX: centerRX, centerY: centerRY, width: cw, height: ch, angleRad: commonSkewAngle)
            var emptyAlphaL: [UInt8] = []
            var emptyAlphaR: [UInt8] = []
            let trimBorderInsets = Self.trimOuterBlackBorders(
                leftRGB: &fullOutL,
                rightRGB: &fullOutR,
                leftAlpha: &emptyAlphaL,
                rightAlpha: &emptyAlphaR,
                width: &cw,
                height: &ch
            )

            // 最終出力の上端に残った数pxの台紙帯を安全に除去
            var appliedTopTrim = 0
            if let cRGB = effectiveCardRGB {
                let cLuma = (cRGB.r + cRGB.g + cRGB.b) / 3.0
                if cLuma >= 95.0 || max(cRGB.r, max(cRGB.g, cRGB.b)) >= 140.0 {
                    let maxTopTrim = min(24, ch / 12)
                    var topTrim = 0
                    let x0 = hasTopArch ? (cw * 2) / 5 : cw / 4
                    let x1 = hasTopArch ? (cw * 3) / 5 : (cw * 3) / 4
                    let colorTol = hasTopArch ? 24.0 : 42.0
                    let reqRate = hasTopArch ? 0.70 : 0.40
                    for y in 0..<maxTopTrim {
                        var matchL = 0, matchR = 0, n = 0
                        let step = max(1, (x1 - x0) / 32)
                        for x in stride(from: x0, to: x1, by: step) {
                            let off = (y * cw + x) * 3
                            let rL = Double(fullOutL[off]), gL = Double(fullOutL[off + 1]), bL = Double(fullOutL[off + 2])
                            let rR = Double(fullOutR[off]), gR = Double(fullOutR[off + 1]), bR = Double(fullOutR[off + 2])
                            let dL = max(abs(rL - cRGB.r), max(abs(gL - cRGB.g), abs(bL - cRGB.b)))
                            let dR = max(abs(rR - cRGB.r), max(abs(gR - cRGB.g), abs(bR - cRGB.b)))
                            if dL <= colorTol { matchL += 1 }
                            if dR <= colorTol { matchR += 1 }
                            n += 1
                        }
                        let rateL = Double(matchL) / Double(max(1, n))
                        let rateR = Double(matchR) / Double(max(1, n))
                        let hit = hasTopArch ? (min(rateL, rateR) >= reqRate) : (max(rateL, rateR) >= reqRate)
                        if hit {
                            topTrim = y + 1
                        } else if y < 4 {
                            continue
                        } else {
                            break
                        }
                    }
                    if topTrim > 0 && ch - topTrim >= 64 {
                        let dropBytes = topTrim * cw * 3
                        fullOutL = Array(fullOutL.dropFirst(dropBytes))
                        fullOutR = Array(fullOutR.dropFirst(dropBytes))
                        ch -= topTrim
                        appliedTopTrim = topTrim
                    }
                }
            }

            // トリム反映後の元カード空間上における最終プリント中心座標
            let cosSkew = cos(commonSkewAngle)
            let sinSkew = sin(commonSkewAngle)
            let uTrimShift = 0.5 * Double(trimBorderInsets.left - trimBorderInsets.right)
            let vTrimShift = 0.5 * Double(trimBorderInsets.top + appliedTopTrim - trimBorderInsets.bottom)
            let dCenterX = uTrimShift * cosSkew - vTrimShift * sinSkew
            let dCenterY = uTrimShift * sinSkew + vTrimShift * cosSkew
            let effCenterLX = centerLX + dCenterX
            let effCenterLY = centerLY + dCenterY
            let effCenterRX = centerRX + dCenterX
            let effCenterRY = centerRY + dCenterY
            let effStartLX = max(0, Int(round(effCenterLX - Double(cw) * 0.5)))
            let effStartLY = max(0, Int(round(effCenterLY - Double(ch) * 0.5)))
            let effStartRX = max(0, Int(round(effCenterRX - Double(cw) * 0.5)))
            let effStartRY = max(0, Int(round(effCenterRY - Double(ch) * 0.5)))

            // フル解像度のコーナー背景色（通常台紙または白/黒抜き背景）から上下の角丸／直角／アーチを独立確定
            let topBgRGB = Self.resolveCornerBackgroundRGB(
                leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch,
                cardRGB: effectiveCardRGB, isTop: true
            )
            let botBgRGB = Self.resolveCornerBackgroundRGB(
                leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch,
                cardRGB: effectiveCardRGB, isTop: false
            )

            // Stage 1 外周連結台紙バリアによる両肩三角領域（幅14%×高さ14%）の一致率評価
            var shoulderBarrier: Double? = nil
            if let barrier = mountAnalysis?.barrier, barrier.model.confidence >= 0.25 {
                let dw = Double(max(1, width - 1))
                let dh = Double(max(1, height - 1))
                let effLY0 = min(height - 2, effStartLY)
                let effRY0 = min(height - 2, effStartRY)
                let effLY1 = min(height - 1, effLY0 + ch)
                let effRY1 = min(height - 1, effRY0 + ch)
                let sL = barrier.shoulderBarrierRatio(
                    normX0: Double(effStartLX) / dw,
                    normX1: Double(effStartLX + cw) / dw,
                    normY0: Double(effLY0) / dh,
                    normY1: Double(effLY1) / dh
                )
                let sR = barrier.shoulderBarrierRatio(
                    normX0: Double(effStartRX) / dw,
                    normX1: Double(effStartRX + cw) / dw,
                    normY0: Double(effRY0) / dh,
                    normY1: Double(effRY1) / dh
                )
                shoulderBarrier = (sL + sR) * 0.5
            }

            let twinArch: (rx: Double, ry: Double, exp: Double)?
            if let twin = mountAnalysis?.twinWindow,
               twin.fitScore >= 0.45 {
                if twin.cutType == .arch {
                    twinArch = (rx: 0.50, ry: Double(twin.archDropRatio), exp: Double(twin.archExponent))
                } else if twin.cutType == .rounded, twin.cornerRadiusRatio >= 0.04 {
                    let r = Double(twin.cornerRadiusRatio)
                    twinArch = (rx: r, ry: r, exp: 2.0)
                } else {
                    twinArch = nil
                }
            } else {
                twinArch = nil
            }

            // 上部コーナー判定・実測（案1: 深いドームアーチまで上限クランプなしで実輪郭フィット）
            if let bgT = topBgRGB {
                let topRatios = Self.cornerCardRatiosRGB(leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch, cardRGB: bgT, isTop: true)
                let topRatioOuterAvg = (topRatios[0] + topRatios[1]) * 0.5
                let topAllAvg = topRatios.reduce(0.0, +) * 0.25
                let topSquare = topRatioOuterAvg < 0.30
                let allTopHaveBg = topRatios[0] >= 0.50 && topAllAvg >= 0.70
                let hasShoulderBarrier = (shoulderBarrier ?? 0.0) >= 0.20

                if (topSquare && !hasShoulderBarrier && twinArch == nil) || (isSquareByTwin && topSquare) {
                    archParams.topRxRatio = 0.0
                    archParams.topRyRatio = 0.0
                    archParams.topArchExp = 2.0
                } else if let measured = Self.measureOuterCornerArchShapeRGB(leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch, cardRGB: bgT, isTop: true) {
                    if measured.ryRatio <= 0.46 {
                        let needsBarrierGuard = measured.ryRatio > 0.25
                        let barrierOK: Bool
                        if let sb = shoulderBarrier {
                            barrierOK = (sb >= 0.20) || (allTopHaveBg && topRatioOuterAvg >= 0.70) || (topRatioOuterAvg >= 0.65 && topAllAvg >= 0.55)
                        } else {
                            barrierOK = (measured.ryRatio <= 0.28) || (allTopHaveBg && topRatioOuterAvg >= 0.60)
                        }
                        if !needsBarrierGuard || barrierOK {
                            archParams.topRxRatio = min(0.50, measured.rxRatio)
                            archParams.topRyRatio = min(0.45, measured.ryRatio)
                            archParams.topArchExp = max(2.0, min(3.5, measured.exp))
                            if let tw = twinArch, (shoulderBarrier == nil || shoulderBarrier! >= 0.18) {
                                if tw.ry > archParams.topRyRatio {
                                    archParams.topRyRatio = min(0.45, max(archParams.topRyRatio, tw.ry))
                                }
                                if archParams.topRyRatio >= 0.18 && archParams.topRxRatio < 0.45 && tw.rx >= 0.45 {
                                    archParams.topRxRatio = 0.50
                                    archParams.topArchExp = max(2.0, min(3.5, tw.exp))
                                }
                            }
                        } else {
                            archParams.topRxRatio = 0.0
                            archParams.topRyRatio = 0.0
                            archParams.topArchExp = 2.0
                        }
                    } else {
                        archParams.topRxRatio = 0.0
                        archParams.topRyRatio = 0.0
                        archParams.topArchExp = 2.0
                    }
                } else if let tw = twinArch, hasShoulderBarrier {
                    archParams.topRxRatio = min(0.50, tw.rx)
                    archParams.topRyRatio = min(0.45, max(0.08, tw.ry))
                    archParams.topArchExp = max(2.0, min(3.5, tw.exp))
                } else if (isSquareByTwin && !allTopHaveBg) || (!allTopHaveBg && archParams.topRyRatio < 0.24) {
                    archParams.topRxRatio = 0.0
                    archParams.topRyRatio = 0.0
                    archParams.topArchExp = 2.0
                }
            } else if let tw = twinArch, (shoulderBarrier ?? 0.0) >= 0.22 {
                archParams.topRxRatio = min(0.50, tw.rx)
                archParams.topRyRatio = min(0.45, max(0.08, tw.ry))
                archParams.topArchExp = max(2.0, min(3.5, tw.exp))
            }

            // 下部コーナー判定・実測
            let hasUpperArch = (archParams.topRxRatio >= 0.15 && archParams.topRyRatio >= 0.08)
            if let bgB = botBgRGB {
                let botRatios = Self.cornerCardRatiosRGB(leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch, cardRGB: bgB, isTop: false)
                let botOuterMin = min(botRatios[0], botRatios[1])
                let botOuterMean = (botRatios[0] + botRatios[1]) * 0.5
                let botAllMean = botRatios.reduce(0.0, +) * 0.25
                if hasUpperArch {
                    let hasSymmetricBotRound = (botOuterMin >= 0.40 && botOuterMean >= 0.52 && botAllMean >= 0.45)
                    if hasSymmetricBotRound,
                       let measured = Self.measureOuterCornerArchShapeRGB(leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch, cardRGB: bgB, isTop: false),
                       measured.rxRatio >= 0.06 && measured.ryRatio >= 0.05 {
                        archParams.botRxRatio = min(0.24, measured.rxRatio)
                        archParams.botRyRatio = min(0.18, measured.ryRatio)
                    } else {
                        archParams.botRxRatio = 0.0
                        archParams.botRyRatio = 0.0
                    }
                } else {
                    let botSquare = botOuterMean < 0.30
                    if botSquare {
                        archParams.botRxRatio = 0.0
                        archParams.botRyRatio = 0.0
                    } else if let measured = Self.measureOuterCornerArchShapeRGB(leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch, cardRGB: bgB, isTop: false) {
                        archParams.botRxRatio = min(0.24, measured.rxRatio)
                        archParams.botRyRatio = min(0.18, measured.ryRatio)
                    } else {
                        archParams.botRxRatio = 0.0
                        archParams.botRyRatio = 0.0
                    }
                }
            } else {
                archParams.botRxRatio = 0.0
                archParams.botRyRatio = 0.0
            }

            let finalTopRx = (archParams.topRxRatio < 0.03 || archParams.topRyRatio < 0.03) ? 0.0 : min(0.50, archParams.topRxRatio)
            let finalTopRy = (archParams.topRxRatio < 0.03 || archParams.topRyRatio < 0.03) ? 0.0 : min(0.45, archParams.topRyRatio)
            let finalBotRx = (archParams.botRxRatio < 0.04 || archParams.botRyRatio < 0.04) ? 0.0 : min(0.24, archParams.botRxRatio)
            let finalBotRy = (archParams.botRxRatio < 0.04 || archParams.botRyRatio < 0.04) ? 0.0 : min(0.18, archParams.botRyRatio)
            let finalTopExp = max(2.0, min(3.5, archParams.topArchExp))
            archParams = ArchShapeParams(
                topRxRatio: finalTopRx,
                topRyRatio: finalTopRy,
                botRxRatio: finalBotRx,
                botRyRatio: finalBotRy,
                topArchExp: finalTopExp
            )

            // Step 1（案1・幾何学的実輪郭正則化 ＋ ワープ前 GPU 4 ステップ仕上げ）:
            // 実測アーチパラメータに基づき元カード空間 (width × height) 上に滑らかな実輪郭確率マップを生成し、
            // ワープ前の元カード画像 segRGB のエッジに対して MPSImageGuidedFilter -> CIMorphologyMinimum -> CIGaussianBlur を適用後、
            // 写真 RGB と完全同一の切り出し座標・回転角でアルファマスクを切り出す。
            let geomProbL = Self.buildCardSpaceGeometricProbMask(
                cardWidth: width, cardHeight: height,
                centerX: effCenterLX, centerY: effCenterLY,
                boxWidth: cw, boxHeight: ch,
                angleRad: commonSkewAngle,
                archParams: archParams
            )
            let geomProbR = Self.buildCardSpaceGeometricProbMask(
                cardWidth: width, cardHeight: height,
                centerX: effCenterRX, centerY: effCenterRY,
                boxWidth: cw, boxHeight: ch,
                angleRad: commonSkewAngle,
                archParams: archParams
            )
            var fullAlphaL: [UInt8] = []
            var fullAlphaR: [UInt8] = []
            DispatchQueue.concurrentPerform(iterations: 2) { side in
                if side == 0 {
                    fullAlphaL = StereoCardMaskRefiner.shared.refineMask(
                        probMask: geomProbL, maskWidth: width, maskHeight: height,
                        guideRGB: segRGB, width: width, height: height
                    )
                } else {
                    fullAlphaR = StereoCardMaskRefiner.shared.refineMask(
                        probMask: geomProbR, maskWidth: width, maskHeight: height,
                        guideRGB: segRGB, width: width, height: height
                    )
                }
            }
            let outAlphaL = Self.cropRotatedMask8(
                fullAlphaL, srcW: width, srcH: height,
                centerX: effCenterLX, centerY: effCenterLY,
                width: cw, height: ch, angleRad: commonSkewAngle
            )
            let outAlphaR = Self.cropRotatedMask8(
                fullAlphaR, srcW: width, srcH: height,
                centerX: effCenterRX, centerY: effCenterRY,
                width: cw, height: ch, angleRad: commonSkewAngle
            )

            // 案1（実輪郭尊重）＋ 安全エッジパディング：
            // 広範囲ぼかし塗りつぶしは一切行わず、マスク外側 5px だけを写真境界色でパディングして Lanczos-3 の台紙滲みを防ぐ。
            let totalOutPx = max(1, cw * ch)
            let activeL = outAlphaL.reduce(0) { $0 + ($1 >= 128 ? 1 : 0) }
            let activeR = outAlphaR.reduce(0) { $0 + ($1 >= 128 ? 1 : 0) }
            let hasValidAlphaMasks = (Double(activeL) / Double(totalOutPx) >= 0.35) && (Double(activeR) / Double(totalOutPx) >= 0.35)

            if hasValidAlphaMasks {
                Self.extendBoundaryColorsOutsideMask(rgb: &fullOutL, alpha: outAlphaL, width: cw, height: ch, radius: 5)
                Self.extendBoundaryColorsOutsideMask(rgb: &fullOutR, alpha: outAlphaR, width: cw, height: ch, radius: 5)
            }

            let sampledU8: (r: UInt8, g: UInt8, b: UInt8)
            if let c = effectiveCardRGB {
                sampledU8 = (
                    UInt8(max(0, min(255, Int(c.r.rounded())))),
                    UInt8(max(0, min(255, Int(c.g.rounded())))),
                    UInt8(max(0, min(255, Int(c.b.rounded()))))
                )
            } else {
                let lumaU8 = UInt8(max(0, min(255, Int((cardLuma ?? 195.0).rounded()))))
                sampledU8 = (lumaU8, lumaU8, lumaU8)
            }

            let finalUnmaskedAlphaL = hasValidAlphaMasks ? outAlphaL : [UInt8](repeating: 255, count: cw * ch)
            let finalUnmaskedAlphaR = hasValidAlphaMasks ? outAlphaR : [UInt8](repeating: 255, count: cw * ch)

            let mountCtx = OriginalCardMountContext(
                cardRGB: rgb,
                cardWidth: width,
                cardHeight: height,
                leftBox: (x0: effStartLX, y0: effStartLY, x1: effStartLX + cw, y1: effStartLY + ch),
                rightBox: (x0: effStartRX, y0: effStartRY, x1: effStartRX + cw, y1: effStartRY + ch),
                maskL: finalMaskL,
                maskR: finalMaskR,
                maskWidth: mw,
                maskHeight: mh,
                skewAngleRad: commonSkewAngle,
                sampledCardRGB: sampledU8,
                archParams: archParams,
                unmaskedLeftRGB: fullOutL,
                unmaskedRightRGB: fullOutR,
                unmaskedAlphaL: finalUnmaskedAlphaL,
                unmaskedAlphaR: finalUnmaskedAlphaR,
                unmaskedWidth: cw,
                unmaskedHeight: ch
            )
            lock.lock()
            latestArchParams = archParams
            latestMountContext = mountCtx
            latestFullCardAlphaL = fullAlphaL
            latestFullCardAlphaR = fullAlphaR
            lock.unlock()

            if mode == .keepArchBlack {
                if hasValidAlphaMasks {
                    Self.applyAlphaMaskBlack(&fullOutL, alpha: outAlphaL, width: cw, height: ch)
                    Self.applyAlphaMaskBlack(&fullOutR, alpha: outAlphaR, width: cw, height: ch)
                } else {
                    Self.applyParametricArchMask(&fullOutL, width: cw, height: ch, params: archParams, extraInsetRatio: 0.004)
                    Self.applyParametricArchMask(&fullOutR, width: cw, height: ch, params: archParams, extraInsetRatio: 0.004)
                }

                return StereoCardCropper.CropResult(leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch, detectedCard: true, preservedArch: true)
            } else {
                return StereoCardCropper.CropResult(leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch, detectedCard: true, preservedArch: false)
            }
    }

    // MARK: - SAM 2.1 Tiny Refinement

    private struct RefinedMasks {
        let maskL: [Bool]
        let maskR: [Bool]
        let probL: [Float]
        let probR: [Float]
        let w: Int
        let h: Int
    }

    private struct SAMCandidateResult {
        let mask: [Bool]
        let softProb: [Float]
        let box: IntBox
        let area: Int
        let iou: Double
        let composite: Double
    }

    func containsNonFinite(_ arr: MLMultiArray) -> Bool {
        let totalCount = arr.count
        guard totalCount > 0 else { return false }
        if arr.dataType == .float16 {
            let ptr = arr.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<totalCount {
                if !ptr[i].isFinite { return true }
            }
        } else if arr.dataType == .float32 {
            let ptr = arr.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<totalCount {
                if !ptr[i].isFinite { return true }
            }
        }
        return false
    }

    private enum SAMPromptMode {
        case symmetricPointsOnly
        case pointsAndBox
    }

    private func refineWithSAM21Tiny(
        cgImage: CGImage,
        rgb: [UInt8],
        cardRGB: (r: Double, g: Double, b: Double)?,
        barrier: MountBarrierMap? = nil,
        srcW: Int,
        srcH: Int,
        boxL: IntBox,
        boxR: IntBox,
        refMaskL: [Bool],
        refMaskR: [Bool],
        probPhoto: [Float],
        splitX: Int,
        refW: Int,
        refH: Int,
        v3SeedHints: SegV3SAMSeedHints? = nil
    ) -> RefinedMasks? {
        guard let initialEncoder = loadModel(name: "SAM2_1TinyImageEncoderFLOAT16", cache: &cachedSam2Encoder),
              let initialPromptEnc = loadModel(name: "SAM2_1TinyPromptEncoderFLOAT16", cache: &cachedSam2Prompt),
              let initialDecoder = loadModel(name: "SAM2_1TinyMaskDecoderFLOAT16", cache: &cachedSam2Decoder) else {
            return nil
        }

        let scale = Double(samSize) / Double(max(srcW, srcH))
        let resizedW = max(1, Int((Double(srcW) * scale).rounded()))
        let resizedH = max(1, Int((Double(srcH) * scale).rounded()))
        let validW = max(1, Int((Double(resizedW) / 4.0).rounded()))
        let validH = max(1, Int((Double(resizedH) / 4.0).rounded()))
        let splitXValid = max(1, min(validW - 2, Int((Double(splitX) / Double(max(1, refW)) * Double(validW)).rounded())))

        do {
            var samPixelBuffer: CVPixelBuffer?
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                samSize,
                samSize,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &samPixelBuffer
            )
            guard status == kCVReturnSuccess, let samPB = samPixelBuffer else {
                return nil
            }
            CVPixelBufferLockBaseAddress(samPB, [])
            if let pxData = CVPixelBufferGetBaseAddress(samPB) {
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let bpr = CVPixelBufferGetBytesPerRow(samPB)
                if let ctx = CGContext(
                    data: pxData,
                    width: samSize,
                    height: samSize,
                    bitsPerComponent: 8,
                    bytesPerRow: bpr,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
                ) {
                    ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
                    ctx.fill(CGRect(x: 0, y: 0, width: samSize, height: samSize))
                    ctx.interpolationQuality = .medium
                    ctx.draw(cgImage, in: CGRect(x: 0, y: samSize - resizedH, width: resizedW, height: resizedH))
                }
            }
            CVPixelBufferUnlockBaseAddress(samPB, [])

            let imgFeature = MLFeatureValue(pixelBuffer: samPB)
            var encOut = try initialEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": imgFeature]))
            guard var imgEmb = encOut.featureValue(for: "image_embedding")?.multiArrayValue,
                  var featsS0 = encOut.featureValue(for: "feats_s0")?.multiArrayValue,
                  var featsS1 = encOut.featureValue(for: "feats_s1")?.multiArrayValue else {
                return nil
            }

            var useCPUAndGPUAll = false
            if containsNonFinite(imgEmb) || containsNonFinite(featsS0) || containsNonFinite(featsS1) {
                NSLog("[SAM2] Non-finite values detected in ImageEncoder output; retrying on .cpuAndGPU")
                if let cpuEnc = cachedSam2EncoderCPU ?? loadModel(name: "SAM2_1TinyImageEncoderFLOAT16", cache: &cachedSam2EncoderCPU, computeUnitsOverride: .cpuAndGPU),
                   let retryEnc = try? cpuEnc.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": imgFeature])),
                   let rEmb = retryEnc.featureValue(for: "image_embedding")?.multiArrayValue,
                   let rS0 = retryEnc.featureValue(for: "feats_s0")?.multiArrayValue,
                   let rS1 = retryEnc.featureValue(for: "feats_s1")?.multiArrayValue,
                   !containsNonFinite(rEmb), !containsNonFinite(rS0), !containsNonFinite(rS1) {
                    encOut = retryEnc
                    imgEmb = rEmb
                    featsS0 = rS0
                    featsS1 = rS1
                    useCPUAndGPUAll = true
                } else {
                    return nil
                }
            }

            storeInteractiveEmbeddingCache(
                cardRGB: rgb,
                cardWidth: srcW,
                cardHeight: srcH,
                resizedW: resizedW,
                resizedH: resizedH,
                validW: validW,
                validH: validH,
                imageEmbedding: imgEmb,
                featsS0: featsS0,
                featsS1: featsS1,
                usedCPUAndGPU: useCPUAndGPUAll
            )

            func toSAMX(_ rx: Double) -> Float {
                Float(max(0.0, min(Double(samSize - 1), rx / Double(refW) * Double(resizedW))))
            }
            func toSAMY(_ ry: Double) -> Float {
                Float(max(0.0, min(Double(samSize - 1), ry / Double(refH) * Double(resizedH))))
            }

            // Step A: ステレオ対称 2パス正負ポイントプロンプト + 緩い Box（PromptEncoder は末尾 +1 パディングするため N ∈ [2, 14] を厳守）
            func buildPromptPoints(
                box: IntBox,
                otherBox: IntBox,
                refMask: [Bool],
                isLeft: Bool,
                mode: SAMPromptMode
            ) -> [(x: Float, y: Float, label: Float)] {
                var pts: [(x: Float, y: Float, label: Float)] = []
                pts.reserveCapacity(14)

                let cx = (box.minX + box.maxX) / 2
                let cy = (box.minY + box.maxY) / 2
                let bh = max(1, box.maxY - box.minY + 1)

                func isConnectedBarrier(_ rx: Int, _ ry: Int) -> Bool {
                    guard let barrier, barrier.model.confidence >= 0.25 else { return false }
                    let nx = Double(rx) / Double(max(1, refW - 1))
                    let ny = Double(ry) / Double(max(1, refH - 1))
                    return barrier.isConnectedBarrierAt(normX: nx, normY: ny)
                }

                func isSafePositive(_ rx: Int, _ ry: Int) -> Bool {
                    guard rx >= 1, rx < refW - 1, ry >= 1, ry < refH - 1 else { return false }
                    if refMask[ry * refW + rx] {
                        var cnt = 0
                        for dy in -1...1 {
                            for dx in -1...1 where refMask[(ry + dy) * refW + (rx + dx)] {
                                cnt += 1
                            }
                        }
                        if cnt >= 5 { return true }
                    }
                    // U-Net が明るい空・天井を過剰カットした場合でも、外周連結バリア外かつ十分内側の写真帯域であれば正点として許可
                    let nx = Double(rx) / Double(max(1, refW - 1))
                    let ny = Double(ry) / Double(max(1, refH - 1))
                    guard nx >= 0.06 && nx <= 0.94 && ny >= 0.08 && ny <= 0.92 else { return false }
                    return !isConnectedBarrier(rx, ry)
                }

                // 1. 正プロンプト (label = 1.0, 上下3点分散)
                // 上端点が U-Net に削られていても拾えるよう、外周バリア外かつ安全帯域の上部にも分散配置
                var topPosY = box.minY + max(2, Int(Double(bh) * 0.22))
                if mode == .symmetricPointsOnly {
                    let yFloor = max(2, Int(Double(refH) * 0.14))
                    var yProbe = topPosY
                    while yProbe > yFloor && !isConnectedBarrier(cx, yProbe - 1) {
                        yProbe -= 1
                    }
                    topPosY = min(topPosY, max(yFloor, yProbe + Int(Double(refH) * 0.04)))
                }
                var posCandidates: [(Int, Int)] = []
                if let hints = v3SeedHints {
                    let hPt = isLeft ? hints.posPointL : hints.posPointR
                    posCandidates.append((hPt.x, hPt.y))
                }
                posCandidates.append((cx, cy))
                posCandidates.append((cx, topPosY))
                posCandidates.append((cx, box.minY + Int(Double(bh) * 0.72)))
                var seenPosY: [Int] = []
                for (px, py) in posCandidates where !seenPosY.contains(py) && isSafePositive(px, py) {
                    seenPosY.append(py)
                    pts.append((toSAMX(Double(px)), toSAMY(Double(py)), 1.0))
                    if seenPosY.count >= 3 { break }
                }
                if seenPosY.isEmpty {
                    let fallbackPt = v3SeedHints.map { isLeft ? $0.posPointL : $0.posPointR } ?? (cx, cy)
                    pts.append((toSAMX(Double(fallbackPt.0)), toSAMY(Double(fallbackPt.1)), 1.0))
                }

                // 2. 負プロンプト (label = 0.0):
                // (a) 対向側プリント中央（必須・密着カードでの左右癒着を抑止）
                let otherCx = (otherBox.minX + otherBox.maxX) / 2
                let otherCy = (otherBox.minY + otherBox.maxY) / 2
                pts.append((toSAMX(Double(otherCx)), toSAMY(Double(otherCy)), 0.0))

                // (b) カード四隅 + 上下中央谷間（v3 SeedHints がある場合は全面写真ガード済みの確実背景点のみを使用）
                if let hints = v3SeedHints {
                    for np in hints.bgNegPoints {
                        pts.append((toSAMX(Double(np.x)), toSAMY(Double(np.y)), 0.0))
                    }
                } else {
                    let cornerAndValleyCoords: [(nx: Double, ny: Double)] = [
                        (0.02, 0.02), (0.98, 0.02), (0.02, 0.98), (0.98, 0.98),
                        (Double(splitX) / Double(max(1, refW)), 0.06),
                        (Double(splitX) / Double(max(1, refW)), 0.96),
                    ]
                    for pt in cornerAndValleyCoords {
                        let rx = max(0, min(refW - 1, Int((pt.nx * Double(refW - 1)).rounded())))
                        let ry = max(0, min(refH - 1, Int((pt.ny * Double(refH - 1)).rounded())))
                        let isBgProb = probPhoto[ry * refW + rx] < 0.45
                        if isBgProb || isConnectedBarrier(rx, ry) {
                            pts.append((toSAMX(Double(rx)), toSAMY(Double(ry)), 0.0))
                        }
                    }
                }

                // (c) 対象プリント外周の確信度高い台紙帯への補助負点（残り枠内）
                func appendNegIfBg(_ rx: Int, _ ry: Int, threshold: Float = 0.15, verifyBackgroundRGB: Bool = true) {
                    guard rx >= 0, rx < refW, ry >= 0, ry < refH,
                          probPhoto[ry * refW + rx] < threshold else { return }
                    if let barrier, barrier.model.confidence >= 0.25 {
                        guard isConnectedBarrier(rx, ry) else { return }
                    }
                    if verifyBackgroundRGB, let cRGB = cardRGB, rgb.count >= srcW * srcH * 3 {
                        let sx = min(srcW - 1, max(0, rx * srcW / refW))
                        let sy = min(srcH - 1, max(0, ry * srcH / refH))
                        let idx = (sy * srcW + sx) * 3
                        let r = Double(rgb[idx]), g = Double(rgb[idx + 1]), b = Double(rgb[idx + 2])
                        let luma = (r + g + b) / 3.0
                        let cLuma = (cRGB.r + cRGB.g + cRGB.b) / 3.0
                        let isCardLike = max(abs(r - cRGB.r), max(abs(g - cRGB.g), abs(b - cRGB.b))) <= 42.0
                        let isScanLike = (luma >= 218.0 || luma <= 35.0)
                        let isBlackFrameOnBright = (cLuma >= 115.0 && luma <= 85.0)
                        guard isCardLike || isScanLike || isBlackFrameOnBright else { return }
                    }
                    pts.append((toSAMX(Double(rx)), toSAMY(Double(ry)), 0.0))
                }

                let padY = max(3, Int(Double(refH) * 0.035))
                appendNegIfBg(cx, box.minY - padY, verifyBackgroundRGB: true)
                appendNegIfBg(cx, box.maxY + padY, verifyBackgroundRGB: true)

                let maxPointBudget = (mode == .pointsAndBox) ? 12 : 14
                if pts.count > maxPointBudget {
                    pts = Array(pts.prefix(maxPointBudget))
                }

                if mode == .pointsAndBox {
                    // Box 上端は U-Net の上空削りを引きずらないよう、外周バリア手前まで最大 6% 上方に余裕を持たせる
                    let looseMinY: Int = {
                        let target = max(0, box.minY - max(2, Int(Double(refH) * 0.06)))
                        var yCur = box.minY
                        while yCur > target && !isConnectedBarrier(cx, yCur - 1) {
                            yCur -= 1
                        }
                        return yCur
                    }()
                    pts.append((toSAMX(Double(box.minX)), toSAMY(Double(looseMinY)), 2.0))
                    pts.append((toSAMX(Double(box.maxX + 1)), toSAMY(Double(box.maxY + 1)), 3.0))
                }
                return pts
            }

            func decodeWithPrompts(
                pts: [(x: Float, y: Float, label: Float)],
                box: IntBox,
                refMask: [Bool],
                isLeft: Bool
            ) -> SAMCandidateResult? {
                let pointCount = min(14, max(2, pts.count))
                guard let ptsArr = try? MLMultiArray(shape: [1, NSNumber(value: pointCount), 2], dataType: .float16),
                      let lblArr = try? MLMultiArray(shape: [1, NSNumber(value: pointCount)], dataType: .float16) else {
                    return nil
                }

                for i in 0..<pointCount {
                    ptsArr[[0, NSNumber(value: i), 0] as [NSNumber]] = NSNumber(value: pts[i].x)
                    ptsArr[[0, NSNumber(value: i), 1] as [NSNumber]] = NSNumber(value: pts[i].y)
                    lblArr[[0, NSNumber(value: i)] as [NSNumber]] = NSNumber(value: pts[i].label)
                }

                func runPromptAndDecode(
                    pEnc: MLModel,
                    mDec: MLModel,
                    eOutEmb: MLMultiArray,
                    eOutS0: MLMultiArray,
                    eOutS1: MLMultiArray
                ) -> (masks: MLMultiArray, scores: MLMultiArray?)? {
                    guard let pProvider = try? MLDictionaryFeatureProvider(dictionary: [
                        "points": MLFeatureValue(multiArray: ptsArr),
                        "labels": MLFeatureValue(multiArray: lblArr),
                    ]),
                    let pOut = try? pEnc.prediction(from: pProvider),
                    let sparseEmb = pOut.featureValue(for: "sparse_embeddings")?.multiArrayValue,
                    let denseEmb = pOut.featureValue(for: "dense_embeddings")?.multiArrayValue,
                    let decProvider = try? MLDictionaryFeatureProvider(dictionary: [
                        "image_embedding": MLFeatureValue(multiArray: eOutEmb),
                        "sparse_embedding": MLFeatureValue(multiArray: sparseEmb),
                        "dense_embedding": MLFeatureValue(multiArray: denseEmb),
                        "feats_s0": MLFeatureValue(multiArray: eOutS0),
                        "feats_s1": MLFeatureValue(multiArray: eOutS1),
                    ]),
                    let decOut = try? mDec.prediction(from: decProvider),
                    let masks = decOut.featureValue(for: "low_res_masks")?.multiArrayValue else {
                        return nil
                    }
                    let scores = decOut.featureValue(for: "scores")?.multiArrayValue
                    return (masks, scores)
                }

                let activePromptEnc = useCPUAndGPUAll
                    ? (cachedSam2PromptCPU ?? loadModel(name: "SAM2_1TinyPromptEncoderFLOAT16", cache: &cachedSam2PromptCPU, computeUnitsOverride: .cpuAndGPU) ?? initialPromptEnc)
                    : initialPromptEnc
                let activeDecoder = initialDecoder

                guard var decoded = runPromptAndDecode(
                    pEnc: activePromptEnc,
                    mDec: activeDecoder,
                    eOutEmb: imgEmb,
                    eOutS0: featsS0,
                    eOutS1: featsS1
                ) else {
                    return nil
                }

                let maskHasNaN = containsNonFinite(decoded.masks) || (decoded.scores.map { containsNonFinite($0) } ?? false)
                if maskHasNaN {
                    NSLog("[SAM2] Non-finite values detected in MaskDecoder output; falling back to .cpuAndGPU")
                    if !useCPUAndGPUAll,
                       let cpuEnc = cachedSam2EncoderCPU ?? loadModel(name: "SAM2_1TinyImageEncoderFLOAT16", cache: &cachedSam2EncoderCPU, computeUnitsOverride: .cpuAndGPU),
                       let retryEnc = try? cpuEnc.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": imgFeature])),
                       let rEmb = retryEnc.featureValue(for: "image_embedding")?.multiArrayValue,
                       let rS0 = retryEnc.featureValue(for: "feats_s0")?.multiArrayValue,
                       let rS1 = retryEnc.featureValue(for: "feats_s1")?.multiArrayValue,
                       let cpuPrompt = cachedSam2PromptCPU ?? loadModel(name: "SAM2_1TinyPromptEncoderFLOAT16", cache: &cachedSam2PromptCPU, computeUnitsOverride: .cpuAndGPU) {
                        imgEmb = rEmb; featsS0 = rS0; featsS1 = rS1; useCPUAndGPUAll = true
                        storeInteractiveEmbeddingCache(
                            cardRGB: rgb,
                            cardWidth: srcW,
                            cardHeight: srcH,
                            resizedW: resizedW,
                            resizedH: resizedH,
                            validW: validW,
                            validH: validH,
                            imageEmbedding: imgEmb,
                            featsS0: featsS0,
                            featsS1: featsS1,
                            usedCPUAndGPU: true
                        )
                        if let retryDec = runPromptAndDecode(pEnc: cpuPrompt, mDec: activeDecoder, eOutEmb: imgEmb, eOutS0: featsS0, eOutS1: featsS1),
                           !containsNonFinite(retryDec.masks) {
                            decoded = retryDec
                        } else if let cpuOnlyDec = cachedSam2DecoderCPU ?? loadModel(name: "SAM2_1TinyMaskDecoderFLOAT16", cache: &cachedSam2DecoderCPU, computeUnitsOverride: .cpuOnly),
                                  let cpuOnlyRes = runPromptAndDecode(pEnc: cpuPrompt, mDec: cpuOnlyDec, eOutEmb: imgEmb, eOutS0: featsS0, eOutS1: featsS1),
                                  !containsNonFinite(cpuOnlyRes.masks) {
                            decoded = cpuOnlyRes
                        } else {
                            return nil
                        }
                    } else if let cpuOnlyDec = cachedSam2DecoderCPU ?? loadModel(name: "SAM2_1TinyMaskDecoderFLOAT16", cache: &cachedSam2DecoderCPU, computeUnitsOverride: .cpuOnly),
                              let cpuOnlyRes = runPromptAndDecode(pEnc: activePromptEnc, mDec: cpuOnlyDec, eOutEmb: imgEmb, eOutS0: featsS0, eOutS1: featsS1),
                              !containsNonFinite(cpuOnlyRes.masks) {
                        decoded = cpuOnlyRes
                    } else {
                        return nil
                    }
                }

                let masks = decoded.masks
                let cCount = masks.shape[1].intValue
                let sC = masks.strides[1].intValue
                let sY = masks.strides[2].intValue
                let sX = masks.strides[3].intValue
                let isFP16 = (masks.dataType == .float16)

                var candScores = [Double](repeating: 0.5, count: cCount)
                if let scoreArr = decoded.scores {
                    let sStrideK = scoreArr.strides.last?.intValue ?? 1
                    let sCount = min(cCount, scoreArr.shape.last?.intValue ?? cCount)
                    if scoreArr.dataType == .float16 {
                        let sPtr16 = scoreArr.dataPointer.assumingMemoryBound(to: Float16.self)
                        for k in 0..<sCount {
                            let val = Double(sPtr16[k * sStrideK])
                            if val.isFinite {
                                candScores[k] = min(1.0, max(0.0, val))
                            }
                        }
                    } else {
                        let sPtr32 = scoreArr.dataPointer.assumingMemoryBound(to: Float.self)
                        for k in 0..<sCount {
                            let val = Double(sPtr32[k * sStrideK])
                            if val.isFinite {
                                candScores[k] = min(1.0, max(0.0, val))
                            }
                        }
                    }
                }

                var candidates: [SAMCandidateResult] = []
                candidates.reserveCapacity(cCount)
                let totalValidArea = max(1, validW * validH)

                for k in 0..<cCount {
                    var raw = [Bool](repeating: false, count: validW * validH)
                    var rawSigmoid = [Float](repeating: 0, count: validW * validH)
                    if isFP16 {
                        let ptr16 = masks.dataPointer.assumingMemoryBound(to: Float16.self)
                        let cOff = k * sC
                        for y in 0..<validH {
                            let yOff = cOff + y * sY
                            let row = y * validW
                            for x in 0..<validW {
                                let logit = Float(ptr16[yOff + x * sX])
                                let p: Float = logit.isFinite ? (1.0 / (1.0 + expf(-max(-16.0, min(16.0, logit))))) : 0.0
                                rawSigmoid[row + x] = p
                                if p >= 0.5 { raw[row + x] = true }
                            }
                        }
                    } else {
                        let ptr32 = masks.dataPointer.assumingMemoryBound(to: Float.self)
                        let cOff = k * sC
                        for y in 0..<validH {
                            let yOff = cOff + y * sY
                            let row = y * validW
                            for x in 0..<validW {
                                let logit = ptr32[yOff + x * sX]
                                let p: Float = logit.isFinite ? (1.0 / (1.0 + expf(-max(-16.0, min(16.0, logit))))) : 0.0
                                rawSigmoid[row + x] = p
                                if p >= 0.5 { raw[row + x] = true }
                            }
                        }
                    }

                    let filled = hvConvexFill(raw, w: validW, h: validH)
                    // 境界周辺の連続確率遷移は保持し、穴埋め内部・孤立ノイズのみ補正
                    var softProb = rawSigmoid
                    for i in 0..<(validW * validH) {
                        if filled[i] && !raw[i] {
                            softProb[i] = max(softProb[i], 0.95)
                        } else if !filled[i] && raw[i] {
                            softProb[i] = 0.0
                        }
                    }

                    guard let samBox = robustBoundingBox(mask: filled, w: validW, h: validH) else { continue }
                    let area = filled.reduce(0) { $0 + ($1 ? 1 : 0) }
                    let areaRatio = Double(area) / Double(totalValidArea)
                    guard areaRatio >= 0.14 && areaRatio <= 0.49 else { continue }

                    // 中央分割線越境率チェック
                    var crossCount = 0
                    var barrierHits = 0
                    for y in samBox.minY...samBox.maxY {
                        let row = y * validW
                        let ny = Double(y) / Double(max(1, validH - 1))
                        for x in samBox.minX...samBox.maxX where filled[row + x] {
                            if (isLeft && x > splitXValid + 1) || (!isLeft && x < splitXValid - 1) {
                                crossCount += 1
                            }
                            if let barrier, barrier.model.confidence >= 0.25 {
                                let nx = Double(x) / Double(max(1, validW - 1))
                                if barrier.isConnectedBarrierAt(normX: nx, normY: ny) {
                                    barrierHits += 1
                                }
                            }
                        }
                    }
                    let crossRatio = Double(crossCount) / Double(max(1, area))
                    let barrierRatio = Double(barrierHits) / Double(max(1, area))
                    guard crossRatio <= 0.08 && barrierRatio <= 0.14 else { continue }

                    let iou = computeIoU(filled, w: validW, h: validH, refMask: refMask, refW: refW, refH: refH)
                    let boxArea = max(1, (samBox.maxX - samBox.minX + 1) * (samBox.maxY - samBox.minY + 1))
                    let fillRatio = min(1.0, Double(area) / Double(boxArea))
                    // 人物やカーテンのみを切り抜いた非凸・切り絵シルエットを棄却（印画紙枠は必ず高い充填率を持つ）
                    guard fillRatio >= 0.78 else { continue }
                    let areaPrior: Double = (areaRatio >= 0.25 && areaRatio <= 0.46)
                        ? 1.0
                        : (areaRatio < 0.25 ? max(0.0, 1.0 - (0.25 - areaRatio) * 6.0) : max(0.0, 1.0 - (areaRatio - 0.46) * 8.0))
                    let composite = iou * 0.45
                        + fillRatio * 0.22
                        + candScores[k] * 0.15
                        + areaPrior * 0.10
                        + (1.0 - min(1.0, crossRatio * 6.0)) * 0.08
                        - barrierRatio * 0.40
                    candidates.append(SAMCandidateResult(mask: filled, softProb: softProb, box: samBox, area: area, iou: iou, composite: composite))
                }
                return selectBestSAMCandidate(candidates: candidates, w: validW, h: validH, promptBox: box, refW: refW, refH: refH)
            }

            func decodeSideWithFallback(box: IntBox, otherBox: IntBox, refMask: [Bool], isLeft: Bool) -> SAMCandidateResult? {
                let ptsBox = buildPromptPoints(box: box, otherBox: otherBox, refMask: refMask, isLeft: isLeft, mode: .pointsAndBox)
                return decodeWithPrompts(pts: ptsBox, box: box, refMask: refMask, isLeft: isLeft)
            }

            func toRefMinY(_ validY: Int) -> Int {
                max(0, min(refH - 1, Int(floor(Double(validY) / Double(validH) * Double(refH)))))
            }
            func toRefMaxY(_ validY: Int) -> Int {
                max(0, min(refH - 1, Int(ceil(Double(validY + 1) / Double(validH) * Double(refH))) - 1))
            }

            // Step C: パス 1 推論 ＋ 片側失敗救済 ＋ 同一 image_embedding による高さ不整合の 2 パス自己修復
            // （手貼りカードでは L/R で垂直位置のみ 10〜25px 段差がつくため、絶対 Y 座標ではなくプリント高さの有意差でのみ補正する）
            var candL = decodeSideWithFallback(box: boxL, otherBox: boxR, refMask: refMaskL, isLeft: true)
            var candR = decodeSideWithFallback(box: boxR, otherBox: boxL, refMask: refMaskR, isLeft: false)

            if let l = candL, candR == nil {
                let sy0 = toRefMinY(l.box.minY)
                let sy1 = toRefMaxY(l.box.maxY)
                if sy1 > sy0 + 8 {
                    let syncBoxR = IntBox(minX: boxR.minX, minY: sy0, maxX: boxR.maxX, maxY: sy1)
                    candR = decodeSideWithFallback(box: syncBoxR, otherBox: boxL, refMask: refMaskR, isLeft: false)
                }
            } else if let r = candR, candL == nil {
                let sy0 = toRefMinY(r.box.minY)
                let sy1 = toRefMaxY(r.box.maxY)
                if sy1 > sy0 + 8 {
                    let syncBoxL = IntBox(minX: boxL.minX, minY: sy0, maxX: boxL.maxX, maxY: sy1)
                    candL = decodeSideWithFallback(box: syncBoxL, otherBox: boxR, refMask: refMaskL, isLeft: true)
                }
            }

            guard var resL = candL, var resR = candR else {
                return nil
            }

            let hL = resL.box.maxY - resL.box.minY + 1
            let hR = resR.box.maxY - resR.box.minY + 1
            let diffH = abs(hL - hR)
            let tolH = max(6, min(hL, hR) / 12)

            if diffH >= tolH {
                let scoreDiff = resL.composite - resR.composite
                let trustLeft: Bool
                if abs(scoreDiff) >= 0.03 {
                    trustLeft = scoreDiff > 0
                } else {
                    // スコアが同等の場合、U-Netのプロンプト高さ（expectedH）に近い方を優先する（上端が削れて小さくなった誤検出を優先しない）
                    let expectedHL = Double(boxL.maxY - boxL.minY + 1) / Double(refH) * Double(validH)
                    let expectedHR = Double(boxR.maxY - boxR.minY + 1) / Double(refH) * Double(validH)
                    let diffExpectedL = abs(Double(hL) - expectedHL)
                    let diffExpectedR = abs(Double(hR) - expectedHR)
                    if abs(diffExpectedL - diffExpectedR) >= 2.0 {
                        trustLeft = diffExpectedL < diffExpectedR
                    } else {
                        trustLeft = hL >= hR
                    }
                }
                let trust = trustLeft ? resL : resR
                let bad = trustLeft ? resR : resL
                let trustH = trust.box.maxY - trust.box.minY + 1
                let targetRefH = max(16, Int((Double(trustH) / Double(validH) * Double(refH)).rounded()))

                let badRefMinY = toRefMinY(bad.box.minY)
                let badRefMaxY = toRefMaxY(bad.box.maxY)
                let deltaTop = abs(bad.box.minY - trust.box.minY)
                let deltaBot = abs(bad.box.maxY - trust.box.maxY)

                let adjMinY: Int
                let adjMaxY: Int
                if deltaBot >= deltaTop {
                    adjMinY = badRefMinY
                    adjMaxY = min(refH - 1, adjMinY + targetRefH - 1)
                } else {
                    adjMaxY = badRefMaxY
                    adjMinY = max(0, adjMaxY - targetRefH + 1)
                }

                if adjMaxY > adjMinY + 8 {
                    if trustLeft {
                        let retryBoxR = IntBox(minX: boxR.minX, minY: adjMinY, maxX: boxR.maxX, maxY: adjMaxY)
                        if let retryR = decodeSideWithFallback(box: retryBoxR, otherBox: boxL, refMask: refMaskR, isLeft: false) {
                            let newHR = retryR.box.maxY - retryR.box.minY + 1
                            if abs(hL - newHR) < diffH {
                                resR = retryR
                            }
                        }
                    } else {
                        let retryBoxL = IntBox(minX: boxL.minX, minY: adjMinY, maxX: boxL.maxX, maxY: adjMaxY)
                        if let retryL = decodeSideWithFallback(box: retryBoxL, otherBox: boxR, refMask: refMaskL, isLeft: true) {
                            let newHL = retryL.box.maxY - retryL.box.minY + 1
                            if abs(newHL - hR) < diffH {
                                resL = retryL
                            }
                        }
                    }
                }
            }

            return RefinedMasks(
                maskL: resL.mask,
                maskR: resR.mask,
                probL: resL.softProb,
                probR: resR.softProb,
                w: validW,
                h: validH
            )
        } catch {
            return nil
        }
    }

    private func makeTopLeftPaddedCGImage(_ src: CGImage, targetSize: Int, drawW: Int, drawH: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: targetSize,
            height: targetSize,
            bitsPerComponent: 8,
            bytesPerRow: targetSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        ctx.interpolationQuality = .medium
        // CGContext は左下原点のため、y = targetSize - drawH で画像上端が (0, 0) に一致する
        ctx.draw(src, in: CGRect(x: 0, y: targetSize - drawH, width: drawW, height: drawH))
        return ctx.makeImage()
    }

    func hvConvexFill(_ raw: [Bool], w: Int, h: Int) -> [Bool] {
        // 1. 最大連結成分抽出
        let cc = largestConnectedComponent(raw, w: w, h: h)
        // 2. 軽い 3x3 Opening (Min -> Max) で外側のヒゲ除去
        var eroded = [Bool](repeating: false, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let idx = y * w + x
                if cc[idx] && cc[idx - 1] && cc[idx + 1] && cc[idx - w] && cc[idx + w] {
                    eroded[idx] = true
                }
            }
        }
        var out = eroded
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where eroded[y * w + x] {
                let idx = y * w + x
                out[idx - 1] = true; out[idx + 1] = true
                out[idx - w] = true; out[idx + w] = true
            }
        }

        // 3. 水平スキャンライン埋め
        for y in 0..<h {
            let row = y * w
            var minX = w, maxX = -1
            for x in 0..<w where out[row + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
            if maxX > minX {
                for x in minX...maxX { out[row + x] = true }
            }
        }

        // 4. 垂直スキャンライン埋め
        for x in 0..<w {
            var minY = h, maxY = -1
            for y in 0..<h where out[y * w + x] {
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
            if maxY > minY {
                for y in minY...maxY { out[y * w + x] = true }
            }
        }
        return out
    }

    /// SAM 2.1 Tiny の複数候補マスクから複合品質スコアと境界妥当性で最良候補を選別
    private func selectBestSAMCandidate(
        candidates: [SAMCandidateResult],
        w: Int,
        h: Int,
        promptBox: IntBox,
        refW: Int,
        refH: Int
    ) -> SAMCandidateResult? {
        let valid = candidates.filter {
            $0.iou >= 0.62 && isAcceptableSAMMask($0.mask, w: w, h: h, promptBox: promptBox, refW: refW, refH: refH)
        }
        guard let best = valid.max(by: { $0.composite < $1.composite }) else { return nil }
        return best
    }

    private func isAcceptableSAMMask(
        _ mask: [Bool],
        w: Int,
        h: Int,
        promptBox: IntBox,
        refW: Int,
        refH: Int
    ) -> Bool {
        guard let samBox = robustBoundingBox(mask: mask, w: w, h: h) else { return false }
        let expectedW = Double(promptBox.maxX - promptBox.minX + 1) / Double(refW) * Double(w)
        let expectedH = Double(promptBox.maxY - promptBox.minY + 1) / Double(refH) * Double(h)
        guard expectedW >= 8, expectedH >= 8 else { return false }
        let samW = Double(samBox.maxX - samBox.minX + 1)
        let samH = Double(samBox.maxY - samBox.minY + 1)
        guard samW >= expectedW * 0.78 && samW <= expectedW * 1.18
            && samH >= expectedH * 0.78 && samH <= expectedH * 1.22 else {
            return false
        }
        let area = Double(mask.reduce(0) { $0 + ($1 ? 1 : 0) })
        guard area >= (expectedW * expectedH) * 0.72 else {
            return false
        }
        let expectedCx = (Double(promptBox.minX + promptBox.maxX) * 0.5 + 0.5) / Double(refW) * Double(w)
        let expectedCy = (Double(promptBox.minY + promptBox.maxY) * 0.5 + 0.5) / Double(refH) * Double(h)
        let samCx = Double(samBox.minX + samBox.maxX) * 0.5 + 0.5
        let samCy = Double(samBox.minY + samBox.maxY) * 0.5 + 0.5
        return abs(samCx - expectedCx) <= expectedW * 0.12
            && abs(samCy - expectedCy) <= expectedH * 0.14
    }

    private func computeIoU(_ mask: [Bool], w: Int, h: Int, refMask: [Bool], refW: Int, refH: Int) -> Double {
        var inter = 0
        var union = 0
        for y in 0..<h {
            let ry = min(refH - 1, y * refH / h)
            for x in 0..<w {
                let rx = min(refW - 1, x * refW / w)
                let a = mask[y * w + x]
                let b = refMask[ry * refW + rx]
                if a && b { inter += 1 }
                if a || b { union += 1 }
            }
        }
        return union > 0 ? Double(inter) / Double(union) : 0.0
    }

    private func smoothProbFromMask(_ mask: [Bool], w: Int, h: Int) -> [Float] {
        var prob = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - 1), y1 = min(h - 1, y + 1)
            for x in 0..<w {
                let x0 = max(0, x - 1), x1 = min(w - 1, x + 1)
                var sum: Float = 0
                var cnt: Float = 0
                for yy in y0...y1 {
                    for xx in x0...x1 {
                        sum += mask[yy * w + xx] ? 1.0 : 0.0
                        cnt += 1.0
                    }
                }
                prob[y * w + x] = sum / cnt
            }
        }
        return prob
    }

    // MARK: - Helpers

    struct IntBox { var minX, minY, maxX, maxY: Int }

    /// 指定された元解像度行 y が Stage 1 外周連結台紙バリアかつ非写真の平坦台紙帯と一致するかを判定
    private static func isPureMountBarrierRow(
        rgb: [UInt8],
        width: Int,
        height: Int,
        y: Int,
        x0: Int,
        x1: Int,
        isRightSide: Bool,
        scanningFromTop: Bool,
        cardRGB: (r: Double, g: Double, b: Double)?,
        barrier: MountBarrierMap,
        minConnRatio: Double,
        minRowConnRatio: Double
    ) -> Bool {
        guard y >= 0, y < height, rgb.count >= width * height * 3 else { return false }
        let bw = x1 - x0
        let sxStart = min(width - 1, max(0, x0 + bw / 8))
        let sxEnd = min(width - 1, max(sxStart, x0 + (isRightSide ? (bw * 65) / 100 : (bw * 7) / 8)))
        guard sxEnd > sxStart + 8 else { return false }

        let ny = Double(y) / Double(max(1, height - 1))
        let yAdj = scanningFromTop ? min(height - 1, y + 2) : max(0, y - 2)
        var nonCardCnt = 0, sampleTot = 0
        var lumaSum = 0.0, lumaSq = 0.0
        for sx in stride(from: sxStart, through: sxEnd, by: max(1, (sxEnd - sxStart) / 36)) {
            let nx = Double(sx) / Double(max(1, width - 1))
            if barrier.isConnectedBarrierAt(normX: nx, normY: ny) {
                continue
            }
            let idx = (y * width + sx) * 3
            let r = Double(rgb[idx]), g = Double(rgb[idx + 1]), b = Double(rgb[idx + 2])
            let l = (r + g + b) / 3.0
            let idxR = (y * width + min(width - 1, sx + 2)) * 3
            let lR = (Double(rgb[idxR]) + Double(rgb[idxR + 1]) + Double(rgb[idxR + 2])) / 3.0
            let idxA = (yAdj * width + sx) * 3
            let lA = (Double(rgb[idxA]) + Double(rgb[idxA + 1]) + Double(rgb[idxA + 2])) / 3.0
            lumaSum += l; lumaSq += l * l
            sampleTot += 1
            if abs(l - lR) >= 12.0 || abs(l - lA) >= 12.0 {
                nonCardCnt += 1
            } else if let cRGB = cardRGB {
                let dr = abs(r - cRGB.r), dg = abs(g - cRGB.g), db = abs(b - cRGB.b)
                if max(dr, max(dg, db)) > 20.0 {
                    nonCardCnt += 1
                }
            }
        }
        if sampleTot >= 4 {
            let meanL = lumaSum / Double(sampleTot)
            let rowStd = sqrt(max(0.0, lumaSq / Double(sampleTot) - meanL * meanL))
            if rowStd >= 10.5 || Double(nonCardCnt) / Double(sampleTot) >= 0.18 {
                return false
            }
        }

        let midS = min(width - 1, max(0, x0 + bw / 4))
        let midE = min(width - 1, max(midS, x0 + (isRightSide ? (bw * 2) / 3 : (bw * 3) / 4)))
        var connCnt = 0, tot = 0
        for sx in stride(from: midS, through: midE, by: max(1, (midE - midS) / 24)) {
            tot += 1
            if barrier.isConnectedBarrierAt(normX: Double(sx) / Double(max(1, width - 1)), normY: ny) {
                connCnt += 1
            }
        }
        let connRatio = Double(connCnt) / Double(max(1, tot))
        let nx0 = CGFloat(midS) / CGFloat(max(1, width - 1))
        let nx1 = CGFloat(midE) / CGFloat(max(1, width - 1))
        let rowBarrier = barrier.isMountBarrierRow(
            normalizedY: CGFloat(ny),
            normalizedXRange: min(nx0, nx1)...max(nx0, nx1),
            threshold: 0.45
        )
        return connRatio >= minConnRatio || (rowBarrier && connRatio >= minRowConnRatio)
    }

    /// マスク座標のボックスをフル解像度に変換して上下端を補正し、マスク座標へ戻す
    private func refineVerticalBoundsInMask(
        rgb: [UInt8], srcW: Int, srcH: Int,
        boxL: inout IntBox, boxR: inout IntBox,
        maskW: Int, maskH: Int
    ) {
        guard maskW >= 16, maskH >= 16 else { return }
        func toSrc(_ b: IntBox) -> (Int, Int, Int, Int) {
            (b.minX * srcW / maskW, (b.maxX + 1) * srcW / maskW, b.minY * srcH / maskH, (b.maxY + 1) * srcH / maskH - 1)
        }
        let (vl, vr) = refineVerticalBoundsPair(rgb: rgb, srcW: srcW, srcH: srcH, left: toSrc(boxL), right: toSrc(boxR))
        boxL.minY = max(0, vl.y0 * maskH / srcH)
        boxL.maxY = min(maskH - 1, vl.y1 * maskH / srcH)
        boxR.minY = max(0, vr.y0 * maskH / srcH)
        boxR.maxY = min(maskH - 1, vr.y1 * maskH / srcH)
    }

    /// 左右の写真窓それぞれについて上下端を補正し、左右で一致した補正のみ採用する
    /// （左右窓は同じ高さに印刷されるため、片側だけ大きく動く補正は誤検出とみなす）
    private func refineVerticalBoundsPair(
        rgb: [UInt8], srcW: Int, srcH: Int,
        left: (x0: Int, x1: Int, y0: Int, y1: Int),
        right: (x0: Int, x1: Int, y0: Int, y1: Int)
    ) -> (left: (y0: Int, y1: Int), right: (y0: Int, y1: Int)) {
        var l = refineVerticalBounds(rgb: rgb, srcW: srcW, srcH: srcH, x0: left.x0, x1: left.x1, y0Guess: left.y0, y1Guess: left.y1)
        var r = refineVerticalBounds(rgb: rgb, srcW: srcW, srcH: srcH, x0: right.x0, x1: right.x1, y0Guess: right.y0, y1Guess: right.y1)
        let tol = max(2, Int(Double(srcH) * 0.02))
        if abs(l.y0 - r.y0) > tol { l.y0 = left.y0; r.y0 = right.y0 }
        if abs(l.y1 - r.y1) > tol { l.y1 = left.y1; r.y1 = right.y1 }
        return (l, r)
    }

    /// 写真窓中央 40% 幅の行統計（平均・標準偏差）から、写真と台紙帯（均一な行の連続）の上下境界を求める。
    /// - スキャナ背景（画像端から続く均一行）は台紙と区別して除外
    /// - 縮小は最大 5%、拡張は「台紙より十分暗い領域（宇宙・夜空）」を取り戻す場合のみ許可
    private func refineVerticalBounds(
        rgb: [UInt8], srcW: Int, srcH: Int,
        x0: Int, x1: Int, y0Guess: Int, y1Guess: Int
    ) -> (y0: Int, y1: Int) {
        let H = srcH
        let y0g = min(max(0, y0Guess), H - 1)
        let y1g = min(max(0, y1Guess), H - 1)
        guard srcW >= 64, H >= 64, x1 - x0 >= 32, y1g > y0g + 32, rgb.count >= srcW * H * 3 else {
            return (y0g, y1g)
        }
        let bw = x1 - x0
        let cx0 = max(0, x0 + Int(Double(bw) * 0.30))
        let cx1 = min(srcW, x1 - Int(Double(bw) * 0.30))
        guard cx1 > cx0 + 4 else { return (y0g, y1g) }
        let step = max(1, (cx1 - cx0) / 96)

        var mean = [Double](repeating: 0, count: H)
        var std = [Double](repeating: 0, count: H)
        rgb.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for y in 0..<H {
                let row = y * srcW * 3
                var s = 0.0, sq = 0.0, n = 0.0
                var x = cx0
                while x < cx1 {
                    let i = row + x * 3
                    let v = (Double(base[i]) + Double(base[i + 1]) + Double(base[i + 2])) / 3.0
                    s += v; sq += v * v; n += 1
                    x += step
                }
                let m = s / max(1, n)
                mean[y] = m
                std[y] = sqrt(max(0, sq / max(1, n) - m * m))
            }
        }

        func median(_ a: ArraySlice<Double>) -> Double {
            let s = a.sorted()
            return s.isEmpty ? 0 : s[s.count / 2]
        }

        // 画像端から続くスキャナ背景の範囲
        func bgExtent(fromTop: Bool) -> (last: Int, ref: Double) {
            let e = fromTop ? 0 : H - 1
            let ref = mean[e]
            var last = e
            let seq: [Int] = fromTop ? Array(0..<H) : Array((0..<H).reversed())
            for y in seq {
                if abs(mean[y] - ref) < 12 && std[y] <= 12 { last = y } else { break }
            }
            return (last, ref)
        }
        func cardRef(_ lo: Int, _ hi: Int, bgRef: Double) -> Double? {
            let a = max(0, lo), b = min(H, hi)
            guard b - a >= 2 else { return nil }
            guard median(std[a..<b]) <= 10 else { return nil }
            let r = median(mean[a..<b])
            return abs(r - bgRef) >= 20 ? r : nil
        }

        let (topBg, topBgRef) = bgExtent(fromTop: true)
        let (botBg, botBgRef) = bgExtent(fromTop: false)
        let refB = cardRef(botBg - Int(Double(H) * 0.03), botBg - Int(Double(H) * 0.005), bgRef: botBgRef)
        let rawRefT = cardRef(topBg + Int(Double(H) * 0.005), topBg + Int(Double(H) * 0.02), bgRef: topBgRef)

        // 上端台紙 refT の厳格な整合性検証:
        // ステレオカード台紙は同素材のため、下端台紙 refB との整合性がある場合のみ上端台紙として認定。
        // 下端台紙がない場合や明色（空・天井の誤認防止）の場合は台紙とみなさない。
        let refT: Double?
        if let rawT = rawRefT {
            if let b = refB {
                refT = abs(rawT - b) <= 25.0 ? rawT : nil
            } else {
                lock.lock()
                let prevCard = latestCardLuma
                lock.unlock()
                if let pc = prevCard, abs(rawT - pc) <= 20.0, rawT < 175.0 {
                    refT = rawT
                } else {
                    refT = nil
                }
            }
        } else {
            refT = nil
        }

        if let r = refB ?? refT {
            lock.lock()
            latestCardLuma = r
            lock.unlock()
        }

        let k = max(3, Int(Double(H) * 0.006))
        let win = Int(Double(H) * 0.12)
        let shrink = Int(Double(H) * 0.05)
        let cy = (y0g + y1g) / 2
        var ny0 = y0g, ny1 = y1g

        if let ref = refB {
            func isCard(_ y: Int) -> Bool { std[y] <= 10 && abs(mean[y] - ref) <= 14 }
            let from = max(cy, y1g - win)
            let to = min(H - k, y1g + win)
            if to > from {
                for y in from..<to {
                    if y >= botBg { ny1 = y - 2; break }
                    if (0..<k).allSatisfy({ isCard(y + $0) }) { ny1 = y - 1; break }
                }
            }
            if ny1 < y1g - shrink { ny1 = y1g }
        }

        // 上端の台紙トリミングは、上端に真の台紙（refT）が検証・確認された場合のみ実施
        // （下端台紙 refB しかない場合に、その色で上端の空を誤トリムするのを防止）
        if let ref = refT {
            func isCard(_ y: Int) -> Bool { std[y] <= 10 && abs(mean[y] - ref) <= 14 }
            let from = min(cy, y0g + win)
            let to = max(k, y0g - win)
            if from > to {
                for y in stride(from: from, to: to, by: -1) {
                    if y <= topBg { ny0 = y + 2; break }
                    if (0..<k).allSatisfy({ isCard(y - $0) }) { ny0 = y + 1; break }
                }
            }
            if ny0 > y0g + shrink { ny0 = y0g }
            if ny0 < y0g - 2 && median(mean[ny0..<y0g]) > ref - 25 { ny0 = y0g }
        }

        guard ny1 > ny0 + 32 else { return (y0g, y1g) }
        return (ny0, ny1)
    }

    /// 上下端 4% 以内にある均一な台紙帯の水平境界線を検出してトリミング
    private func trimHorizontalCardBorders(
        rgb: [UInt8],
        srcW: Int,
        srcH: Int,
        x0: Int,
        x1: Int,
        y0: inout Int,
        y1: inout Int
    ) {
        let bw = x1 - x0
        let bh = y1 - y0
        guard bw >= 64, bh >= 64 else { return }
        let sx0 = x0 + Int(Double(bw) * 0.25)
        let sx1 = x1 - Int(Double(bw) * 0.25)
        let step = max(1, (sx1 - sx0) / 64)
        let maxScan = max(6, Int(Double(bh) * 0.028))
        let outerOffset = max(6, Int(Double(srcH) * 0.015))

        func rowStats(_ y: Int) -> (mean: Double, std: Double) {
            let cy = min(srcH - 1, max(0, y))
            let rowOff = cy * srcW * 3
            var sum = 0.0
            var sumSq = 0.0
            var n = 0
            var x = sx0
            while x < sx1 {
                let idx = rowOff + x * 3
                let luma = (Double(rgb[idx]) + Double(rgb[idx + 1]) + Double(rgb[idx + 2])) / 3.0
                sum += luma
                sumSq += luma * luma
                n += 1
                x += step
            }
            guard n > 0 else { return (0, 255) }
            let mean = sum / Double(n)
            let variance = max(0.0, sumSq / Double(n) - mean * mean)
            return (mean, sqrt(variance))
        }

        // 下端スキャン: 外側(y1+outerOffset)の台紙輝度と一致し、かつ写真本体との間に段差がある水平境界のみトリミング
        // （上端はアーチ頂点がカード外周の黒余白に近く、宇宙を誤検出しやすいため下端のみ対象）
        let cardBot = rowStats(y1 + outerOffset)
        var newY1 = y1
        for dy in 1...maxScan {
            let y = y1 - dy
            let stOuter = rowStats(y)
            let stNext = rowStats(y - 3)
            if stOuter.std <= 14.0
                && abs(stOuter.mean - cardBot.mean) <= 18.0
                && abs(stOuter.mean - stNext.mean) >= 18.0 {
                newY1 = max(y0 + 32, y - 1)
            }
        }
        y1 = newY1
    }

    /// U-Net / SAM が明るい天井や空などの写真上部を過小予測した場合に、
    /// フル解像度 RGB・左右中腹テクスチャ・Stage 1 外周連結台紙バリアから写真本体の物理上端境界まで安全に外側（上方向）へ復元する
    private static func recoverOvercroppedTopEdgeRGB(
        rgb: [UInt8],
        srcW: Int,
        srcH: Int,
        cLx0: Int, cLx1: Int, cLy0: inout Int, cLy1: Int,
        cRx0: Int, cRx1: Int, cRy0: inout Int, cRy1: Int,
        cardRGB: (r: Double, g: Double, b: Double),
        barrier: MountBarrierMap? = nil
    ) {
        guard srcW >= 64, srcH >= 64, rgb.count >= srcW * srcH * 3 else { return }
        let cLuma = (cardRGB.r + cardRGB.g + cardRGB.b) / 3.0
        let hasValidBarrier = (barrier != nil && barrier!.model.confidence >= 0.25)

        // 画像最上端 (y = 1) でスキャナ背景を判定
        let scanX0 = srcW / 4
        let scanX1 = srcW * 3 / 4
        let scanStep = max(1, (scanX1 - scanX0) / 64)
        var sr = 0.0, sg = 0.0, sb = 0.0, slSq = 0.0
        var scanCount = 0
        rgb.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            let rowOff = min(srcH - 1, 1) * srcW * 3
            var x = scanX0
            while x < scanX1 && scanCount < 64 {
                let i = rowOff + x * 3
                let r = Double(base[i]), g = Double(base[i + 1]), b = Double(base[i + 2])
                let luma = (r + g + b) / 3.0
                sr += r; sg += g; sb += b
                slSq += luma * luma
                scanCount += 1
                x += scanStep
            }
        }
        let topMeanR = scanCount > 0 ? sr / Double(scanCount) : 0.0
        let topMeanG = scanCount > 0 ? sg / Double(scanCount) : 0.0
        let topMeanB = scanCount > 0 ? sb / Double(scanCount) : 0.0
        let topLuma = (topMeanR + topMeanG + topMeanB) / 3.0
        let topStd = scanCount > 0 ? sqrt(max(0.0, slSq / Double(scanCount) - topLuma * topLuma)) : 255.0
        let hasWhiteScan = (scanCount > 0 && topStd <= 14.0 && topLuma >= 218.0)
        let hasBlackScan = (scanCount > 0 && topStd <= 14.0 && topLuma <= 35.0)

        func centerBarrierRatio(y: Int, sx0: Int, sx1: Int) -> Double {
            guard hasValidBarrier, let b = barrier, sx1 > sx0 else { return 0.0 }
            let normY = Double(min(srcH - 1, max(0, y))) / Double(max(1, srcH - 1))
            let step = max(1, (sx1 - sx0) / 24)
            var hit = 0, tot = 0
            var x = sx0
            while x < sx1 {
                let normX = Double(x) / Double(max(1, srcW - 1))
                if b.isConnectedBarrierAt(normX: normX, normY: normY) { hit += 1 }
                tot += 1
                x += step
            }
            return tot > 0 ? Double(hit) / Double(tot) : 0.0
        }

        func recoverSide(x0: Int, x1: Int, y0: Int, y1: Int) -> Int {
            let bw = x1 - x0
            let bh = y1 - y0
            guard bw >= 48, bh >= 64, y0 >= 4 else { return y0 }
            let sx0 = max(0, x0 + bw / 4)
            let sx1 = min(srcW, x1 - bw / 4)
            guard sx1 > sx0 + 4 else { return y0 }

            let wingL0 = max(0, x0 + Int(Double(bw) * 0.12))
            let wingL1 = min(srcW, x0 + Int(Double(bw) * 0.32))
            let wingR0 = max(0, x1 - Int(Double(bw) * 0.32))
            let wingR1 = min(srcW, x1 - Int(Double(bw) * 0.12))

            func analyzeBand(_ y: Int, bx0: Int, bx1: Int, skipBarrier: Bool) -> (bgRatio: Double, darkRatio: Double, distCard: Double, meanLuma: Double, std: Double, scanMatch: Bool, samples: Int) {
                guard bx1 > bx0 else { return (1.0, 0.0, 0.0, cLuma, 0.0, false, 0) }
                let cy = min(srcH - 1, max(0, y))
                let rowOff = cy * srcW * 3
                let normY = Double(cy) / Double(max(1, srcH - 1))
                let step = max(1, (bx1 - bx0) / 36)
                var rSum = 0.0, gSum = 0.0, bSum = 0.0, lSq = 0.0
                var bgCnt = 0, darkCnt = 0, n = 0
                rgb.withUnsafeBufferPointer { ptr in
                    guard let base = ptr.baseAddress else { return }
                    var x = bx0
                    while x < bx1 {
                        if skipBarrier, hasValidBarrier, let bMap = barrier,
                           bMap.isConnectedBarrierAt(normX: Double(x) / Double(max(1, srcW - 1)), normY: normY) {
                            x += step
                            continue
                        }
                        let i = rowOff + x * 3
                        let r = Double(base[i]), g = Double(base[i + 1]), b = Double(base[i + 2])
                        let luma = (r + g + b) / 3.0
                        rSum += r; gSum += g; bSum += b; lSq += luma * luma
                        if max(abs(r - cardRGB.r), max(abs(g - cardRGB.g), abs(b - cardRGB.b))) <= 26.0 {
                            bgCnt += 1
                        }
                        if luma <= 85.0 {
                            darkCnt += 1
                        }
                        n += 1
                        x += step
                    }
                }
                guard n > 0 else { return (1.0, 0.0, 0.0, cLuma, 0.0, false, 0) }
                let mr = rSum / Double(n), mg = gSum / Double(n), mb = bSum / Double(n)
                let ml = (mr + mg + mb) / 3.0
                let std = sqrt(max(0.0, lSq / Double(n) - ml * ml))
                let dist = sqrt(pow(mr - cardRGB.r, 2) + pow(mg - cardRGB.g, 2) + pow(mb - cardRGB.b, 2))
                let maxDiffTop = max(abs(mr - topMeanR), max(abs(mg - topMeanG), abs(mb - topMeanB)))
                let scanMatch = (hasWhiteScan && (ml >= 212.0 || maxDiffTop <= 28.0))
                    || (hasBlackScan && (ml <= 38.0 || maxDiffTop <= 28.0))
                return (Double(bgCnt) / Double(n), Double(darkCnt) / Double(n), dist, ml, std, scanMatch, n)
            }

            let maxExpand = min(Int(Double(bh) * 0.24), Int(Double(srcH) * 0.22))
            let limitY = max(0, y0 - maxExpand)
            let minGain = max(4, Int(Double(srcH) * 0.012))
            guard y0 - 1 >= limitY else { return y0 }

            var candY = y0
            var bgSum = 0.0
            var distSum = 0.0
            var steps = 0
            var barrierConfirmedSteps = 0
            var wingPhotoHits = 0

            for y in stride(from: y0 - 1, through: limitY, by: -1) {
                let st = analyzeBand(y, bx0: sx0, bx1: sx1, skipBarrier: false)
                if st.scanMatch { break }
                if hasWhiteScan && st.meanLuma >= max(210.0, cLuma + 22.0) { break }
                if cLuma >= 115.0 && ((st.darkRatio >= 0.45 && st.meanLuma <= 95.0) || st.darkRatio >= 0.55) { break }

                let wL = analyzeBand(y, bx0: wingL0, bx1: wingL1, skipBarrier: true)
                let wR = analyzeBand(y, bx0: wingR0, bx1: wingR1, skipBarrier: true)
                let isWingPhoto = (wL.samples >= 4 && wL.bgRatio < 0.55 && wL.std >= 11.0 && !wL.scanMatch)
                    || (wR.samples >= 4 && wR.bgRatio < 0.55 && wR.std >= 11.0 && !wR.scanMatch)
                if !isWingPhoto && st.bgRatio >= 0.72 && st.std <= 11.0 { break }

                var hitBarrier = false
                var barrierRatio = 1.0
                if hasValidBarrier, let b = barrier {
                    let normY = CGFloat(y) / CGFloat(max(1, srcH - 1))
                    let nx0 = CGFloat(sx0) / CGFloat(max(1, srcW - 1))
                    let nx1 = CGFloat(sx1) / CGFloat(max(1, srcW - 1))
                    barrierRatio = centerBarrierRatio(y: y, sx0: sx0, sx1: sx1)
                    let isRowB = b.isMountBarrierRow(normalizedY: normY, normalizedXRange: min(nx0, nx1)...max(nx0, nx1), threshold: 0.55)
                    if barrierRatio >= 0.48 || (isRowB && !isWingPhoto && barrierRatio >= 0.25) {
                        hitBarrier = true
                    }
                }
                if hitBarrier { break }

                let isColorPhoto = (st.bgRatio < 0.35 && st.distCard >= 26.0)
                let isBarrierFree = hasValidBarrier && (barrierRatio < 0.20)
                guard isColorPhoto || isWingPhoto || isBarrierFree else { break }

                candY = y
                bgSum += st.bgRatio
                distSum += st.distCard
                steps += 1
                if isBarrierFree { barrierConfirmedSteps += 1 }
                if isWingPhoto { wingPhotoHits += 1 }
            }

            guard steps >= minGain else { return y0 }
            let meanBg = bgSum / Double(steps)
            let meanDist = distSum / Double(steps)
            let barrierConfirmed = (barrierConfirmedSteps >= minGain) || (wingPhotoHits >= 3)
            if !barrierConfirmed {
                guard meanBg <= 0.15, meanDist >= 32.0 else { return y0 }
            } else {
                let maxBg = (wingPhotoHits >= 3) ? 0.88 : 0.72
                guard meanBg <= maxBg else { return y0 }
            }

            var boundaryOK = (candY <= 2)
            if !boundaryOK && candY >= 1 {
                for k in 1...min(6, candY) {
                    let checkY = candY - k
                    let st = analyzeBand(checkY, bx0: sx0, bx1: sx1, skipBarrier: false)
                    let cBar = centerBarrierRatio(y: checkY, sx0: sx0, sx1: sx1)
                    if st.bgRatio >= 0.45 || (cLuma >= 115.0 && st.darkRatio >= 0.50) || st.scanMatch || cBar >= 0.35 {
                        boundaryOK = true
                        break
                    }
                }
            }
            guard boundaryOK else { return y0 }

            let inset = max(1, Int(Double(bh) * 0.002))
            return min(y0, candY + inset)
        }

        cLy0 = recoverSide(x0: cLx0, x1: cLx1, y0: cLy0, y1: cLy1)
        cRy0 = recoverSide(x0: cRx0, x1: cRx1, y0: cRy0, y1: cRy1)

        // 片側の上端回復だけが不自然に大きく取り残された場合の同期救済
        if abs(cLy0 - cRy0) > max(18, srcH / 36) {
            let highY = min(cLy0, cRy0)
            let targetIsLeft = (cLy0 > cRy0)
            let tx0 = targetIsLeft ? cLx0 : cRx0
            let tx1 = targetIsLeft ? cLx1 : cRx1
            let sx0 = tx0 + (tx1 - tx0) / 4
            let sx1 = tx1 - (tx1 - tx0) / 4
            if sx1 > sx0 + 4 {
                let cBar = centerBarrierRatio(y: highY + 2, sx0: sx0, sx1: sx1)
                if !hasValidBarrier || cBar < 0.25 {
                    if targetIsLeft {
                        cLy0 = highY
                    } else {
                        cRy0 = highY
                    }
                }
            }
        }
    }

    /// Stage 1 外周連結台紙バリアと局所RGBから、過小予測された下端（淡色床・絨毯等）を物理プリント下端境界まで復元する
    private static func recoverOvercroppedBottomEdgeRGB(
        rgb: [UInt8],
        srcW: Int,
        srcH: Int,
        cLx0: Int, cLx1: Int, cLy0: Int, cLy1: inout Int,
        cRx0: Int, cRx1: Int, cRy0: Int, cRy1: inout Int,
        cardRGB: (r: Double, g: Double, b: Double),
        barrier: MountBarrierMap?
    ) {
        guard srcW >= 64, srcH >= 64, rgb.count >= srcW * srcH * 3,
              let bMap = barrier, bMap.model.confidence >= 0.25 else {
            return
        }
        let cLuma = (cardRGB.r + cardRGB.g + cardRGB.b) / 3.0

        // 画像最下端 (y = srcH - 2) でスキャナ背景を判定
        let scanX0 = srcW / 4
        let scanX1 = srcW * 3 / 4
        let scanStep = max(1, (scanX1 - scanX0) / 64)
        var sr = 0.0, sg = 0.0, sb = 0.0, slSq = 0.0, scanCount = 0
        rgb.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            let rowOff = max(0, srcH - 2) * srcW * 3
            var x = scanX0
            while x < scanX1 && scanCount < 64 {
                let i = rowOff + x * 3
                let r = Double(base[i]), g = Double(base[i + 1]), b = Double(base[i + 2])
                let l = (r + g + b) / 3.0
                sr += r; sg += g; sb += b; slSq += l * l; scanCount += 1
                x += scanStep
            }
        }
        let botMeanR = scanCount > 0 ? sr / Double(scanCount) : 0.0
        let botMeanG = scanCount > 0 ? sg / Double(scanCount) : 0.0
        let botMeanB = scanCount > 0 ? sb / Double(scanCount) : 0.0
        let botLuma = (botMeanR + botMeanG + botMeanB) / 3.0
        let botStd = scanCount > 0 ? sqrt(max(0.0, slSq / Double(scanCount) - botLuma * botLuma)) : 255.0
        let hasWhiteScan = (scanCount > 0 && botStd <= 14.0 && botLuma >= 218.0)
        let hasBlackScan = (scanCount > 0 && botStd <= 14.0 && botLuma <= 35.0)

        func recoverSide(x0: Int, x1: Int, y0: Int, y1: Int, isRightSide: Bool) -> Int {
            let bw = x1 - x0
            let bh = y1 - y0
            guard bw >= 48, bh >= 64, y1 < srcH - 3 else { return y1 }
            let sx0 = max(0, x0 + Int(Double(bw) * 0.15))
            // 右画像は右下赤スタンプ領域を避けるため 65% までで検査
            let sx1 = min(srcW, x0 + Int(Double(bw) * (isRightSide ? 0.65 : 0.85)))
            guard sx1 > sx0 + 8 else { return y1 }
            let step = max(1, (sx1 - sx0) / 36)

            let maxExpand = min(Int(Double(srcH) * 0.10), srcH - 2 - y1)
            guard maxExpand >= 3 else { return y1 }

            var candY1 = y1
            var steps = 0

            for y in y1..<(y1 + maxExpand) {
                let normY = Double(y) / Double(max(1, srcH - 1))
                var barHits = 0, darkHits = 0, bgHits = 0, tot = 0
                var rSum = 0.0, gSum = 0.0, bSum = 0.0, lSq = 0.0
                var x = sx0
                while x < sx1 {
                    let normX = Double(x) / Double(max(1, srcW - 1))
                    if bMap.isConnectedBarrierAt(normX: normX, normY: normY) { barHits += 1 }
                    let i = (y * srcW + x) * 3
                    let r = Double(rgb[i]), g = Double(rgb[i + 1]), b = Double(rgb[i + 2])
                    let l = (r + g + b) / 3.0
                    rSum += r; gSum += g; bSum += b; lSq += l * l
                    if max(abs(r - cardRGB.r), max(abs(g - cardRGB.g), abs(b - cardRGB.b))) <= 26.0 { bgHits += 1 }
                    if l <= 80.0 { darkHits += 1 }
                    tot += 1
                    x += step
                }
                guard tot > 0 else { break }
                let barRatio = Double(barHits) / Double(tot)
                let bgRatio = Double(bgHits) / Double(tot)
                let mr = rSum / Double(tot), mg = gSum / Double(tot), mb = bSum / Double(tot)
                let ml = (mr + mg + mb) / 3.0
                let std = sqrt(max(0.0, lSq / Double(tot) - ml * ml))
                let maxDiffBot = max(abs(mr - botMeanR), max(abs(mg - botMeanG), abs(mb - botMeanB)))
                let scanMatch = (hasWhiteScan && (ml >= 212.0 || maxDiffBot <= 28.0))
                    || (hasBlackScan && (ml <= 38.0 || maxDiffBot <= 28.0))

                if scanMatch { break }
                if bgRatio >= 0.55 || (bgRatio >= 0.35 && std <= 18.0) { break }
                if barRatio >= 0.25 { break }
                let isRowB = bMap.isMountBarrierRow(
                    normalizedY: CGFloat(normY),
                    normalizedXRange: CGFloat(sx0) / CGFloat(max(1, srcW - 1))...CGFloat(sx1) / CGFloat(max(1, srcW - 1)),
                    threshold: 0.60
                )
                if isRowB && std < 9.5 && barRatio >= 0.15 { break }
                if cLuma >= 115.0 && Double(darkHits) / Double(tot) >= 0.65 && std <= 22.0 && ml <= 65.0 { break }

                candY1 = y + 1
                steps += 1
            }

            guard steps >= 3 else { return y1 }
            // 台紙境界から1pxだけ安全に内側へ残す
            return max(y1, min(srcH, candY1 - 1))
        }

        cLy1 = recoverSide(x0: cLx0, x1: cLx1, y0: cLy0, y1: cLy1, isRightSide: false)
        cRy1 = recoverSide(x0: cRx0, x1: cRx1, y0: cRy0, y1: cRy1, isRightSide: true)
    }

    /// 写真窓の下部にある台紙帯・キャプション文字帯（London Stereoscopic... 等）や金枠・黒帯を検出し、
    /// 写真本体の水平境界線まで正確にトリミングする
    /// 写真窓の上下端にある太い黒枠（Black Frame）・台紙帯・下部キャプション文字帯を検出し、
    /// 写真本体の水平境界線まで安全かつ正確にトリミングする
    private static func trimHorizontalCardAndCaptionBorders(
        rgb: [UInt8],
        srcW: Int,
        srcH: Int,
        cLx0: Int, cLx1: Int, cLy0: inout Int, cLy1: inout Int,
        cRx0: Int, cRx1: Int, cRy0: inout Int, cRy1: inout Int,
        cardRGB: (r: Double, g: Double, b: Double)?,
        barrier: MountBarrierMap? = nil
    ) {
        guard srcW >= 64, srcH >= 64, rgb.count >= srcW * srcH * 3,
              let cRGB = cardRGB else { return }

        let cLuma = (cRGB.r + cRGB.g + cRGB.b) / 3.0
        let sxL0 = cLx0 + (cLx1 - cLx0) / 6
        let sxL1 = cLx1 - (cLx1 - cLx0) / 6
        let sxR0 = cRx0 + (cRx1 - cRx0) / 6
        let sxR1 = cRx1 - (cRx1 - cRx0) / 6
        guard sxL1 > sxL0 + 8, sxR1 > sxR0 + 8 else { return }

        struct RowMetrics {
            let bgRatio: Double
            let darkRatio: Double
            let meanLuma: Double
            let distCard: Double
            let std: Double
        }

        func analyzeRow(_ y: Int, x0: Int, x1: Int) -> RowMetrics {
            let cy = min(srcH - 1, max(0, y))
            let rowOff = cy * srcW * 3
            let step = max(1, (x1 - x0) / 64)
            var sr = 0.0, sg = 0.0, sb = 0.0, slSq = 0.0
            var bgCnt = 0, darkCnt = 0, n = 0
            rgb.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                var x = x0
                while x < x1 {
                    let i = rowOff + x * 3
                    let r = Double(base[i]), g = Double(base[i + 1]), b = Double(base[i + 2])
                    let luma = (r + g + b) / 3.0
                    sr += r; sg += g; sb += b
                    slSq += luma * luma
                    let dCard = max(abs(r - cRGB.r), max(abs(g - cRGB.g), abs(b - cRGB.b)))
                    if dCard <= 28.0 { bgCnt += 1 }
                    if luma <= 85.0 { darkCnt += 1 }
                    n += 1
                    x += step
                }
            }
            guard n > 0 else { return RowMetrics(bgRatio: 0, darkRatio: 0, meanLuma: 0, distCard: 255, std: 255) }
            let mr = sr / Double(n), mg = sg / Double(n), mb = sb / Double(n)
            let ml = (mr + mg + mb) / 3.0
            let std = sqrt(max(0.0, slSq / Double(n) - ml * ml))
            let dist = sqrt(pow(mr - cRGB.r, 2) + pow(mg - cRGB.g, 2) + pow(mb - cRGB.b, 2))
            return RowMetrics(
                bgRatio: Double(bgCnt) / Double(n),
                darkRatio: Double(darkCnt) / Double(n),
                meanLuma: ml,
                distCard: dist,
                std: std
            )
        }

        func stepDiff(_ y: Int, x0: Int, x1: Int) -> Double {
            let yP = min(srcH - 1, y + 2)
            let yM = max(0, y - 2)
            let rP = yP * srcW * 3
            let rM = yM * srcW * 3
            let step = max(1, (x1 - x0) / 64)
            var sum = 0.0, n = 0
            rgb.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                var x = x0
                while x < x1 {
                    let iP = rP + x * 3, iM = rM + x * 3
                    let dr = Double(base[iP]) - Double(base[iM])
                    let dg = Double(base[iP + 1]) - Double(base[iM + 1])
                    let db = Double(base[iP + 2]) - Double(base[iM + 2])
                    sum += sqrt(dr * dr + dg * dg + db * db)
                    n += 1
                    x += step
                }
            }
            return n > 0 ? sum / Double(n) : 0.0
        }

        // 各サイドの上端・下端それぞれを精密トリミング
        func trimSideBottom(yTop: Int, yBot: Int, sx0: Int, sx1: Int) -> Int {
            let bh = yBot - yTop
            guard bh >= 64 else { return yBot }
            let maxScan = min(Int(Double(bh) * 0.16), Int(Double(srcH) * 0.15))
            guard maxScan >= 4 else { return yBot }

            var currentY1 = yBot

            // 1. 太い水平黒枠（明色台紙の内側にある均一暗帯）を検出して除去
            // （濃灰台紙 16645-3 等の暗い空・宇宙誤切断防止のため cLuma >= 115.0 のみ対象）
            if cLuma >= 115.0 {
                let off1 = analyzeRow(min(srcH - 1, yBot + max(3, Int(Double(srcH) * 0.008))), x0: sx0, x1: sx1)
                let off2 = analyzeRow(min(srcH - 1, yBot + max(8, Int(Double(srcH) * 0.025))), x0: sx0, x1: sx1)
                if max(off1.meanLuma, off2.meanLuma) >= 115.0 || max(off1.bgRatio, off2.bgRatio) >= 0.45 {
                    let maxDarkRows = max(5, Int(Double(bh) * 0.065))
                    var y = currentY1 - 1
                    let limitY = max(yTop + 48, currentY1 - maxScan)
                    // 外周台紙帯を通過
                    while y > limitY {
                        let st = analyzeRow(y, x0: sx0, x1: sx1)
                        if st.bgRatio >= 0.48 {
                            y -= 1
                        } else {
                            break
                        }
                    }
                    // 外縁の1px抗エイリアス滲みも1行だけ許容しつつ均一黒帯に入る
                    if y > limitY {
                        let stEdge = analyzeRow(y, x0: sx0, x1: sx1)
                        let stNext = analyzeRow(y - 1, x0: sx0, x1: sx1)
                        if stEdge.darkRatio >= 0.40 && stNext.darkRatio >= 0.62 {
                            y -= 1
                        }
                    }
                    var darkRun = 0
                    var darkSumLuma = 0.0
                    while y > limitY && darkRun < maxDarkRows {
                        let st = analyzeRow(y, x0: sx0, x1: sx1)
                        if st.darkRatio >= 0.62 && st.std <= 32.0 && st.meanLuma <= 88.0 {
                            darkRun += 1
                            darkSumLuma += st.meanLuma
                            y -= 1
                        } else {
                            break
                        }
                    }
                    if darkRun >= 2 {
                        let darkMean = darkSumLuma / Double(darkRun)
                        let insideSt = analyzeRow(max(yTop + 16, y - 1), x0: sx0, x1: sx1)
                        let edge = stepDiff(y + 1, x0: sx0, x1: sx1)
                        if insideSt.darkRatio < 0.55
                            && (insideSt.meanLuma >= darkMean + 12.0 || edge >= 15.0 || insideSt.std >= 12.0) {
                            currentY1 = min(currentY1, max(yTop + 32, y + 1))
                        }
                    }
                }
            }

            // 2. 台紙帯・キャプション文字帯（行の多くが cardRGB で構成され、写真本体との間に明確な境界がある帯）を検出
            let capScanMax = min(Int(Double(bh) * 0.08), Int(Double(srcH) * 0.07))
            let capLimitY = max(yTop + 48, yBot - capScanMax)
            if currentY1 > capLimitY + 3 {
                var sumBgRatio = 0.0
                var rowCount = 0
                var photoStreak = 0
                var missBudget = 0
                var lastMarginY: Int? = nil
                var darkRuleStreak = 0

                // 外縁から内側（上）へ向かって台紙・文字行を辿る
                let hasValidBar = (barrier != nil && barrier!.model.confidence >= 0.25)
                for y in stride(from: currentY1 - 1, through: capLimitY, by: -1) {
                    let st = analyzeRow(y, x0: sx0, x1: sx1)
                    let isLikelyTextOnMount = (rowCount >= 2 && st.bgRatio >= 0.52 && st.std <= 24.0)
                    if hasValidBar, let b = barrier, !isLikelyTextOnMount {
                        let normY = Double(min(srcH - 1, max(0, y))) / Double(max(1, srcH - 1))
                        let stepB = max(1, (sx1 - sx0) / 16)
                        var barCnt = 0, bTot = 0
                        var bx = sx0
                        while bx < sx1 {
                            if b.isConnectedBarrierAt(normX: Double(bx) / Double(max(1, srcW - 1)), normY: normY) { barCnt += 1 }
                            bTot += 1
                            bx += stepB
                        }
                        if bTot > 0 && Double(barCnt) / Double(bTot) < 0.25 {
                            photoStreak += 1
                            if photoStreak >= 2 { break }
                            continue
                        }
                    }
                    // 写真内の床模様や足元（背景一致率が低く、かつ std や暗部が高い行）に入ったら探索停止
                    if st.bgRatio < 0.45 && (st.std >= 14.0 || st.darkRatio >= 0.14) {
                        photoStreak += 1
                        if photoStreak >= 2 { break }
                        continue
                    }
                    let isMarginOrTextRow = (st.bgRatio >= 0.60 && st.std <= 18.0)
                        || (st.bgRatio >= 0.48 && st.std <= 24.0 && st.darkRatio <= 0.35)
                    let isDarkRuleRow = st.darkRatio >= 0.62 && st.std <= 28.0
                    if isMarginOrTextRow {
                        sumBgRatio += st.bgRatio
                        rowCount += 1
                        photoStreak = 0
                        missBudget = 0
                        darkRuleStreak = 0
                        lastMarginY = y
                    } else if isDarkRuleRow && darkRuleStreak < 2 && rowCount >= 1 {
                        // 台紙と写真の間の細い黒罫線（最大2px）のみ許容
                        // 宇宙空間・夜空等の暗部写真への侵入を防止
                        sumBgRatio += st.bgRatio
                        rowCount += 1
                        photoStreak = 0
                        missBudget = 0
                        darkRuleStreak += 1
                        lastMarginY = y
                    } else if st.bgRatio >= 0.42 && missBudget < 1 && rowCount >= 2 {
                        // キャプション文字密度が濃い1行のみ許容
                        sumBgRatio += st.bgRatio
                        rowCount += 1
                        missBudget += 1
                        darkRuleStreak = 0
                    } else {
                        photoStreak += 1
                        if photoStreak >= 2 {
                            // 連続2行以上写真領域に突入 → 直前までが台紙/文字帯の候補
                            break
                        }
                    }
                }

                if let borderY = lastMarginY, rowCount >= 2 {
                    let overallBgMean = sumBgRatio / Double(rowCount)
                    let inside1 = analyzeRow(max(yTop + 8, borderY - 2), x0: sx0, x1: sx1)
                    let inside2 = analyzeRow(max(yTop + 8, borderY - 4), x0: sx0, x1: sx1)
                    let diff = stepDiff(borderY, x0: sx0, x1: sx1)
                    let hasBoundaryTransition =
                        inside1.bgRatio < 0.50 && inside2.bgRatio < 0.50 &&
                        (diff >= 15.0 || inside1.distCard >= 15.0 || inside1.std >= 12.0)
                    if overallBgMean >= 0.62 && hasBoundaryTransition {
                        currentY1 = min(currentY1, max(yTop + 32, borderY))
                    }
                }
            }

            // 3. 最下端 8.5% 以内の「プリント下縁水平暗線＋直下手書きキャプションインク帯」専用検出
            func rowLumaRange(_ y: Int) -> (mean: Double, std: Double, minL: Double, maxL: Double) {
                let cy = min(srcH - 1, max(0, y))
                let rowOff = cy * srcW * 3
                let step = max(1, (sx1 - sx0) / 72)
                var sum = 0.0, sq = 0.0, minL = 255.0, maxL = 0.0, n = 0
                rgb.withUnsafeBufferPointer { ptr in
                    guard let base = ptr.baseAddress else { return }
                    var x = sx0
                    while x < sx1 {
                        let i = rowOff + x * 3
                        let l = (Double(base[i]) + Double(base[i + 1]) + Double(base[i + 2])) / 3.0
                        sum += l; sq += l * l
                        if l < minL { minL = l }
                        if l > maxL { maxL = l }
                        n += 1
                        x += step
                    }
                }
                guard n > 0 else { return (0, 255, 255, 0) }
                let m = sum / Double(n)
                return (m, sqrt(max(0.0, sq / Double(n) - m * m)), minL, maxL)
            }

            let seamScan = min(Int(Double(bh) * 0.085), Int(Double(srcH) * 0.08))
            let seamStart = max(yTop + 48, currentY1 - seamScan)
            let seamEnd = max(yTop + 48, currentY1 - 2)
            if seamEnd > seamStart + 4 {
                for y in seamStart..<seamEnd {
                    let line = rowLumaRange(y)
                    let up = rowLumaRange(max(yTop + 8, y - 4))
                    guard up.mean >= line.mean + 16.0 && up.std <= 14.0 else {
                        continue
                    }
                    let lowStart = y + 2
                    let lowEnd = currentY1
                    guard lowEnd - lowStart >= 2 else { continue }
                    var lowSum = 0.0
                    var lowCnt = 0
                    var inkRows = 0
                    for ly in lowStart..<lowEnd {
                        let r = rowLumaRange(ly)
                        lowSum += r.mean
                        lowCnt += 1
                        if r.minL <= 70.0 && (r.maxL - r.minL) >= 45.0 && r.std >= 10.5 {
                            inkRows += 1
                        }
                    }
                    guard lowCnt >= 2 else { continue }
                    let lowMean = lowSum / Double(lowCnt)
                    if lowMean >= line.mean + 10.0 && inkRows >= 2 {
                        currentY1 = min(currentY1, max(yTop + 32, y - 1))
                        break
                    }
                }
            }

            return currentY1
        }

        func trimSideTop(yTop: Int, yBot: Int, sx0: Int, sx1: Int, fullX0: Int, fullX1: Int) -> Int {
            let bh = yBot - yTop
            guard bh >= 64 else { return yTop }
            let maxScan = min(Int(Double(bh) * 0.08), Int(Double(srcH) * 0.075))
            guard maxScan >= 4 else { return yTop }

            // 1. 明色台紙＋均一黒枠バンドの除去
            if cLuma >= 115.0 {
                let off1 = analyzeRow(max(0, yTop - max(3, Int(Double(srcH) * 0.008))), x0: sx0, x1: sx1)
                let off2 = analyzeRow(max(0, yTop - max(8, Int(Double(srcH) * 0.025))), x0: sx0, x1: sx1)
                if max(off1.meanLuma, off2.meanLuma) >= 115.0 || max(off1.bgRatio, off2.bgRatio) >= 0.45 {
                    var y = yTop
                    let limitY = min(yBot - 48, yTop + maxScan)
                    while y < limitY {
                        let st = analyzeRow(y, x0: sx0, x1: sx1)
                        if st.bgRatio >= 0.48 {
                            y += 1
                        } else {
                            break
                        }
                    }
                    if y < limitY {
                        let stEdge = analyzeRow(y, x0: sx0, x1: sx1)
                        let stNext = analyzeRow(y + 1, x0: sx0, x1: sx1)
                        if stEdge.darkRatio >= 0.40 && stNext.darkRatio >= 0.62 {
                            y += 1
                        }
                    }
                    let maxDarkRows = max(5, Int(Double(bh) * 0.055))
                    var darkRun = 0
                    var darkSumLuma = 0.0
                    while y < limitY && darkRun < maxDarkRows {
                        let st = analyzeRow(y, x0: sx0, x1: sx1)
                        if st.darkRatio >= 0.62 && st.std <= 32.0 && st.meanLuma <= 88.0 {
                            darkRun += 1
                            darkSumLuma += st.meanLuma
                            y += 1
                        } else {
                            break
                        }
                    }
                    if darkRun >= 2 {
                        let darkMean = darkSumLuma / Double(darkRun)
                        let insideSt = analyzeRow(min(yBot - 16, y + 1), x0: sx0, x1: sx1)
                        let edge = stepDiff(y - 1, x0: sx0, x1: sx1)
                        if insideSt.darkRatio < 0.55
                            && (insideSt.meanLuma >= darkMean + 12.0 || edge >= 15.0 || insideSt.std >= 12.0) {
                            return max(yTop, min(yBot - 32, y))
                        }
                    }
                }
            }

            // 2. 上端の均一な外周台紙帯＋明瞭なプリント境界（02_white_columns 等：空誤切断を防ぐ厳格チェック）
            let limitMarginY = min(yBot - 48, yTop + min(maxScan, Int(Double(bh) * 0.06)))
            var y = yTop
            var bgRun = 0
            while y < limitMarginY {
                let st = analyzeRow(y, x0: sx0, x1: sx1)
                if st.bgRatio >= 0.68 && st.std <= 15.0 {
                    bgRun += 1
                    y += 1
                } else {
                    break
                }
            }
            if bgRun >= 2 {
                // 境界直下の細い枠暗線（1〜3px）を通過しつつ、その内側が明確な別トーン（空と色違い・構造あり）である場合のみカット
                var ruleAdv = y
                while ruleAdv < min(limitMarginY, y + 4) {
                    let st = analyzeRow(ruleAdv, x0: sx0, x1: sx1)
                    if st.darkRatio >= 0.45 || st.meanLuma < cLuma - 18.0 {
                        ruleAdv += 1
                    } else {
                        break
                    }
                }
                if ruleAdv > y {
                    // 明確な水平境界枠線が存在したため安全にトリム
                    return max(yTop, min(yBot - 32, ruleAdv))
                }
            }

            // 3. 天頂中央40%における無地純台紙帯の除去（外縁影0..5pxを跨ぎ、純台紙帯が終わる境界までトリム）
            // 注意: 11603-7589 のように中央40%が無地の空で左右中腹にヤシの葉・背景構造がある場合は写真内部なので絶対停止する
            let fw = fullX1 - fullX0
            let cx0 = max(0, fullX0 + (fw * 3) / 10)
            let cx1 = min(srcW, fullX0 + (fw * 7) / 10)
            let wingL0 = max(0, fullX0 + fw / 10)
            let wingL1 = min(srcW, fullX0 + (fw * 3) / 10)
            let wingR0 = max(0, fullX0 + (fw * 7) / 10)
            let wingR1 = min(srcW, fullX0 + (fw * 9) / 10)
            let hasValidBarrier = (barrier != nil && barrier!.model.confidence >= 0.25)

            func hasSidePhotoTexture(y: Int) -> Bool {
                func wingHasPhoto(wx0: Int, wx1: Int) -> Bool {
                    guard wx1 > wx0 + 4 else { return false }
                    if hasValidBarrier, let b = barrier {
                        // アーチ外角上の台紙と混同しないよう、連結バリア外の画素だけで写真テクスチャを判定
                        let normY = Double(min(srcH - 1, max(0, y))) / Double(max(1, srcH - 1))
                        var nonBarrierCnt = 0
                        var nonBgOrTexCnt = 0
                        var sum = 0.0, sumSq = 0.0
                        let step = max(1, (wx1 - wx0) / 24)
                        var x = wx0
                        while x < wx1 {
                            if !b.isConnectedBarrierAt(normX: Double(x) / Double(max(1, srcW - 1)), normY: normY) {
                                let i = (y * srcW + x) * 3
                                let r = Double(rgb[i]), g = Double(rgb[i + 1]), bl = Double(rgb[i + 2])
                                let l = (r + g + bl) / 3.0
                                sum += l; sumSq += l * l
                                nonBarrierCnt += 1
                                let dCard = max(abs(r - cRGB.r), max(abs(g - cRGB.g), abs(bl - cRGB.b)))
                                if dCard >= 16.0 { nonBgOrTexCnt += 1 }
                            }
                            x += step
                        }
                        guard nonBarrierCnt >= 4 else { return false }
                        let ml = sum / Double(nonBarrierCnt)
                        let std = sqrt(max(0.0, sumSq / Double(nonBarrierCnt) - ml * ml))
                        let nonBgRatio = Double(nonBgOrTexCnt) / Double(nonBarrierCnt)
                        return std >= 10.5 || nonBgRatio >= 0.45
                    } else if y >= yTop + Int(Double(bh) * 0.06) {
                        let wst = analyzeRow(y, x0: wx0, x1: wx1)
                        return wst.std >= 10.5 || wst.bgRatio < 0.65 || wst.distCard >= 16.0
                    }
                    return false
                }
                return wingHasPhoto(wx0: wingL0, wx1: wingL1) || wingHasPhoto(wx0: wingR0, wx1: wingR1)
            }

            func isCenterConnectedBarrier(y: Int) -> Bool {
                guard hasValidBarrier, let b = barrier, cx1 > cx0 else { return true }
                let normY = Double(min(srcH - 1, max(0, y))) / Double(max(1, srcH - 1))
                let step = max(1, (cx1 - cx0) / 16)
                var hit = 0, tot = 0
                var x = cx0
                while x < cx1 {
                    if b.isConnectedBarrierAt(normX: Double(x) / Double(max(1, srcW - 1)), normY: normY) { hit += 1 }
                    tot += 1
                    x += step
                }
                return tot > 0 && Double(hit) / Double(tot) >= 0.35
            }

            if cx1 - cx0 >= 16 {
                let pureMaxScan = min(Int(Double(bh) * 0.14), Int(Double(srcH) * 0.13))
                let limitPureY = min(yBot - 48, yTop + pureMaxScan)
                let skipLimit = min(limitPureY, yTop + 6)
                var pStart = yTop
                while pStart < skipLimit {
                    if hasSidePhotoTexture(y: pStart) || !isCenterConnectedBarrier(y: pStart) {
                        pStart = skipLimit
                        break
                    }
                    let st = analyzeRow(pStart, x0: cx0, x1: cx1)
                    if st.bgRatio >= 0.85 && st.distCard <= 13.0 && st.std <= 10.0 {
                        break
                    }
                    pStart += 1
                }
                if pStart < skipLimit {
                    var pEnd = pStart
                    var pureRun = 0
                    while pEnd < limitPureY {
                        if hasSidePhotoTexture(y: pEnd) || !isCenterConnectedBarrier(y: pEnd) {
                            break
                        }
                        let st = analyzeRow(pEnd, x0: cx0, x1: cx1)
                        if st.bgRatio >= 0.85 && st.distCard <= 13.0 && st.std <= 10.0 {
                            pureRun += 1
                            pEnd += 1
                        } else {
                            break
                        }
                    }
                    if pureRun >= 6 && pEnd < limitPureY && !hasSidePhotoTexture(y: pEnd) {
                        let diff = stepDiff(pEnd, x0: cx0, x1: cx1)
                        let nextSt = analyzeRow(min(yBot - 16, pEnd + 2), x0: cx0, x1: cx1)
                        // 空の緩やかな階調変化を純台紙帯と誤認して写真を切り落とすのを防ぐため、明確なエッジや構造変化を要求
                        if diff >= 14.0 || nextSt.std >= 12.0 || nextSt.distCard >= 20.0 {
                            return max(yTop, min(yBot - 32, pEnd))
                        }
                    }
                }
            }

            return yTop
        }

        let newLy1 = trimSideBottom(yTop: cLy0, yBot: cLy1, sx0: sxL0, sx1: sxL1)
        let newRy1 = trimSideBottom(yTop: cRy0, yBot: cRy1, sx0: sxR0, sx1: sxR1)
        let newLy0 = trimSideTop(yTop: cLy0, yBot: newLy1, sx0: sxL0, sx1: sxL1, fullX0: cLx0, fullX1: cLx1)
        let newRy0 = trimSideTop(yTop: cRy0, yBot: newRy1, sx0: sxR0, sx1: sxR1, fullX0: cRx0, fullX1: cRx1)

        // ステレオ下端Y同期（もし片側だけ大きく残っていたらより清潔に切れた側の近くも確認）
        cLy1 = min(cLy1, newLy1)
        cRy1 = min(cRy1, newRy1)
        cLy0 = max(cLy0, newLy0)
        cRy0 = max(cRy0, newRy0)

        // L/R の下端差が開いている場合、長い側のはみ出し分が台紙/キャプション帯なら短い側に揃える
        let minY1 = min(cLy1, cRy1)
        let maxY1 = max(cLy1, cRy1)
        if maxY1 - minY1 >= 4 {
            let wideIsLeft = cLy1 > cRy1
            let sx0 = wideIsLeft ? sxL0 : sxR0
            let sx1 = wideIsLeft ? sxL1 : sxR1
            var sumBg = 0.0
            var cnt = 0
            for y in minY1..<maxY1 {
                let st = analyzeRow(y, x0: sx0, x1: sx1)
                sumBg += st.bgRatio
                cnt += 1
            }
            if cnt > 0 && (sumBg / Double(cnt)) >= 0.45 {
                cLy1 = minY1
                cRy1 = minY1
            }
        }
    }

    /// roughBoxL と roughBoxR の上下 Y 境界を、はみ出し側帯域の局所平坦性（台紙余白・キャプション vs 写真テクスチャ）に基づいて安全に同期する
    private func syncRoughBoundsY(
        rgb: [UInt8],
        srcW: Int,
        srcH: Int,
        boxL: inout IntBox,
        boxR: inout IntBox,
        maskW: Int,
        maskH: Int
    ) {
        let minDiff = abs(boxL.minY - boxR.minY)
        let maxDiff = abs(boxL.maxY - boxR.maxY)
        guard minDiff >= 2 || maxDiff >= 2,
              maskW >= 16, maskH >= 16, srcW >= 64, srcH >= 64, rgb.count >= srcW * srcH * 3 else {
            let syncMinY = min(boxL.minY, boxR.minY)
            let syncMaxY = max(boxL.maxY, boxR.maxY)
            boxL = IntBox(minX: boxL.minX, minY: syncMinY, maxX: boxL.maxX, maxY: syncMaxY)
            boxR = IntBox(minX: boxR.minX, minY: syncMinY, maxX: boxR.maxX, maxY: syncMaxY)
            return
        }

        // 指定したマスクY範囲の領域が「台紙余白・少数の文字のみ（局所平坦率が高い均一帯）」かどうかを判定
        func isLikelyMarginBand(box: IntBox, yStartMask: Int, yEndMask: Int) -> Bool {
            guard yEndMask > yStartMask else { return false }
            let bx0 = Double(box.minX) * Double(srcW) / Double(maskW)
            let bx1 = Double(box.maxX + 1) * Double(srcW) / Double(maskW)
            let bw = bx1 - bx0
            guard bw >= 24 else { return false }
            let sx0 = max(2, Int(bx0 + bw * 0.20))
            let sx1 = min(srcW - 3, Int(bx1 - bw * 0.20))
            guard sx1 > sx0 + 8 else { return false }

            let sy0 = max(0, yStartMask * srcH / maskH)
            let sy1 = min(srcH, yEndMask * srcH / maskH)
            guard sy1 > sy0 else { return false }

            let stepX = max(2, (sx1 - sx0) / 48)
            let stepY = max(1, (sy1 - sy0) / 8)
            var totalFlatRatio = 0.0
            var rows = 0

            rgb.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                var y = sy0
                while y < sy1 {
                    let row = y * srcW * 3
                    var flat = 0
                    var cnt = 0
                    var x = sx0 + 2
                    while x < sx1 - 2 {
                        let iC = row + x * 3
                        let iP = row + (x - 2) * 3
                        let iN = row + (x + 2) * 3
                        let lC = (Double(base[iC]) + Double(base[iC + 1]) + Double(base[iC + 2])) / 3.0
                        let lP = (Double(base[iP]) + Double(base[iP + 1]) + Double(base[iP + 2])) / 3.0
                        let lN = (Double(base[iN]) + Double(base[iN + 1]) + Double(base[iN + 2])) / 3.0
                        if abs(lC - lP) <= 6.0 && abs(lC - lN) <= 6.0 {
                            flat += 1
                        }
                        cnt += 1
                        x += stepX
                    }
                    if cnt > 0 {
                        totalFlatRatio += Double(flat) / Double(cnt)
                        rows += 1
                    }
                    y += stepY
                }
            }
            guard rows > 0 else { return false }
            return (totalFlatRatio / Double(rows)) >= 0.65
        }

        let topLow = min(boxL.minY, boxR.minY)
        let topHigh = max(boxL.minY, boxR.minY)
        let finalMinY: Int
        if minDiff >= 2 {
            let widerTopBox = (boxL.minY < boxR.minY) ? boxL : boxR
            finalMinY = isLikelyMarginBand(box: widerTopBox, yStartMask: topLow, yEndMask: topHigh) ? topHigh : topLow
        } else {
            finalMinY = topLow
        }

        let botLow = min(boxL.maxY, boxR.maxY)
        let botHigh = max(boxL.maxY, boxR.maxY)
        let finalMaxY: Int
        if maxDiff >= 2 {
            let widerBotBox = (boxL.maxY > boxR.maxY) ? boxL : boxR
            finalMaxY = isLikelyMarginBand(box: widerBotBox, yStartMask: botLow + 1, yEndMask: botHigh + 1) ? botLow : botHigh
        } else {
            finalMaxY = botHigh
        }

        guard finalMaxY > finalMinY + 8 else { return }
        boxL = IntBox(minX: boxL.minX, minY: finalMinY, maxX: boxL.maxX, maxY: finalMaxY)
        boxR = IntBox(minX: boxR.minX, minY: finalMinY, maxX: boxR.maxX, maxY: finalMaxY)
    }

    /// 外周ラベル枠（P. Rossier / Keystone 等）と写真本体の間にある強い垂直境界線を検出してトリミング
    private func trimOuterLabelBorders(
        rgb: [UInt8],
        srcW: Int,
        srcH: Int,
        boxL: inout IntBox,
        boxR: inout IntBox,
        maskW: Int,
        maskH: Int
    ) {
        guard maskW >= 64, maskH >= 32, srcW >= 64, srcH >= 32 else { return }
        let y0 = Int(Double(maskH) * 0.18)
        let y1 = max(y0 + 4, Int(Double(maskH) * 0.82))
        let rowCount = Double(y1 - y0)

        // maskW x maskH グリッドでのグレースケール輝度と水平勾配 grad[x] = mean(|I(y, x+1) - I(y, x-1)|)
        var gray = [Float](repeating: 0, count: maskW * maskH)
        rgb.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for y in y0..<y1 {
                let sy = min(srcH - 1, y * srcH / maskH)
                let srcRow = sy * srcW * 3
                let dstRow = y * maskW
                for x in 0..<maskW {
                    let sx = min(srcW - 1, x * srcW / maskW)
                    let idx = srcRow + sx * 3
                    gray[dstRow + x] = (Float(base[idx]) + Float(base[idx + 1]) + Float(base[idx + 2])) / 3.0
                }
            }
        }

        var grad = [Float](repeating: 0, count: maskW)
        for x in 1..<(maskW - 1) {
            var sum: Float = 0
            for y in y0..<y1 {
                let row = y * maskW
                sum += abs(gray[row + x + 1] - gray[row + x - 1])
            }
            grad[x] = sum / Float(rowCount)
        }

        // 外側帯が真に均一な台紙・ラベル紙帯であり、内側写真領域と明瞭な輝度・色差を持つか検証するガード
        func isTrueOuterLabelStrip(outerMaskX0: Int, outerMaskX1: Int, innerMaskX0: Int, innerMaskX1: Int) -> Bool {
            let ox0 = max(1, outerMaskX0 * srcW / maskW)
            let ox1 = min(srcW - 1, outerMaskX1 * srcW / maskW)
            let ix0 = max(1, innerMaskX0 * srcW / maskW)
            let ix1 = min(srcW - 1, innerMaskX1 * srcW / maskW)
            guard ox1 > ox0 + 2, ix1 > ix0 + 4 else { return false }
            let sy0 = max(0, srcH / 5)
            let sy1 = min(srcH, (srcH * 4) / 5)
            let stepY = max(1, (sy1 - sy0) / 48)

            func stripStats(_ x0: Int, _ x1: Int) -> (meanR: Double, meanG: Double, meanB: Double, meanL: Double, flatRatio: Double) {
                var sr = 0.0, sg = 0.0, sb = 0.0, n = 0
                var flat = 0
                let stepX = max(1, (x1 - x0) / 8)
                rgb.withUnsafeBufferPointer { ptr in
                    guard let base = ptr.baseAddress else { return }
                    var y = sy0
                    while y < sy1 {
                        let row = y * srcW * 3
                        var x = x0
                        while x < x1 {
                            let i = row + x * 3
                            let r = Double(base[i]), g = Double(base[i + 1]), b = Double(base[i + 2])
                            sr += r; sg += g; sb += b; n += 1
                            let xl = max(0, x - 1), xr = min(srcW - 1, x + 1)
                            let il = row + xl * 3, ir = row + xr * 3
                            let ll = (Double(base[il]) + Double(base[il + 1]) + Double(base[il + 2])) / 3.0
                            let lr = (Double(base[ir]) + Double(base[ir + 1]) + Double(base[ir + 2])) / 3.0
                            if abs(lr - ll) <= 8.0 { flat += 1 }
                            x += stepX
                        }
                        y += stepY
                    }
                }
                guard n > 0 else { return (0, 0, 0, 0, 0) }
                let mr = sr / Double(n), mg = sg / Double(n), mb = sb / Double(n)
                return (mr, mg, mb, (mr + mg + mb) / 3.0, Double(flat) / Double(n))
            }

            let outer = stripStats(ox0, ox1)
            let inner = stripStats(ix0, ix1)
            guard outer.flatRatio >= 0.45 else { return false }
            let lumaDiff = abs(outer.meanL - inner.meanL)
            let colorDiff = hypot(hypot(outer.meanR - inner.meanR, outer.meanG - inner.meanG), outer.meanB - inner.meanB)
            return lumaDiff >= 18.0 || colorDiff >= 22.0
        }

        // 左ボックスの外端トリミング
        let bwL = boxL.maxX - boxL.minX
        if bwL >= 32 {
            let i0 = max(1, boxL.minX + Int(Double(bwL) * 0.25))
            let i1 = min(maskW - 2, boxL.maxX - Int(Double(bwL) * 0.15))
            if i1 > i0 + 4 {
                let sortedL = grad[i0...i1].sorted()
                let baseL = sortedL[sortedL.count / 2]
                let thL = max(42.0, baseL * 4.2)
                let searchEnd = min(maskW - 2, boxL.minX + Int(Double(bwL) * 0.09))
                let searchStart = max(1, boxL.minX + 3)
                if searchEnd >= searchStart {
                    var newMinX = boxL.minX
                    for x in searchStart...searchEnd where grad[x] >= thL {
                        newMinX = x + 1
                    }
                    if newMinX > boxL.minX && boxL.maxX - newMinX >= 32,
                       isTrueOuterLabelStrip(
                           outerMaskX0: boxL.minX, outerMaskX1: newMinX - 1,
                           innerMaskX0: newMinX + 1, innerMaskX1: min(boxL.maxX, newMinX + max(4, bwL / 10))
                       ) {
                        boxL.minX = newMinX
                    }
                }
            }
        }

        // 右ボックスの外端トリミング
        let bwR = boxR.maxX - boxR.minX
        if bwR >= 32 {
            let i0 = max(1, boxR.minX + Int(Double(bwR) * 0.15))
            let i1 = min(maskW - 2, boxR.maxX - Int(Double(bwR) * 0.25))
            if i1 > i0 + 4 {
                let sortedR = grad[i0...i1].sorted()
                let baseR = sortedR[sortedR.count / 2]
                let thR = max(42.0, baseR * 4.2)
                let searchStart = max(1, boxR.maxX - Int(Double(bwR) * 0.09))
                let searchEnd = min(maskW - 2, boxR.maxX - 3)
                if searchEnd >= searchStart {
                    var newMaxX = boxR.maxX
                    for x in (searchStart...searchEnd).reversed() where grad[x] >= thR {
                        newMaxX = x - 1
                    }
                    if newMaxX < boxR.maxX && newMaxX - boxR.minX >= 32,
                       isTrueOuterLabelStrip(
                           outerMaskX0: newMaxX + 1, outerMaskX1: boxR.maxX,
                           innerMaskX0: max(boxR.minX, newMaxX - max(4, bwR / 10)), innerMaskX1: newMaxX - 1
                       ) {
                        boxR.maxX = newMaxX
                    }
                }
            }
        }
    }

    /// 突出した数pxの波打ち（台紙残り）を無視して直線エッジを捉えるロバスト外接矩形
    func robustBoundingBox(mask: [Bool], w: Int, h: Int) -> IntBox? {
        var rowCounts = [Int](repeating: 0, count: h)
        var colCounts = [Int](repeating: 0, count: w)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where mask[row + x] {
                rowCounts[y] += 1
                colCounts[x] += 1
            }
        }
        guard let maxRow = rowCounts.max(), let maxCol = colCounts.max(),
              maxRow > 8, maxCol > 8 else {
            return boundingBox(mask: mask, w: w, h: h)
        }
        let rowThresh = max(2, Int(Double(maxRow) * 0.05))
        let colThresh = max(2, Int(Double(maxCol) * 0.05))

        var minY = h, maxY = -1
        for y in 0..<h where rowCounts[y] >= rowThresh {
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
        var minX = w, maxX = -1
        for x in 0..<w where colCounts[x] >= colThresh {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
        }
        guard maxX > minX + 8, maxY > minY + 8 else {
            return boundingBox(mask: mask, w: w, h: h)
        }
        return IntBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// 左右マスクの四隅の欠け面積から、上部アーチ・下部角丸の幾何曲率パラメータを推定
    private func estimateArchParams(
        maskL: [Bool], boxL: IntBox,
        maskR: [Bool], boxR: IntBox,
        w: Int, h: Int
    ) -> ArchShapeParams {
        func measureCorners(mask: [Bool], box: IntBox) -> (tl: Double, tr: Double, bl: Double, br: Double) {
            let bw = max(16, box.maxX - box.minX + 1)
            let bh = max(16, box.maxY - box.minY + 1)
            let cwTop = max(4, Int(Double(bw) * 0.50))
            let chTop = max(4, Int(Double(bh) * 0.45))
            let cwBot = max(4, Int(Double(bw) * 0.28))
            let chBot = max(4, Int(Double(bh) * 0.28))

            var missTL = 0, missTR = 0
            for dy in 0..<chTop {
                let y = box.minY + dy
                for dx in 0..<cwTop {
                    if !mask[y * w + (box.minX + dx)] { missTL += 1 }
                    if !mask[y * w + (box.maxX - dx)] { missTR += 1 }
                }
            }

            var missBL = 0, missBR = 0
            for dy in 0..<chBot {
                let y = box.maxY - dy
                for dx in 0..<cwBot {
                    if !mask[y * w + (box.minX + dx)] { missBL += 1 }
                    if !mask[y * w + (box.maxX - dx)] { missBR += 1 }
                }
            }

            // 楕円四分円の外側面積 A = (1 - pi/4) * rx * ry ≈ 0.2146 * r^2 * bw * bh
            let s = max(1.0, 0.2146018 * Double(bw * bh))
            return (
                sqrt(max(0.0, Double(missTL) / s)),
                sqrt(max(0.0, Double(missTR) / s)),
                sqrt(max(0.0, Double(missBL) / s)),
                sqrt(max(0.0, Double(missBR) / s))
            )
        }

        let cL = measureCorners(mask: maskL, box: boxL)
        let cR = measureCorners(mask: maskR, box: boxR)
        // 外側ペア（Lの左上/左下 ＋ Rの右上/右下）は中央谷間の番号印字等の影響を受けにくい
        let leftPair = (cL.tl + cR.tl) * 0.5
        let rightPair = (cL.tr + cR.tr) * 0.5
        let rTop = max(min(leftPair, rightPair), min(cL.tl, cR.tr))
        let leftBotPair = (cL.bl + cR.bl) * 0.5
        let rightBotPair = (cL.br + cR.br) * 0.5
        let rBot = max(min(leftBotPair, rightBotPair), min(cL.bl, cR.br))

        let hasTop = rTop >= 0.045
        // 上部アーチ（Arch-top）が存在する場合、ステレオカード本来の仕様に基づき下部は直角（ただしコーナー実測側で両角丸も判定）
        let hasBot = !hasTop && (rBot >= 0.045)
        let topRx: Double
        let topRy: Double
        if hasTop {
            // 案1: 深いドームアーチ (rx≈0.50, ry≈0.20〜0.45) まで浅クランプなしで実測推定を解放
            topRx = min(0.50, max(0.10, rTop * 1.15))
            topRy = min(0.45, max(0.08, rTop * 0.90))
        } else {
            topRx = 0.0
            topRy = 0.0
        }
        return ArchShapeParams(
            topRxRatio: topRx,
            topRyRatio: topRy,
            botRxRatio: hasBot ? min(0.18, rBot * 1.02) : 0.0,
            botRyRatio: hasBot ? min(0.18, rBot * 1.02) : 0.0,
            topArchExp: 2.0
        )
    }

    /// フル解像度の外側コーナー（L外側 & R外側：中央谷間の数字印字の影響を受けない隅）から
    /// 上部または下部の楕円角丸パラメータ (rxRatio, ryRatio) を L1 楕円フィッティングで直接計測する
    private static func measureOuterCornerArchShapeRGB(
        leftRGB: [UInt8],
        rightRGB: [UInt8],
        width w: Int,
        height h: Int,
        cardRGB: (r: Double, g: Double, b: Double),
        isTop: Bool = true
    ) -> (rxRatio: Double, ryRatio: Double, exp: Double)? {
        guard w >= 64, h >= 64, leftRGB.count >= w * h * 3, rightRGB.count >= w * h * 3 else { return nil }
        if isCornersSquareRGB(leftRGB: leftRGB, rightRGB: rightRGB, width: w, height: h, cardRGB: cardRGB, isTop: isTop) {
            return nil
        }

        let maxScanX = min(w / 2, Int(Double(w) * 0.52))
        let maxScanY = min(h / 2, Int(Double(h) * 0.48))
        guard maxScanX >= 12, maxScanY >= 12 else { return nil }

        // 外側 2 隅先端の局所背景色を抽出（照明ムラ・黄変・白抜きの差を吸収）
        let ix = max(2, Int(Double(w) * 0.006))
        let iy = max(2, Int(Double(h) * 0.006))
        let cwSample = max(3, Int(Double(w) * 0.020))
        let chSample = max(3, Int(Double(h) * 0.020))
        let y0c = isTop ? min(h - chSample, iy) : max(0, h - iy - chSample)
        let xR0c = max(0, w - ix - cwSample)
        var nearR: [Double] = []
        var nearG: [Double] = []
        var nearB: [Double] = []
        func collectNear(_ rgb: [UInt8], xStart: Int) {
            for y in y0c..<(y0c + chSample) {
                let row = y * w * 3
                for x in xStart..<(xStart + cwSample) {
                    let i = row + x * 3
                    let r = Double(rgb[i]), g = Double(rgb[i + 1]), b = Double(rgb[i + 2])
                    if max(abs(r - cardRGB.r), max(abs(g - cardRGB.g), abs(b - cardRGB.b))) <= 26.0 {
                        nearR.append(r); nearG.append(g); nearB.append(b)
                    }
                }
            }
        }
        collectNear(leftRGB, xStart: ix)
        collectNear(rightRGB, xStart: xR0c)
        let localBg: (r: Double, g: Double, b: Double)
        if nearR.count >= 8 {
            nearR.sort(); nearG.sort(); nearB.sort()
            let mid = nearR.count / 2
            localBg = (nearR[mid], nearG[mid], nearB[mid])
        } else {
            localBg = cardRGB
        }

        // 上部アーチ曲線上の Sobel エッジ勾配吸着に用いる局所勾配マップ（上部 maxScanY 範囲のみ事前計算）
        let gradH = isTop ? min(h, maxScanY + 4) : 0
        func computeTopGrad(_ rgb: [UInt8]) -> [Double] {
            guard isTop, gradH >= 4, w >= 16 else { return [] }
            var luma = [Double](repeating: 0.0, count: w * gradH)
            for i in 0..<(w * gradH) {
                let p = i * 3
                luma[i] = (Double(rgb[p]) + Double(rgb[p + 1]) + Double(rgb[p + 2])) / 3.0
            }
            var grad = [Double](repeating: 0.0, count: w * gradH)
            for y in 1..<(gradH - 1) {
                let r0 = (y - 1) * w, r1 = y * w, r2 = (y + 1) * w
                for x in 1..<(w - 1) {
                    let gx = (-luma[r0 + x - 1] + luma[r0 + x + 1]) + 2.0 * (-luma[r1 + x - 1] + luma[r1 + x + 1]) + (-luma[r2 + x - 1] + luma[r2 + x + 1])
                    let gy = (-luma[r0 + x - 1] - 2.0 * luma[r0 + x] - luma[r0 + x + 1]) + (luma[r2 + x - 1] + 2.0 * luma[r2 + x] + luma[r2 + x + 1])
                    grad[r1 + x] = min(1.0, hypot(gx, gy) / 255.0)
                }
            }
            return grad
        }
        let topGradL = computeTopGrad(leftRGB)
        let topGradR = computeTopGrad(rightRGB)

        func tryMeasure(refCol: (r: Double, g: Double, b: Double), tol: Double) -> (rxRatio: Double, ryRatio: Double, exp: Double)? {
            func isBg(_ rgb: [UInt8], _ x: Int, _ y: Int) -> Bool {
                let idx = (y * w + x) * 3
                let dr = abs(Double(rgb[idx]) - refCol.r)
                let dg = abs(Double(rgb[idx + 1]) - refCol.g)
                let db = abs(Double(rgb[idx + 2]) - refCol.b)
                return max(dr, max(dg, db)) <= tol
            }

            func columnDrop(_ rgb: [UInt8], x: Int) -> Int {
                guard maxScanY > 4 else { return 0 }
                // 台紙から非台紙（写真）へ遷移する位置をピクセル精度で検出
                // 局所シミ・ゴミを回避するため、非台紙ピクセルが3点連続する最初の位置を採用
                for dy in 0..<(maxScanY - 3) {
                    let y = isTop ? dy : (h - 1 - dy)
                    if !isBg(rgb, x, y) {
                        let y1 = isTop ? (dy + 1) : (h - 1 - (dy + 1))
                        let y2 = isTop ? (dy + 2) : (h - 1 - (dy + 2))
                        if !isBg(rgb, x, y1) && !isBg(rgb, x, y2) {
                            return dy
                        }
                    }
                }
                return maxScanY - 3
            }

            // 中央辺縁（x ∈ [0.35w ..< 0.65w]）のドロップ量を計測：上辺全体に台紙色の空がある場合を排除
            let centerStart = Int(Double(w) * 0.35)
            let centerEnd = Int(Double(w) * 0.65)
            var centerDropSum = 0.0
            let centerSamples = 7
            for i in 0..<centerSamples {
                let cx = min(w - 1, max(0, centerStart + (centerEnd - centerStart) * i / max(1, centerSamples - 1)))
                centerDropSum += Double(columnDrop(leftRGB, x: cx))
                centerDropSum += Double(columnDrop(rightRGB, x: cx))
            }
            let dropCenterRatio = (centerDropSum / Double(centerSamples * 2)) / Double(h)
            guard dropCenterRatio <= 0.12 else { return nil }

            // L 外側・R 外側の隅先端に十分な背景色が存在することを確認（片側欠けでの誤爆防止）
            var cornerHitsL = 0
            var cornerHitsR = 0
            let endY = min(10, maxScanY)
            let endX = min(10, maxScanX)
            if endY > 2 && endX > 2 {
                for dy in 2..<endY {
                    let y = isTop ? dy : (h - 1 - dy)
                    for dx in 2..<endX {
                        if isBg(leftRGB, dx, y) { cornerHitsL += 1 }
                        if isBg(rightRGB, w - 1 - dx, y) { cornerHitsR += 1 }
                    }
                }
            }
            guard cornerHitsL >= 6, cornerHitsR >= 6 else { return nil }

            var profile: [(fx: Double, fy: Double)] = []
            let stepX = max(1, maxScanX / 44)
            var dx = 2
            var flatRun = 0
            let symMinThreshold = max(4, Int(Double(h) * 0.02))
            while dx < maxScanX {
                let dL = columnDrop(leftRGB, x: dx)
                let dR = columnDrop(rightRGB, x: w - 1 - dx)
                let drop: Double
                let hi = Double(max(dL, dR))
                let lo = Double(min(dL, dR))
                if lo >= Double(symMinThreshold) || (dx <= stepX * 2 && lo >= 4.0) {
                    if hi > lo * 1.6 + Double(h) * 0.04 {
                        drop = lo
                    } else {
                        drop = (hi + lo) * 0.5
                    }
                } else if hi >= Double(symMinThreshold) && isTop {
                    // 片側に台紙ドロップが残っている場合、片側の暗部・汚れによる0急落を防ぐため重み付き平均
                    drop = (hi + lo * 2.0) / 3.0
                } else {
                    drop = lo
                }
                let fy = drop / Double(h)
                profile.append((Double(dx) / Double(w), fy))
                if !isTop && fy < 0.005 {
                    flatRun += 1
                    if flatRun >= 3 && profile.count >= 5 { break }
                } else {
                    flatRun = 0
                }
                dx += stepX
            }

            guard !profile.isEmpty else { return nil }
            // 単発の台紙ゴミ・シミによる 1 列急落（0 スパイク等）が curMax を永久ラッチするのを防ぐ 3 点メジアン平滑
            let smoothed: [(fx: Double, fy: Double)]
            if profile.count >= 3 {
                var tmp = profile
                for i in 1..<(profile.count - 1) {
                    let a = profile[i - 1].fy
                    let b = profile[i].fy
                    let c = profile[i + 1].fy
                    let med = max(min(a, b), min(max(a, b), c))
                    tmp[i] = (profile[i].fx, med)
                }
                smoothed = tmp
            } else {
                smoothed = profile
            }
            var mono: [(fx: Double, fy: Double)] = []
            mono.reserveCapacity(smoothed.count)
            var curMax = smoothed[0].fy
            for i in 0..<smoothed.count {
                let pt = smoothed[i]
                let clamped = (pt.fy > curMax + 0.02) ? curMax : pt.fy
                // 1〜2点連続の局所ディップ（シミ・境界ノイズ）で curMax が永久ラッチするのを防ぐ後方3点窓
                var winMax = pt.fy
                let winEnd = min(smoothed.count, i + 3)
                if i + 1 < winEnd {
                    for j in (i + 1)..<winEnd {
                        if smoothed[j].fy > winMax { winMax = smoothed[j].fy }
                    }
                }
                curMax = min(curMax, winMax)
                mono.append((pt.fx, clamped))
            }

            guard let maxFy = mono.prefix(3).map(\.fy).max(),
                  maxFy >= 0.035,
                  maxFy - dropCenterRatio >= 0.025 else {
                return nil
            }

            // モデルA: フラット天井＋左右2隅角丸の直接 L1 非対称楕円フィッティング
            var bestLoss = Double.greatestFiniteMagnitude
            var bestRx = 0.0
            var bestRy = 0.0
            var bestExp = 2.0
            for ixStep in 6...38 {
                let rx = Double(ixStep) * 0.01
                for iyStep in 6...34 {
                    let ry = Double(iyStep) * 0.01
                    guard rx >= ry * 0.60 && rx <= ry * 2.80 else { continue }
                    var loss = 0.0
                    for pt in mono {
                        let pred: Double
                        if pt.fx < rx {
                            let u = min(1.0, max(0.0, (rx - pt.fx) / rx))
                            pred = ry * (1.0 - sqrt(max(0.0, 1.0 - u * u)))
                        } else {
                            pred = 0.0
                        }
                        let diff = pred - pt.fy
                        loss += (diff < 0.0) ? (-2.6 * diff) : diff
                    }
                    if loss < bestLoss {
                        bestLoss = loss
                        bestRx = rx
                        bestRy = ry
                        bestExp = 2.0
                    }
                }
            }

            // モデルB（上部のみ）: 全幅深いドームアーチ（rx=0.50, ry=0.12...0.45, q=2.0...2.4）の L1 フィット比較
            if isTop {
                for iyStep in 12...45 {
                    let ry = Double(iyStep) * 0.01
                    for q in [2.0, 2.2, 2.4] {
                        var loss = 0.0
                        for pt in mono {
                            let u = min(1.0, max(0.0, (0.50 - pt.fx) / 0.50))
                            let pred = ry * (1.0 - sqrt(max(0.0, 1.0 - pow(u, q))))
                            let diff = pred - pt.fy
                            loss += (diff < 0.0) ? (-2.6 * diff) : diff
                        }
                        if loss < bestLoss {
                            bestLoss = loss
                            bestRx = 0.50
                            bestRy = ry
                            bestExp = q
                        }
                    }
                }
            }

            guard bestRx > 0.0 && bestRy > 0.0 else { return nil }
            let finalRx = min(0.50, bestRx)
            let finalRy = min(isTop ? 0.45 : 0.24, bestRy)
            return (finalRx, finalRy, bestExp)
        }

        // 色差ベース実測が色同系・斑点等で失敗／浅く止まった場合の上部専用「領域平坦性＋Sobel勾配」2変数直接アーチフィット
        func fitArchByEdgeAndRegion() -> (rxRatio: Double, ryRatio: Double, exp: Double)? {
            guard isTop, !topGradL.isEmpty, !topGradR.isEmpty, gradH >= 8 else { return nil }
            func medianCornerRGB(_ rgb: [UInt8], isLeftCorner: Bool) -> (r: Double, g: Double, b: Double)? {
                let xEnd = min(16, w / 16)
                let yEnd = min(16, h / 16)
                guard xEnd > 2, yEnd > 2 else { return nil }
                var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
                let cap = (xEnd - 2) * (yEnd - 2)
                rs.reserveCapacity(cap); gs.reserveCapacity(cap); bs.reserveCapacity(cap)
                for dy in 2..<yEnd {
                    let row = dy * w * 3
                    for dx in 2..<xEnd {
                        let x = isLeftCorner ? dx : (w - 1 - dx)
                        let i = row + x * 3
                        rs.append(Double(rgb[i]))
                        gs.append(Double(rgb[i + 1]))
                        bs.append(Double(rgb[i + 2]))
                    }
                }
                guard !rs.isEmpty else { return nil }
                rs.sort(); gs.sort(); bs.sort()
                let mid = rs.count / 2
                return (rs[mid], gs[mid], bs[mid])
            }
            guard let bgL = medianCornerRGB(leftRGB, isLeftCorner: true),
                  let bgR = medianCornerRGB(rightRGB, isLeftCorner: false) else { return nil }

            @inline(__always)
            func calcPBg(_ rgb: [UInt8], _ gradMap: [Double], _ x: Int, _ y: Int, _ bg: (r: Double, g: Double, b: Double)) -> Double {
                let idx = y * w + x
                let off = idx * 3
                let dist = max(abs(Double(rgb[off]) - bg.r), max(abs(Double(rgb[off + 1]) - bg.g), abs(Double(rgb[off + 2]) - bg.b)))
                let g = gradMap[idx]
                let pColor = 1.0 / (1.0 + exp((dist - 24.0) / 5.5))
                let texGate = (g <= 0.25) ? 1.0 : max(0.25, 1.0 - (g - 0.25) * 1.5)
                return pColor * texGate
            }

            let step = max(2, min(w, h) / 140)
            var ys: [Int] = []
            var yy = 1
            while yy < gradH - 1 { ys.append(yy); yy += step }
            guard ys.count >= 4 else { return nil }

            // アーチ頂点直下（中央帯 y ∈ 5%..15%）が均一な無地背景一色である場合（空・天井等）はアーチ誤検出を防ぐ
            let cyStart = max(1, Int(Double(h) * 0.05))
            let cyEnd = min(gradH - 1, max(cyStart + 1, Int(Double(h) * 0.15)))
            var centerBgSum = 0.0
            var centerBgCnt = 0
            for cy in stride(from: cyStart, to: cyEnd, by: step) {
                for cx in stride(from: Int(Double(w) * 0.35), to: w / 2, by: step) {
                    centerBgSum += calcPBg(leftRGB, topGradL, cx, cy, bgL)
                    centerBgSum += calcPBg(rightRGB, topGradR, w - 1 - cx, cy, bgR)
                    centerBgCnt += 2
                }
            }
            if centerBgCnt > 0 && (centerBgSum / Double(centerBgCnt)) >= 0.55 {
                return nil
            }

            struct ColCache {
                let fx: Double
                let xL: Int
                let xR: Int
                let pBgL: [Double]
                let pBgR: [Double]
            }
            var cols: [ColCache] = []
            var xx = 2
            while xx < w / 2 {
                let xR = w - 1 - xx
                var pL = [Double](); pL.reserveCapacity(ys.count)
                var pR = [Double](); pR.reserveCapacity(ys.count)
                for y in ys {
                    pL.append(calcPBg(leftRGB, topGradL, xx, y, bgL))
                    pR.append(calcPBg(rightRGB, topGradR, xR, y, bgR))
                }
                cols.append(ColCache(fx: Double(xx) / Double(w), xL: xx, xR: xR, pBgL: pL, pBgR: pR))
                xx += step
            }
            guard !cols.isEmpty else { return nil }

            func evalArchCost(ry: Double, q: Double) -> Double {
                var errSum = 0.0
                var cnt = 0
                var edgeSum = 0.0
                var edgeCnt = 0
                for col in cols {
                    let u = min(1.0, max(0.0, (0.50 - col.fx) / 0.50))
                    let yCurve = (ry > 0.0) ? (ry * Double(h) * (1.0 - sqrt(max(0.0, 1.0 - pow(u, q))))) : 0.0
                    for rIdx in 0..<ys.count {
                        let py = Double(ys[rIdx])
                        let pL = col.pBgL[rIdx]
                        let pR = col.pBgR[rIdx]
                        if py < yCurve {
                            errSum += (1.0 - pL) + (1.0 - pR)
                        } else {
                            errSum += 1.75 * pL + 1.75 * pR
                        }
                        cnt += 2
                    }
                    if ry > 0.0 {
                        let cy = Int(yCurve.rounded())
                        let yOut = max(0, min(gradH - 1, cy - 4))
                        let yIn = max(0, min(gradH - 1, cy + 4))
                        let pOutL = calcPBg(leftRGB, topGradL, col.xL, yOut, bgL)
                        let pOutR = calcPBg(rightRGB, topGradR, col.xR, yOut, bgR)
                        let pInL = calcPBg(leftRGB, topGradL, col.xL, yIn, bgL)
                        let pInR = calcPBg(rightRGB, topGradR, col.xR, yIn, bgR)
                        let dirContrastL = max(0.0, pOutL - pInL)
                        let dirContrastR = max(0.0, pOutR - pInR)
                        var maxGL = 0.0
                        var maxGR = 0.0
                        for dy in -2...2 {
                            let gy = max(0, min(gradH - 1, cy + dy))
                            let rowOff = gy * w
                            maxGL = max(maxGL, topGradL[rowOff + col.xL])
                            maxGR = max(maxGR, topGradR[rowOff + col.xR])
                        }
                        let bL = maxGL * (0.4 + 0.6 * dirContrastL)
                        let bR = maxGR * (0.4 + 0.6 * dirContrastR)
                        edgeSum += (bL + bR) * 0.5
                        edgeCnt += 1
                    }
                }
                let regionErr = errSum / Double(max(1, cnt))
                let edgeScore = (ry > 0.0 && edgeCnt > 0) ? (edgeSum / Double(edgeCnt)) : 0.0
                return regionErr - 0.14 * edgeScore
            }

            let squareCost = evalArchCost(ry: 0.0, q: 2.0)
            var bestCost = squareCost
            var bestRy = 0.0
            var bestQ = 2.0
            for q in [2.0, 2.2] {
                for ry in stride(from: 0.10, through: 0.45, by: 0.01) {
                    let cost = evalArchCost(ry: ry, q: q)
                    if cost < bestCost {
                        bestCost = cost
                        bestRy = ry
                        bestQ = q
                    }
                }
            }
            guard bestCost < squareCost - 0.020, bestRy >= 0.10 else { return nil }
            let outRx = (bestRy >= 0.18) ? 0.50 : 0.26
            return (outRx, min(0.45, bestRy), bestQ)
        }

        var colorRes: (rxRatio: Double, ryRatio: Double, exp: Double)? = nil
        for (ref, tol) in [(cardRGB, 24.0), (localBg, 18.0), (localBg, 14.0)] {
            if let res = tryMeasure(refCol: ref, tol: tol) {
                colorRes = res
                break
            }
        }
        if isTop {
            if let cRes = colorRes {
                return cRes
            } else {
                return fitArchByEdgeAndRegion()
            }
        }
        return colorRes
    }

    /// 上隅または下隅に残った元カードの台紙画素および境界縁線を、境界沿いの平坦な写真背景色（被写体・構造物を複製しない拡散補間）で外側へシームレスに補間する
    private static func inpaintTopArchCornersWithPhotoBackground(
        leftRGB: inout [UInt8],
        rightRGB: inout [UInt8],
        width w: Int,
        height h: Int,
        cardRGB: (r: Double, g: Double, b: Double),
        globalCardRGB: (r: Double, g: Double, b: Double)? = nil,
        leftBoxStart: (x: Int, y: Int),
        rightBoxStart: (x: Int, y: Int),
        cardSize: (w: Int, h: Int),
        barrier: MountBarrierMap?,
        isTop: Bool = true
    ) {
        guard w >= 48, h >= 48, leftRGB.count >= w * h * 3, rightRGB.count >= w * h * 3 else { return }
        let maxCornerX = isTop ? min(w / 2, Int(Double(w) * 0.46)) : min(w / 2, Int(Double(w) * 0.28))
        let maxCornerY = isTop ? min(h / 2, Int(Double(h) * 0.28)) : min(h / 2, Int(Double(h) * 0.22))
        guard maxCornerX >= 8, maxCornerY >= 8 else { return }

        let useBarrier = (barrier != nil && barrier!.model.confidence >= 0.25)
        let cardLuma = (cardRGB.r + cardRGB.g + cardRGB.b) / 3.0
        let globalLuma = globalCardRGB.map { ($0.r + $0.g + $0.b) / 3.0 } ?? cardLuma
        let isPureWhiteCard = (cardLuma >= 242.0 || globalLuma >= 242.0)

        @inline(__always)
        func archEnvelopeY(_ dx: Int) -> Int {
            let u = min(1.0, max(0.0, Double(maxCornerX - dx) / Double(max(1, maxCornerX))))
            return Int((Double(maxCornerY) * (1.0 - sqrt(max(0.0, 1.0 - u * u)))).rounded())
        }

        func processCorner(_ rgb: inout [UInt8], boxStart: (x: Int, y: Int), isRightCorner: Bool) {
            @inline(__always)
            func xAt(_ dx: Int) -> Int { isRightCorner ? (w - 1 - dx) : dx }
            @inline(__always)
            func yAt(_ dy: Int) -> Int { isTop ? dy : (h - 1 - dy) }

            // 隅三角域 (dx + dy < 18) から局所台紙色を採取（明色台紙では外縁黒仕切り線・影画素を母数から除外）
            var cornerSamplesR: [Double] = []
            var cornerSamplesG: [Double] = []
            var cornerSamplesB: [Double] = []
            var cornerBgHits = 0
            var cornerTotal = 0
            let sampleLimX = min(16, maxCornerX)
            let sampleLimY = min(16, maxCornerY)
            for dy in 0..<sampleLimY {
                let row = yAt(dy) * w * 3
                for dx in 0..<sampleLimX where dx + dy < 18 {
                    let i = row + xAt(dx) * 3
                    let r = Double(rgb[i]), g = Double(rgb[i + 1]), b = Double(rgb[i + 2])
                    let luma = (r + g + b) / 3.0
                    if cardLuma > 130.0 && luma < 95.0 { continue }
                    cornerTotal += 1
                    let dCard = max(abs(r - cardRGB.r), max(abs(g - cardRGB.g), abs(b - cardRGB.b)))
                    let dGlob = globalCardRGB.map { max(abs(r - $0.r), max(abs(g - $0.g), abs(b - $0.b))) } ?? dCard
                    let minD = min(dCard, dGlob)
                    if minD <= 32.0 {
                        cornerBgHits += 1
                        cornerSamplesR.append(r)
                        cornerSamplesG.append(g)
                        cornerSamplesB.append(b)
                    }
                }
            }
            guard cornerTotal > 0,
                  cornerSamplesR.count >= 8,
                  Double(cornerBgHits) / Double(cornerTotal) >= 0.35 else {
                return
            }
            cornerSamplesR.sort(); cornerSamplesG.sort(); cornerSamplesB.sort()
            let mid = cornerSamplesR.count / 2
            let localBg = (r: cornerSamplesR[mid], g: cornerSamplesG[mid], b: cornerSamplesB[mid])

            @inline(__always)
            func isStrictMountPixel(_ x: Int, _ dy: Int) -> Bool {
                let y = yAt(dy)
                let i = (y * w + x) * 3
                let r = Double(rgb[i]), g = Double(rgb[i + 1]), b = Double(rgb[i + 2])
                if isPureWhiteCard {
                    let luma = (r + g + b) / 3.0
                    let chroma = max(r, max(g, b)) - min(r, min(g, b))
                    return luma >= 236.0 && chroma <= 18.0
                }
                let dLocal = max(abs(r - localBg.r), max(abs(g - localBg.g), abs(b - localBg.b)))
                let dCard = max(abs(r - cardRGB.r), max(abs(g - cardRGB.g), abs(b - cardRGB.b)))
                let dGlob = globalCardRGB.map { max(abs(r - $0.r), max(abs(g - $0.g), abs(b - $0.b))) } ?? dCard
                let minD = min(dLocal, min(dCard, dGlob))
                if minD > 28.0 { return false }
                if useBarrier, let bMap = barrier, cardSize.w > 1, cardSize.h > 1 {
                    let nx = Double(max(0, min(cardSize.w - 1, boxStart.x + x))) / Double(cardSize.w - 1)
                    let ny = Double(max(0, min(cardSize.h - 1, boxStart.y + y))) / Double(cardSize.h - 1)
                    if bMap.isConnectedBarrierAt(normX: nx, normY: ny) {
                        return minD <= 28.0
                    }
                }
                return minD <= (isTop ? 25.0 : 18.0)
            }

            // 外端 (dx = 0) から内側へ向かって各列の台紙終了行を特定（厳格単調減少＋楕円アーチ包絡線上限）
            var dropYs = [Int](repeating: 0, count: maxCornerX)
            var curUpperBound = maxCornerY - 3
            var zeroRun = 0
            var extremeDepthCols = 0
            for dx in 0..<maxCornerX {
                let x = xAt(dx)
                var hasEdgeMount = false
                var topIsDarkRule = true
                for tdy in 0..<min(6, maxCornerY) {
                    let ti = (yAt(tdy) * w + x) * 3
                    let tl = (Double(rgb[ti]) + Double(rgb[ti + 1]) + Double(rgb[ti + 2])) / 3.0
                    if !(cardLuma > 130.0 && tl < 95.0) { topIsDarkRule = false }
                    if isStrictMountPixel(x, tdy) {
                        hasEdgeMount = true
                        break
                    }
                }
                if !hasEdgeMount {
                    if dx < 8 && topIsDarkRule {
                        continue
                    }
                    zeroRun += 1
                    if zeroRun >= 5 && dx >= 12 { break }
                    continue
                }
                zeroRun = 0

                let envLim = archEnvelopeY(dx) + 2
                let scanLim = min(maxCornerY - 3, min(envLim, (dx < 8) ? (maxCornerY - 3) : curUpperBound))
                guard scanLim >= 1 else { break }
                var drop = 0
                for dy in 0..<scanLim {
                    if !isStrictMountPixel(x, dy)
                        && !isStrictMountPixel(x, dy + 1)
                        && !isStrictMountPixel(x, dy + 2) {
                        drop = dy
                        break
                    }
                    drop = dy + 1
                }
                if drop >= maxCornerY - 3 {
                    // 台紙が探索上限まで突き抜ける場合（空と台紙の完全同色化）は誤侵食防止のため安全抑制
                    extremeDepthCols += 1
                    if dx < 5 && extremeDepthCols >= 3 {
                        return
                    }
                    drop = 0
                }
                // 境界直下の暗いアーチ縁取り線 (最大 3px) のみを跨いでクリーンな写真境界へ進める
                if drop > 0 && drop + 2 < maxCornerY {
                    for _ in 0..<3 {
                        guard drop + 2 < maxCornerY && drop + 1 <= envLim else { break }
                        let iC = (yAt(drop) * w + x) * 3
                        let iN = (yAt(drop + 2) * w + x) * 3
                        let lC = (Double(rgb[iC]) + Double(rgb[iC + 1]) + Double(rgb[iC + 2])) / 3.0
                        let lN = (Double(rgb[iN]) + Double(rgb[iN + 1]) + Double(rgb[iN + 2])) / 3.0
                        if lN - lC >= 10.0 || isStrictMountPixel(x, drop) {
                            drop += 1
                        } else {
                            break
                        }
                    }
                }
                if drop > 0 {
                    let safeDrop = min(envLim, min(h / 2 - 4, drop + 2))
                    dropYs[dx] = safeDrop
                    curUpperBound = (dx < 8) ? safeDrop : min(curUpperBound, safeDrop)
                }
            }

            // 外縁 dx < 8 が黒仕切り線等で欠けた場合は直近内側有効列の高さで補完
            if let firstValid = (0..<min(10, maxCornerX)).first(where: { dropYs[$0] > 0 }), firstValid > 0 {
                for dx in 0..<firstValid where dropYs[dx] == 0 {
                    dropYs[dx] = min(archEnvelopeY(dx) + 2, dropYs[firstValid])
                }
            }

            // 列方向のノイズ平滑（3点中央値）＋ 単調非増加・楕円包絡線の厳格強制
            var smoothDrops = dropYs
            if maxCornerX >= 3 {
                for dx in 1..<(maxCornerX - 1) {
                    let a = dropYs[dx - 1], b = dropYs[dx], c = dropYs[dx + 1]
                    smoothDrops[dx] = max(min(a, b), min(max(a, b), c))
                }
            }
            for dx in 0..<maxCornerX {
                smoothDrops[dx] = min(smoothDrops[dx], archEnvelopeY(dx) + 2)
                if dx > 0 {
                    smoothDrops[dx] = min(smoothDrops[dx], smoothDrops[dx - 1])
                }
            }

            let activeEndDx = (0..<maxCornerX).reversed().first(where: { smoothDrops[$0] >= 2 }) ?? -1
            guard activeEndDx >= 2 else { return }

            // 境界直下の「構造物・暗部を避けた平坦な写真背景色」を列ごとに抽出
            var colBgColors = [(r: Double, g: Double, b: Double)?](repeating: nil, count: maxCornerX)
            for dx in 0...activeEndDx {
                let drop = smoothDrops[dx]
                guard drop >= 2 else { continue }
                let x = xAt(dx)
                let dyStart = min(h - 2, drop + 1)
                let dyEnd = min(h - 1, dyStart + 6)
                var bestScore = Double.greatestFiniteMagnitude
                var bestCol: (r: Double, g: Double, b: Double)? = nil
                for sdy in dyStart..<dyEnd {
                    let sy = yAt(sdy)
                    let i = (sy * w + x) * 3
                    let r = Double(rgb[i]), g = Double(rgb[i + 1]), b = Double(rgb[i + 2])
                    let luma = (r + g + b) / 3.0
                    // 縦・横の局所勾配を計算（平坦な空・壁ほどスコアが良い）
                    let syN = yAt(min(h - 1, sdy + 1))
                    let sxP = max(0, x - 1), sxN = min(w - 1, x + 1)
                    let iYN = (syN * w + x) * 3
                    let iXP = (sy * w + sxP) * 3
                    let iXN = (sy * w + sxN) * 3
                    let lYN = (Double(rgb[iYN]) + Double(rgb[iYN + 1]) + Double(rgb[iYN + 2])) / 3.0
                    let lXP = (Double(rgb[iXP]) + Double(rgb[iXP + 1]) + Double(rgb[iXP + 2])) / 3.0
                    let lXN = (Double(rgb[iXN]) + Double(rgb[iXN + 1]) + Double(rgb[iXN + 2])) / 3.0
                    let grad = abs(luma - lYN) + abs(lXN - lXP) * 0.5
                    let darkPenalty = max(0.0, 90.0 - luma) * 0.35
                    let score = grad + darkPenalty + Double(sdy - dyStart) * 1.5
                    if score < bestScore {
                        bestScore = score
                        bestCol = (r, g, b)
                    }
                }
                colBgColors[dx] = bestCol
            }

            // 暗い被写体（ヤシの葉・頭髪など）を除いた平坦背景帯 (40%..85%輝度) からコーナー代表背景色を算出
            var validCols: [(dx: Int, r: Double, g: Double, b: Double, luma: Double)] = []
            for dx in 0...activeEndDx {
                if let c = colBgColors[dx] {
                    validCols.append((dx, c.r, c.g, c.b, (c.r + c.g + c.b) / 3.0))
                }
            }
            guard !validCols.isEmpty else { return }
            let sortedByLuma = validCols.sorted { $0.luma < $1.luma }
            let cornerPhotoBgLuma = sortedByLuma[sortedByLuma.count * 2 / 3].luma
            let loBand = (sortedByLuma.count * 2) / 5
            let hiBand = max(loBand, (sortedByLuma.count * 17) / 20)
            let flatBand = Array(sortedByLuma[loBand...min(sortedByLuma.count - 1, hiBand)])
            let flatMid = flatBand[flatBand.count / 2]
            let baseCornerBg = (r: flatMid.r, g: flatMid.g, b: flatMid.b)

            // 暗部列を baseCornerBg に置換した上で、広い水平平滑半径 (-rad...rad) で列間の縦ストライプを完全に消去
            var filteredCols = [(r: Double, g: Double, b: Double)](repeating: baseCornerBg, count: activeEndDx + 1)
            for dx in 0...activeEndDx {
                if let c = colBgColors[dx] {
                    let l = (c.r + c.g + c.b) / 3.0
                    filteredCols[dx] = (l < cornerPhotoBgLuma - 16.0) ? baseCornerBg : c
                }
            }
            let rad = max(16, activeEndDx / 3)
            var smoothCols = [(r: Double, g: Double, b: Double)](repeating: baseCornerBg, count: activeEndDx + 1)
            for dx in 0...activeEndDx {
                var rSum = 0.0, gSum = 0.0, bSum = 0.0, wSum = 0.0
                for off in -rad...rad {
                    let nx = dx + off
                    guard nx >= 0 && nx <= activeEndDx else { continue }
                    let c = filteredCols[nx]
                    let wt = exp(-Double(off * off) / (2.0 * Double(rad * rad) * 0.25))
                    rSum += c.r * wt; gSum += c.g * wt; bSum += c.b * wt; wSum += wt
                }
                if wSum > 0 {
                    smoothCols[dx] = (rSum / wSum, gSum / wSum, bSum / wSum)
                }
            }

            // 内側端（肩付近）のクリーンな写真境界色も取得し、外側隅に向かって滑らかにブレンド
            let innerAnchorX = xAt(min(w - 1, activeEndDx + 3))
            var innerR = 0.0, innerG = 0.0, innerB = 0.0, innerCnt = 0.0
            for tdy in 1..<min(5, h) {
                let i = (yAt(tdy) * w + innerAnchorX) * 3
                innerR += Double(rgb[i]); innerG += Double(rgb[i + 1]); innerB += Double(rgb[i + 2]); innerCnt += 1.0
            }
            let rawInnerBg = innerCnt > 0
                ? (r: innerR / innerCnt, g: innerG / innerCnt, b: innerB / innerCnt)
                : baseCornerBg
            let innerLuma = (rawInnerBg.r + rawInnerBg.g + rawInnerBg.b) / 3.0
            let innerBg = (innerLuma < cornerPhotoBgLuma - 18.0) ? baseCornerBg : rawInnerBg

            // 構造物を一切コピーせず、平坦背景色の広域2D拡散補間＋微細紙グレイン＋4px境界フェザリングで縦筋ゼロに埋める
            let featherAlphas = [0.25, 0.50, 0.75, 0.90]
            for dx in 0...activeEndDx {
                let drop = smoothDrops[dx]
                guard drop >= 2 else { continue }
                let x = xAt(dx)
                let colC = smoothCols[dx]
                let rowSpan = max(1.0, Double(drop))

                for dy in 0..<drop {
                    let y = yAt(dy)
                    let distFromBoundary = drop - 1 - dy
                    // 境界付近は smoothCols[dx]、隅先端へ向かうほど代表平場色 baseCornerBg へ速やかに収束（縦ストライプ防止）
                    let tBase = min(1.0, Double(max(0, distFromBoundary)) / max(6.0, rowSpan * 0.45))
                    let localR = colC.r * (1.0 - tBase) + baseCornerBg.r * tBase
                    let localG = colC.g * (1.0 - tBase) + baseCornerBg.g * tBase
                    let localB = colC.b * (1.0 - tBase) + baseCornerBg.b * tBase
                    let tVert = Double(dy) / rowSpan
                    let mixInner = (1.0 - tVert) * 0.35
                    var br = localR * (1.0 - mixInner) + innerBg.r * mixInner
                    var bg = localG * (1.0 - mixInner) + innerBg.g * mixInner
                    var bb = localB * (1.0 - mixInner) + innerBg.b * mixInner

                    // 微細なヴィンテージ紙粒状ノイズ（19世紀印画紙の質感を保ち、のっぺり感をなくす）
                    let h1 = UInt64(truncatingIfNeeded: x &* 73856093) ^ UInt64(truncatingIfNeeded: y &* 19349663) ^ 0x9e3779b97f4a7c15
                    let h2 = (h1 ^ (h1 >> 30)) &* 0xbf58476d1ce4e5b9
                    let grain = (Double(h2 & 0xff) / 255.0 - 0.5) * 4.5
                    br += grain; bg += grain; bb += grain * 0.85

                    let dstI = (y * w + x) * 3
                    // 最内縁 4px は元写真画素とソフトフェザーブレンド
                    if distFromBoundary < 4 {
                        let alpha = featherAlphas[distFromBoundary]
                        let inv = 1.0 - alpha
                        br = br * alpha + Double(rgb[dstI]) * inv
                        bg = bg * alpha + Double(rgb[dstI + 1]) * inv
                        bb = bb * alpha + Double(rgb[dstI + 2]) * inv
                    }
                    rgb[dstI]     = UInt8(max(0, min(255, Int(br.rounded()))))
                    rgb[dstI + 1] = UInt8(max(0, min(255, Int(bg.rounded()))))
                    rgb[dstI + 2] = UInt8(max(0, min(255, Int(bb.rounded()))))
                }
            }
        }

        processCorner(&leftRGB, boxStart: leftBoxStart, isRightCorner: false)
        processCorner(&leftRGB, boxStart: leftBoxStart, isRightCorner: true)
        processCorner(&rightRGB, boxStart: rightBoxStart, isRightCorner: false)
        processCorner(&rightRGB, boxStart: rightBoxStart, isRightCorner: true)
    }

    /// 外側コーナー（L左上・R右上）の実測台紙深さプロファイルを左右対称に全4上隅へ適用し、
    /// 中央谷間の数字（594等）やその下のグレー台紙・白フリンジを完全に黒マスク化する
    private static func cleanSymmetricTopArchShoulders(
        _ leftRGB: inout [UInt8],
        _ rightRGB: inout [UInt8],
        width w: Int,
        height h: Int,
        cardRGB: (r: Double, g: Double, b: Double)
    ) {
        let tol = 25.0
        let maxScanX = min(w / 2, Int(Double(w) * 0.42))
        let maxScanY = min(h / 2, Int(Double(h) * 0.36))
        guard maxScanX >= 12, maxScanY >= 12 else { return }

        func isCard(_ rgb: [UInt8], _ x: Int, _ y: Int) -> Bool {
            let idx = (y * w + x) * 3
            let dr = abs(Double(rgb[idx]) - cardRGB.r)
            let dg = abs(Double(rgb[idx + 1]) - cardRGB.g)
            let db = abs(Double(rgb[idx + 2]) - cardRGB.b)
            return max(dr, max(dg, db)) <= tol
        }

        let safetyInsetY = max(4, Int(Double(h) * 0.006))
        for dx in 0..<maxScanX {
            var dropL = 0
            for y in 0..<(maxScanY - 7) {
                var nonCard = 0
                for k in 0..<7 {
                    if !isCard(leftRGB, dx, y + k) { nonCard += 1 }
                }
                if nonCard >= 6 { dropL = y; break }
            }
            var dropR = 0
            let rx = w - 1 - dx
            for y in 0..<(maxScanY - 7) {
                var nonCard = 0
                for k in 0..<7 {
                    if !isCard(rightRGB, rx, y + k) { nonCard += 1 }
                }
                if nonCard >= 6 { dropR = y; break }
            }
            let drop = max(dropL, dropR)
            guard drop > 2 else { continue }
            let maskEndY = min(maxScanY, drop + safetyInsetY)
            let xLeft = dx
            let xRight = w - 1 - dx
            for y in 0..<maskEndY {
                let iLL = (y * w + xLeft) * 3
                let iLR = (y * w + xRight) * 3
                leftRGB[iLL] = 0; leftRGB[iLL + 1] = 0; leftRGB[iLL + 2] = 0
                leftRGB[iLR] = 0; leftRGB[iLR + 1] = 0; leftRGB[iLR + 2] = 0
                rightRGB[iLL] = 0; rightRGB[iLL + 1] = 0; rightRGB[iLL + 2] = 0
                rightRGB[iLR] = 0; rightRGB[iLR + 1] = 0; rightRGB[iLR + 2] = 0
            }
        }
    }

    /// フル解像度 RGB 画像の上部 4 隅で、台紙の RGB 色（緑台紙・セピア空の区別を含む）から上部角丸半径（直角=0.0含む）を実測する
    private static func measureTopArchRadiusRGB(
        leftRGB: [UInt8],
        rightRGB: [UInt8],
        width w: Int,
        height h: Int,
        cardRGB: (r: Double, g: Double, b: Double)
    ) -> Double? {
        guard w >= 64, h >= 64, leftRGB.count >= w * h * 3, rightRGB.count >= w * h * 3 else { return nil }
        // まず上隅先端 2.2% × 2.2% に台紙色が存在しない（長方形プリントの直角上隅）なら 0.0 を返す
        if isCornersSquareRGB(leftRGB: leftRGB, rightRGB: rightRGB, width: w, height: h, cardRGB: cardRGB, isTop: true) {
            return 0.0
        }

        let cw = max(8, Int(Double(w) * 0.34))
        let ch = max(8, Int(Double(h) * 0.38))
        let areaScale = max(1.0, 0.2146018 * Double(w * h))
        let tol = 24.0

        func cornerRadius(_ rgb: [UInt8], isRight: Bool) -> Double {
            var count = 0
            rgb.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                func rgbAt(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
                    let cx = min(w - 1, max(0, x))
                    let cy = min(h - 1, max(0, y))
                    let i = (cy * w + cx) * 3
                    return (Double(base[i]), Double(base[i + 1]), Double(base[i + 2]))
                }
                for dy in 0..<ch {
                    let maxDX = min(cw, Int(Double(cw) * (1.05 - Double(dy) / Double(ch))))
                    guard maxDX > 0 else { continue }
                    for dx in 0..<maxDX {
                        let x = isRight ? (w - 1 - dx) : dx
                        let p = rgbAt(x, dy)
                        guard abs(p.r - cardRGB.r) <= tol,
                              abs(p.g - cardRGB.g) <= tol,
                              abs(p.b - cardRGB.b) <= tol else { continue }
                        let px = rgbAt(isRight ? (x - 2) : (x + 2), dy)
                        let py = rgbAt(x, dy + 2)
                        let dxMax = max(abs(p.r - px.r), max(abs(p.g - px.g), abs(p.b - px.b)))
                        let dyMax = max(abs(p.r - py.r), max(abs(p.g - py.g), abs(p.b - py.b)))
                        if dxMax <= 18.0 && dyMax <= 18.0 {
                            count += 1
                        }
                    }
                }
            }
            return sqrt(Double(count) / areaScale)
        }

        let tlL = cornerRadius(leftRGB, isRight: false)
        let trL = cornerRadius(leftRGB, isRight: true)
        let tlR = cornerRadius(rightRGB, isRight: false)
        let trR = cornerRadius(rightRGB, isRight: true)
        let rMinPair = min((tlL + tlR) * 0.5, (trL + trR) * 0.5)
        guard rMinPair > 0.01 else { return 0.0 }
        // 外周インセット（0.4%〜0.8%）で削られた台紙縁の補正分 +0.03 を加算
        return rMinPair + 0.03
    }

    /// コーナー形状計測用の背景色を決定する。
    /// 台紙のない純白背景（luma >= 244, 例: 白抜きアーチ画像）や純黒背景（luma <= 12）が
    /// 4隅すべてに広がり、かつ中央辺縁部には広がっていない場合はその背景色を優先する。
    private static func resolveCornerBackgroundRGB(
        leftRGB: [UInt8],
        rightRGB: [UInt8],
        width w: Int,
        height h: Int,
        cardRGB: (r: Double, g: Double, b: Double)?,
        isTop: Bool
    ) -> (r: Double, g: Double, b: Double)? {
        guard w >= 32, h >= 32, leftRGB.count >= w * h * 3, rightRGB.count >= w * h * 3 else {
            return cardRGB
        }
        let ix = max(2, Int(Double(w) * 0.006))
        let iy = max(2, Int(Double(h) * 0.006))
        let cw = max(3, Int(Double(w) * 0.022))
        let ch = max(3, Int(Double(h) * 0.022))
        let y0 = isTop ? min(h - ch, iy) : max(0, h - iy - ch)
        let xR = max(0, w - ix - cw)

        func extremeRatios(_ rgb: [UInt8], xStart: Int, xEnd: Int, yStart: Int, yEnd: Int) -> (white: Double, black: Double) {
            var total = 0, wCnt = 0, bCnt = 0
            rgb.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                for y in yStart..<yEnd {
                    let row = y * w * 3
                    for x in xStart..<xEnd {
                        let i = row + x * 3
                        let luma = (Double(base[i]) + Double(base[i + 1]) + Double(base[i + 2])) / 3.0
                        total += 1
                        if luma >= 244.0 { wCnt += 1 }
                        if luma <= 12.0 { bCnt += 1 }
                    }
                }
            }
            guard total > 0 else { return (0.0, 0.0) }
            return (Double(wCnt) / Double(total), Double(bCnt) / Double(total))
        }

        let patches = [
            extremeRatios(leftRGB, xStart: ix, xEnd: ix + cw, yStart: y0, yEnd: y0 + ch),
            extremeRatios(leftRGB, xStart: xR, xEnd: xR + cw, yStart: y0, yEnd: y0 + ch),
            extremeRatios(rightRGB, xStart: ix, xEnd: ix + cw, yStart: y0, yEnd: y0 + ch),
            extremeRatios(rightRGB, xStart: xR, xEnd: xR + cw, yStart: y0, yEnd: y0 + ch),
        ]
        let cx0 = max(0, Int(Double(w) * 0.38))
        let cx1 = min(w, max(cx0 + 1, Int(Double(w) * 0.62)))
        let midL = extremeRatios(leftRGB, xStart: cx0, xEnd: cx1, yStart: y0, yEnd: y0 + ch)
        let midR = extremeRatios(rightRGB, xStart: cx0, xEnd: cx1, yStart: y0, yEnd: y0 + ch)
        let centerWhite = (midL.white + midR.white) * 0.5
        let centerBlack = (midL.black + midR.black) * 0.5

        let minWhite = patches.map(\.white).min() ?? 0.0
        if minWhite >= 0.85 && centerWhite < 0.35 {
            return (255.0, 255.0, 255.0)
        }
        let minBlack = patches.map(\.black).min() ?? 0.0
        let cardLuma = cardRGB.map { ($0.r + $0.g + $0.b) / 3.0 }
        if minBlack >= 0.85 && centerBlack < 0.35 && (cardLuma == nil || cardLuma! > 28.0) {
            return (0.0, 0.0, 0.0)
        }
        return cardRGB
    }

    /// 切り出し画像の上部または下部 4 隅（最外縁インセット内 2.2% × 2.2%）で背景 RGB 色との一致率を昇順で返す
    private static func cornerCardRatiosRGB(
        leftRGB: [UInt8],
        rightRGB: [UInt8],
        width w: Int,
        height h: Int,
        cardRGB: (r: Double, g: Double, b: Double),
        isTop: Bool
    ) -> [Double] {
        guard w >= 32, h >= 32, leftRGB.count >= w * h * 3, rightRGB.count >= w * h * 3 else {
            return [0.0, 0.0, 0.0, 0.0]
        }
        let ix = max(2, Int(Double(w) * 0.006))
        let iy = max(2, Int(Double(h) * 0.006))
        let cw = max(3, Int(Double(w) * 0.022))
        let ch = max(3, Int(Double(h) * 0.022))
        let tol = 24.0

        func cornerCardRatio(_ rgb: [UInt8], xStart: Int, yStart: Int) -> Double {
            var count = 0
            var match = 0
            rgb.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                for y in yStart..<(yStart + ch) {
                    let row = y * w * 3
                    for x in xStart..<(xStart + cw) {
                        let i = row + x * 3
                        let dr = abs(Double(base[i]) - cardRGB.r)
                        let dg = abs(Double(base[i + 1]) - cardRGB.g)
                        let db = abs(Double(base[i + 2]) - cardRGB.b)
                        count += 1
                        if max(dr, max(dg, db)) <= tol { match += 1 }
                    }
                }
            }
            return count > 0 ? Double(match) / Double(count) : 0.0
        }

        let y0 = isTop ? min(h - ch, iy) : max(0, h - iy - ch)
        let xR = max(0, w - ix - cw)
        return [
            cornerCardRatio(leftRGB, xStart: ix, yStart: y0),
            cornerCardRatio(leftRGB, xStart: xR, yStart: y0),
            cornerCardRatio(rightRGB, xStart: ix, yStart: y0),
            cornerCardRatio(rightRGB, xStart: xR, yStart: y0),
        ].sorted()
    }

    /// 切り出し画像の上部または下部 4 隅（最外縁インセット内 2.2% × 2.2%）で台紙 RGB 色との一致率を調べ、
    /// 写真本体が隅まで詰まっている（＝角丸ではなく直角）かを自動判定する
    private static func isCornersSquareRGB(
        leftRGB: [UInt8],
        rightRGB: [UInt8],
        width w: Int,
        height h: Int,
        cardRGB: (r: Double, g: Double, b: Double),
        isTop: Bool
    ) -> Bool {
        let ratios = cornerCardRatiosRGB(leftRGB: leftRGB, rightRGB: rightRGB, width: w, height: h, cardRGB: cardRGB, isTop: isTop)
        // 下位 2 隅の平均が 30% 未満なら、写真本体が直角の角まで入っているとみなす
        return (ratios[0] + ratios[1]) * 0.5 < 0.30
    }

    /// 左右外端（cLx0, cRx1）に台紙 RGB と同色の均一な帯（緑台紙等）が連続して残っている場合のみ内側へトリミングする
    /// 左右外端（cLx0, cRx1）の均一台紙帯・縦書き文字マージン（外側文字+内側ギャップ+細枠線）・縦黒枠バンドおよび中央仕切り黒線を検出し、
    /// 写真本体の垂直境界線まで安全かつ正確にトリミングする
    private static func trimOuterCardColumnsRGB(
        rgb: [UInt8],
        srcW: Int,
        srcH: Int,
        cLx0: inout Int,
        cLx1: inout Int,
        cLy0: Int,
        cLy1: Int,
        cRx0: inout Int,
        cRx1: inout Int,
        cRy0: Int,
        cRy1: Int,
        cardRGB: (r: Double, g: Double, b: Double)
    ) {
        guard srcW >= 64, srcH >= 64, rgb.count >= srcW * srcH * 3 else { return }
        let tol = 28.0
        let cardLuma = (cardRGB.r + cardRGB.g + cardRGB.b) / 3.0

        struct ColMetrics {
            let bgRatio: Double
            let inkRatio: Double
            let darkRatio: Double
            let meanLuma: Double
            let std: Double
        }

        func analyzeCol(x: Int, y0: Int, y1: Int) -> ColMetrics {
            let h = y1 - y0
            guard h >= 16, x >= 0, x < srcW else {
                return ColMetrics(bgRatio: 0, inkRatio: 0, darkRatio: 0, meanLuma: 0, std: 255)
            }
            let sy0 = max(0, y0 + h / 7)
            let sy1 = min(srcH, y1 - h / 7)
            let step = max(1, (sy1 - sy0) / 64)
            var count = 0
            var bgCnt = 0
            var inkCnt = 0
            var darkCnt = 0
            var sum = 0.0
            var sumSq = 0.0
            rgb.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                var y = sy0
                while y < sy1 {
                    let i = (y * srcW + x) * 3
                    let r = Double(base[i])
                    let g = Double(base[i + 1])
                    let b = Double(base[i + 2])
                    let luma = (r + g + b) / 3.0
                    sum += luma
                    sumSq += luma * luma
                    count += 1
                    if max(abs(r - cardRGB.r), max(abs(g - cardRGB.g), abs(b - cardRGB.b))) <= tol {
                        bgCnt += 1
                    } else if cardLuma >= 120.0 ? (luma <= cardLuma - 22.0) : (luma >= cardLuma + 22.0) {
                        inkCnt += 1
                    }
                    if luma <= 92.0 {
                        darkCnt += 1
                    }
                    y += step
                }
            }
            guard count >= 8 else {
                return ColMetrics(bgRatio: 0, inkRatio: 0, darkRatio: 0, meanLuma: 0, std: 255)
            }
            let mean = sum / Double(count)
            let std = sqrt(max(0.0, sumSq / Double(count) - mean * mean))
            return ColMetrics(
                bgRatio: Double(bgCnt) / Double(count),
                inkRatio: Double(inkCnt) / Double(count),
                darkRatio: Double(darkCnt) / Double(count),
                meanLuma: mean,
                std: std
            )
        }

        // 外側から内側へ向かって最大 12% 範囲でマージン/縦文字/黒枠境界を探索（dir = +1: cLx0→右, -1: cRx1-1→左）
        func scanOuterEdge(startEdge: Int, dir: Int, widthBound: Int, y0: Int, y1: Int) -> Int? {
            let maxTrim = min(Int(Double(widthBound) * 0.12), max(4, widthBound - 64))
            guard maxTrim >= 4 else { return nil }

            // 開始位置の外側にすでに明るい台紙色があるか事前チェック（U-Netが黒枠の直前で止まったケース向け）
            var outerEdgeHasCard = false
            for back in 1...8 {
                let bx = startEdge - dir * back
                if bx >= 0 && bx < srcW {
                    let st = analyzeCol(x: bx, y0: y0, y1: y1)
                    if st.bgRatio >= 0.45 {
                        outerEdgeHasCard = true
                        break
                    }
                }
            }

            var cols: [ColMetrics] = []
            cols.reserveCapacity(maxTrim)
            var photoMissStreak = 0
            for dx in 0..<maxTrim {
                let x = dir > 0 ? (startEdge + dx) : (startEdge - dx)
                let st = analyzeCol(x: x, y0: y0, y1: y1)
                cols.append(st)
                let isMarginLike =
                    st.bgRatio >= 0.42 ||
                    st.darkRatio >= 0.64 ||
                    (st.bgRatio >= 0.24 && (st.bgRatio + st.inkRatio) >= 0.74)
                if isMarginLike {
                    photoMissStreak = 0
                } else {
                    photoMissStreak += 1
                    // 連続4列以上、純粋な写真テクスチャが続いたら探索打ち切り（写真内誤侵食を防止）
                    if photoMissStreak >= 4 {
                        break
                    }
                }
            }

            let validLen = cols.count - photoMissStreak
            guard validLen >= 1 else { return nil }

            // 1. 最も内側にある連続クリーン台紙ギャップ（または外側文字を越えた境界クリーンギャップ）終端を探す
            // ただし、一度でも明確な写真テクスチャ（bgRatio < 0.35 かつ darkRatio < 0.50、または std >= 26.0 かつ bgRatio < 0.55）に入った後は写真内部の空・壁とみなして停止
            var pureRun = 0
            var bestCutIdx: Int? = nil
            var prefixBgSum = 0.0
            for idx in 0..<validLen {
                let st = cols[idx]
                if (st.bgRatio < 0.35 && st.darkRatio < 0.50) || (st.std >= 26.0 && st.bgRatio < 0.55) {
                    break
                }
                prefixBgSum += st.bgRatio
                let isPure = st.bgRatio >= 0.78 && st.std <= 14.0
                let prevIsNearPure = idx > 0 && cols[idx - 1].bgRatio >= 0.74
                if isPure {
                    pureRun += 1
                    if idx < 4 || pureRun >= 2 || (prevIsNearPure && st.std <= 15.0) {
                        let meanPrefixBg = prefixBgSum / Double(idx + 1)
                        if meanPrefixBg >= 0.42 {
                            bestCutIdx = idx + 1
                        }
                    }
                } else {
                    pureRun = 0
                }
            }

            // 1b. 上記純粋台紙境界の直内側に 1〜6px の暗い縦枠線・縁取りがある場合は黒枠の内側まで進める
            if let cut = bestCutIdx {
                var adv = cut
                let maxDarkBorder = min(validLen, cut + 8)
                while adv < maxDarkBorder && cols[adv].darkRatio >= 0.62 && cols[adv].std <= 30.0 {
                    adv += 1
                }
                if adv > cut {
                    bestCutIdx = adv
                }
            }

            // 2. 太い縦黒枠（cardLuma >= 115 の明台紙カードで外周に明るい台紙を伴う均一縦黒バンド）を検出
            if cardLuma >= 115.0 {
                let maxDarkBand = max(5, Int(Double(widthBound) * 0.065))
                var darkRun = 0
                var darkSumLuma = 0.0
                var hasOuterCard = outerEdgeHasCard
                for idx in 0..<validLen {
                    let st = cols[idx]
                    if st.bgRatio >= 0.48 {
                        hasOuterCard = true
                    }
                    // 黒枠始まり1列目の抗エイリアス滲みだけ darkRatio >= 0.72 && 次が濃厚黒枠なら開始可
                    let isStartAntiAlias = darkRun == 0 && idx + 1 < validLen
                        && st.darkRatio >= 0.72 && cols[idx + 1].darkRatio >= 0.88 && st.std <= 20.0
                    if (st.darkRatio >= 0.88 && st.std <= 16.0 && st.meanLuma <= 55.0) || isStartAntiAlias {
                        darkRun += 1
                        darkSumLuma += st.meanLuma
                        if darkRun >= 2 && darkRun <= maxDarkBand && (hasOuterCard || idx <= 6) {
                            let nextIdx = idx + 1
                            if nextIdx < cols.count {
                                let darkMean = darkSumLuma / Double(darkRun)
                                let nextCol = cols[nextIdx]
                                if nextCol.darkRatio < 0.55
                                    && (nextCol.meanLuma >= darkMean + 12.0 || nextCol.std >= 12.0) {
                                    bestCutIdx = max(bestCutIdx ?? 0, nextIdx)
                                }
                            }
                        }
                    } else {
                        darkRun = 0
                        darkSumLuma = 0.0
                    }
                }
            }

            guard let finalSteps = bestCutIdx, finalSteps > 0 else { return nil }
            return dir > 0 ? (startEdge + finalSteps) : (startEdge - finalSteps + 1)
        }

        let candLx0 = scanOuterEdge(startEdge: cLx0, dir: 1, widthBound: cLx1 - cLx0, y0: cLy0, y1: cLy1)
        let candRx1 = scanOuterEdge(startEdge: cRx1 - 1, dir: -1, widthBound: cRx1 - cRx0, y0: cRy0, y1: cRy1)

        let origLW = cLx1 - cLx0
        let origRW = cRx1 - cRx0
        let nextLW = (candLx0.map { $0 > cLx0 && cLx1 - $0 >= 64 ? cLx1 - $0 : origLW }) ?? origLW
        let nextRW = (candRx1.map { $0 < cRx1 && $0 - cRx0 >= 64 ? $0 - cRx0 : origRW }) ?? origRW

        // 片側だけが反対側の幅を大きく下回る（8%以上狭い）過剰トリムは、写真内部の無地背景（空・壁等）への誤侵食とみなして抑止する
        if let newLx0 = candLx0, newLx0 > cLx0 && cLx1 - newLx0 >= 64 {
            if Double(nextLW) >= Double(nextRW) * 0.92 {
                cLx0 = newLx0
            }
        }

        if let newRx1 = candRx1, newRx1 < cRx1 && newRx1 - cRx0 >= 64 {
            if Double(nextRW) >= Double(nextLW) * 0.92 {
                cRx1 = newRx1
            }
        }

        // 3. 中央セパレータ（cLx1, cRx0）の細い黒仕切り線のみを安全に除去（暗い椅子・着物等の被写体保護）
        if cardLuma >= 115.0 {
            let maxCenterTrimL = min(4, max(1, (cLx1 - cLx0) / 80))
            var trimmedL = cLx1
            for dx in 0..<maxCenterTrimL {
                let x = cLx1 - 1 - dx
                let st = analyzeCol(x: x, y0: cLy0, y1: cLy1)
                if st.darkRatio >= 0.90 && st.std <= 14.0 && st.meanLuma <= 48.0 {
                    trimmedL = x
                } else {
                    break
                }
            }
            if trimmedL < cLx1 && trimmedL - cLx0 >= 64 {
                cLx1 = trimmedL
            }

            let maxCenterTrimR = min(4, max(1, (cRx1 - cRx0) / 80))
            var trimmedR = cRx0
            for dx in 0..<maxCenterTrimR {
                let x = cRx0 + dx
                let st = analyzeCol(x: x, y0: cRy0, y1: cRy1)
                if st.darkRatio >= 0.90 && st.std <= 14.0 && st.meanLuma <= 48.0 {
                    trimmedR = x + 1
                } else {
                    break
                }
            }
            if trimmedR > cRx0 && cRx1 - trimmedR >= 64 {
                cRx0 = trimmedR
            }
        }
    }

    /// 過剰トリムされた左右外端および密着カードの中央継ぎ目ギャップを、台紙境界・外周連結バリア・勾配継ぎ目に沿って外側へ復元する
    private static func recoverOvercroppedHorizontalEdgesRGB(
        rgb: [UInt8],
        srcW: Int,
        srcH: Int,
        cLx0: inout Int,
        cLx1: inout Int,
        cLy0: Int,
        cLy1: Int,
        cRx0: inout Int,
        cRx1: inout Int,
        cRy0: Int,
        cRy1: Int,
        cardRGB: (r: Double, g: Double, b: Double),
        barrier: MountBarrierMap?
    ) {
        guard srcW >= 64, srcH >= 64, rgb.count >= srcW * srcH * 3 else { return }
        let tol = 26.0
        let cardLuma = (cardRGB.r + cardRGB.g + cardRGB.b) / 3.0
        let hasValidBarrier = (barrier != nil && barrier!.model.confidence >= 0.25)

        func analyzeVerticalCol(x: Int, yStart: Int, yEnd: Int) -> (bgRatio: Double, darkRatio: Double, meanLuma: Double, std: Double, barrierRatio: Double, isScanMargin: Bool) {
            guard x >= 0, x < srcW, yEnd > yStart + 8 else {
                return (1.0, 0.0, cardLuma, 0.0, 1.0, true)
            }
            let step = max(1, (yEnd - yStart) / 64)
            let normX = Double(x) / Double(max(1, srcW - 1))
            var bgCnt = 0, darkCnt = 0, barCnt = 0, n = 0
            var sum = 0.0, sumSq = 0.0
            rgb.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                var y = yStart
                while y < yEnd {
                    let i = (y * srcW + x) * 3
                    let r = Double(base[i]), g = Double(base[i + 1]), b = Double(base[i + 2])
                    let luma = (r + g + b) / 3.0
                    sum += luma; sumSq += luma * luma
                    n += 1
                    if max(abs(r - cardRGB.r), max(abs(g - cardRGB.g), abs(b - cardRGB.b))) <= tol {
                        bgCnt += 1
                    }
                    if luma <= 78.0 {
                        darkCnt += 1
                    }
                    if hasValidBarrier, let bar = barrier,
                       bar.isConnectedBarrierAt(normX: normX, normY: Double(y) / Double(max(1, srcH - 1))) {
                        barCnt += 1
                    }
                    y += step
                }
            }
            guard n > 0 else { return (1.0, 0.0, cardLuma, 0.0, 1.0, true) }
            let ml = sum / Double(n)
            let std = sqrt(max(0.0, sumSq / Double(n) - ml * ml))
            let bRatio = Double(bgCnt) / Double(n)
            let dRatio = Double(darkCnt) / Double(n)
            let barRatio = hasValidBarrier ? (Double(barCnt) / Double(n)) : 0.0
            let isScan = (std <= 12.0 && (ml >= 228.0 || ml <= 28.0))
            return (bRatio, dRatio, ml, std, barRatio, isScan)
        }

        let maxExpandX = min(Int(Double(srcW) * 0.06), max(8, srcW / 16))

        // 1. 左外端 (cLx0) を外側（左）へ復元
        do {
            let lh = max(16, cLy1 - cLy0)
            let yStart = max(0, cLy0 + lh / 5)
            let yEnd = min(srcH, cLy1 - (lh * 3) / 20)
            var candX = cLx0
            let limitX = max(1, cLx0 - maxExpandX)
            if cLx0 - 1 >= limitX {
                for x in stride(from: cLx0 - 1, through: limitX, by: -1) {
                    let st = analyzeVerticalCol(x: x, yStart: yStart, yEnd: yEnd)
                    if st.isScanMargin || st.barrierRatio >= 0.25 { break }
                    if st.bgRatio >= 0.45 && st.std < 14.0 { break }
                    // 明色台紙上の太い黒枠でない限り写真構造として外へ拡張
                    if st.std >= 16.0 || st.bgRatio < 0.35 {
                        candX = x
                    } else {
                        break
                    }
                }
            }
            if candX < cLx0 - 1 {
                cLx0 = min(cLx0, candX + 1)
            }
        }

        // 2. 右外端 (cRx1) を外側（右）へ復元（右下スタンプを避けるため高さ 18%..68% 帯で判定）
        do {
            let rh = max(16, cRy1 - cRy0)
            let yStart = max(0, cRy0 + Int(Double(rh) * 0.18))
            let yEnd = min(srcH, cRy0 + Int(Double(rh) * 0.68))
            var candX = cRx1
            let limitX = min(srcW - 1, cRx1 + maxExpandX)
            if cRx1 < limitX {
                for x in cRx1..<limitX {
                    let st = analyzeVerticalCol(x: x, yStart: yStart, yEnd: yEnd)
                    if st.isScanMargin || st.barrierRatio >= 0.25 { break }
                    if st.bgRatio >= 0.45 && st.std < 14.0 { break }
                    if st.std >= 16.0 || st.bgRatio < 0.35 {
                        candX = x + 1
                    } else {
                        break
                    }
                }
            }
            if candX > cRx1 + 1 {
                cRx1 = max(cRx1, candX - 1)
            }
        }

        // 3. 中央密着継ぎ目 (cLx1 ..< cRx0) の過剰ギャップ回復
        let gap = cRx0 - cLx1
        let maxSeamlessGap = max(6, Int(Double(srcW) * 0.035))
        if gap >= 2 && gap <= maxSeamlessGap && cLx1 < cRx0 {
            let hCom = max(32, max(cLy1 - cLy0, cRy1 - cRy0))
            let yStart = max(0, min(cLy0, cRy0) + Int(Double(hCom) * 0.22))
            let yEnd = min(srcH, max(cLy1, cRy1) - Int(Double(hCom) * 0.22))
            var mountColStreak = 0
            var maxMountStreak = 0
            for x in cLx1..<cRx0 {
                let st = analyzeVerticalCol(x: x, yStart: yStart, yEnd: yEnd)
                if st.isScanMargin || (st.bgRatio >= 0.55 && st.std <= 16.0) || st.barrierRatio >= 0.45 {
                    mountColStreak += 1
                    maxMountStreak = max(maxMountStreak, mountColStreak)
                } else {
                    mountColStreak = 0
                }
            }
            // 中央に真の台紙分離帯（3列以上）がない密着継ぎ目であれば、最大水平勾配列を継ぎ目として再設定
            if maxMountStreak < 3 && yEnd > yStart + 8 {
                let sx0 = max(cLx0 + 32, cLx1 - 2)
                let sx1 = min(cRx1 - 32, cRx0 + 2)
                if sx1 > sx0 {
                    var bestSeamX = (cLx1 + cRx0) / 2
                    var bestGrad = -1.0
                    let stepY = max(1, (yEnd - yStart) / 64)
                    rgb.withUnsafeBufferPointer { ptr in
                        guard let base = ptr.baseAddress else { return }
                        for x in sx0...sx1 {
                            let xl = max(0, x - 1), xr = min(srcW - 1, x + 1)
                            var gSum = 0.0, n = 0
                            var y = yStart
                            while y < yEnd {
                                let il = (y * srcW + xl) * 3
                                let ir = (y * srcW + xr) * 3
                                let ll = (Double(base[il]) + Double(base[il + 1]) + Double(base[il + 2])) / 3.0
                                let lr = (Double(base[ir]) + Double(base[ir + 1]) + Double(base[ir + 2])) / 3.0
                                gSum += abs(lr - ll)
                                n += 1
                                y += stepY
                            }
                            let gMean = n > 0 ? gSum / Double(n) : 0.0
                            if gMean > bestGrad {
                                bestGrad = gMean
                                bestSeamX = x
                            }
                        }
                    }
                    // 継ぎ目上の細い黒仕切り線だけ回避
                    var newLx1 = bestSeamX
                    var newRx0 = bestSeamX
                    while newLx1 > cLx1 {
                        let st = analyzeVerticalCol(x: newLx1 - 1, yStart: yStart, yEnd: yEnd)
                        if cardLuma >= 115.0 && st.darkRatio >= 0.88 && st.std <= 16.0 && st.meanLuma <= 52.0 {
                            newLx1 -= 1
                        } else {
                            break
                        }
                    }
                    while newRx0 < cRx0 {
                        let st = analyzeVerticalCol(x: newRx0, yStart: yStart, yEnd: yEnd)
                        if cardLuma >= 115.0 && st.darkRatio >= 0.88 && st.std <= 16.0 && st.meanLuma <= 52.0 {
                            newRx0 += 1
                        } else {
                            break
                        }
                    }
                    if newLx1 > cLx1 && newLx1 - cLx0 >= 64 { cLx1 = newLx1 }
                    if newRx0 < cRx0 && cRx1 - newRx0 >= 64 { cRx0 = newRx0 }
                }
            }
        }
    }

    /// 画像枠の上下左右に存在する完全な黒余白（スキャン黒帯やレターボックス・ピラーボックス黒枠）を検出し、
    /// 左右写真ペアから余計な外周黒枠を均等にトリミングし、トリミングピクセル数を返す
    @discardableResult
    private static func trimOuterBlackBorders(
        leftRGB: inout [UInt8],
        rightRGB: inout [UInt8],
        leftAlpha: inout [UInt8],
        rightAlpha: inout [UInt8],
        width w: inout Int,
        height h: inout Int
    ) -> (top: Int, bottom: Int, left: Int, right: Int) {
        guard w >= 64, h >= 64, leftRGB.count >= w * h * 3, rightRGB.count >= w * h * 3 else {
            return (0, 0, 0, 0)
        }
        let hasAlpha = (leftAlpha.count >= w * h && rightAlpha.count >= w * h)
        let tol = 16.0
        let maxTrimX = max(4, Int(Double(w) * 0.15))
        let maxTrimY = max(4, Int(Double(h) * 0.15))

        func countBlackRowsTop(_ rgb: [UInt8]) -> Int {
            var trimmed = 0
            for y in 0..<maxTrimY {
                let rowOff = y * w * 3
                var blackCount = 0
                for x in 0..<w {
                    let i = rowOff + x * 3
                    let luma = (Double(rgb[i]) + Double(rgb[i + 1]) + Double(rgb[i + 2])) / 3.0
                    if luma <= tol { blackCount += 1 }
                }
                if Double(blackCount) / Double(w) >= 0.96 {
                    trimmed += 1
                } else {
                    break
                }
            }
            return trimmed
        }

        func countBlackRowsBottom(_ rgb: [UInt8]) -> Int {
            var trimmed = 0
            for dy in 0..<maxTrimY {
                let y = h - 1 - dy
                let rowOff = y * w * 3
                var blackCount = 0
                for x in 0..<w {
                    let i = rowOff + x * 3
                    let luma = (Double(rgb[i]) + Double(rgb[i + 1]) + Double(rgb[i + 2])) / 3.0
                    if luma <= tol { blackCount += 1 }
                }
                if Double(blackCount) / Double(w) >= 0.96 {
                    trimmed += 1
                } else {
                    break
                }
            }
            return trimmed
        }

        func countBlackColsLeft(_ rgb: [UInt8]) -> Int {
            var trimmed = 0
            for x in 0..<maxTrimX {
                var blackCount = 0
                for y in 0..<h {
                    let i = (y * w + x) * 3
                    let luma = (Double(rgb[i]) + Double(rgb[i + 1]) + Double(rgb[i + 2])) / 3.0
                    if luma <= tol { blackCount += 1 }
                }
                if Double(blackCount) / Double(h) >= 0.96 {
                    trimmed += 1
                } else {
                    break
                }
            }
            return trimmed
        }

        func countBlackColsRight(_ rgb: [UInt8]) -> Int {
            var trimmed = 0
            for dx in 0..<maxTrimX {
                let x = w - 1 - dx
                var blackCount = 0
                for y in 0..<h {
                    let i = (y * w + x) * 3
                    let luma = (Double(rgb[i]) + Double(rgb[i + 1]) + Double(rgb[i + 2])) / 3.0
                    if luma <= tol { blackCount += 1 }
                }
                if Double(blackCount) / Double(h) >= 0.96 {
                    trimmed += 1
                } else {
                    break
                }
            }
            return trimmed
        }

        let topL = countBlackRowsTop(leftRGB), topR = countBlackRowsTop(rightRGB)
        let botL = countBlackRowsBottom(leftRGB), botR = countBlackRowsBottom(rightRGB)
        let leftL = countBlackColsLeft(leftRGB), leftR = countBlackColsLeft(rightRGB)
        let rightL = countBlackColsRight(leftRGB), rightR = countBlackColsRight(rightRGB)

        let trimTop = min(topL, topR)
        let trimBot = min(botL, botR)
        let trimLeft = min(leftL, leftR)
        let trimRight = min(rightL, rightR)

        guard trimTop > 0 || trimBot > 0 || trimLeft > 0 || trimRight > 0 else { return (0, 0, 0, 0) }
        let newW = w - trimLeft - trimRight
        let newH = h - trimTop - trimBot
        guard newW >= 64, newH >= 64 else { return (0, 0, 0, 0) }

        var croppedL = [UInt8](repeating: 0, count: newW * newH * 3)
        var croppedR = [UInt8](repeating: 0, count: newW * newH * 3)
        for dy in 0..<newH {
            let srcY = trimTop + dy
            let srcRowOff = (srcY * w + trimLeft) * 3
            let dstRowOff = dy * newW * 3
            let byteCount = newW * 3
            croppedL[dstRowOff..<(dstRowOff + byteCount)] = leftRGB[srcRowOff..<(srcRowOff + byteCount)]
            croppedR[dstRowOff..<(dstRowOff + byteCount)] = rightRGB[srcRowOff..<(srcRowOff + byteCount)]
        }

        if hasAlpha {
            var croppedAL = [UInt8](repeating: 0, count: newW * newH)
            var croppedAR = [UInt8](repeating: 0, count: newW * newH)
            for dy in 0..<newH {
                let srcY = trimTop + dy
                let srcOff = srcY * w + trimLeft
                let dstOff = dy * newW
                croppedAL[dstOff..<(dstOff + newW)] = leftAlpha[srcOff..<(srcOff + newW)]
                croppedAR[dstOff..<(dstOff + newW)] = rightAlpha[srcOff..<(srcOff + newW)]
            }
            leftAlpha = croppedAL
            rightAlpha = croppedAR
        }

        leftRGB = croppedL
        rightRGB = croppedR
        w = newW
        h = newH
        return (trimTop, trimBot, trimLeft, trimRight)
    }

    /// 確定した切り出し枠 (centerX, centerY, boxWidth, boxHeight, angleRad) と実測 archParams に基づき、
    /// ワープ前元カード空間 (cardWidth × cardHeight) 上の滑らかな連続ソフト確率マップ (0.0...1.0) を生成する
    static func buildCardSpaceGeometricProbMask(
        cardWidth: Int,
        cardHeight: Int,
        centerX cx: Double,
        centerY cy: Double,
        boxWidth: Int,
        boxHeight: Int,
        angleRad theta: Double,
        archParams: ArchShapeParams
    ) -> [Float] {
        var prob = [Float](repeating: 0.0, count: max(0, cardWidth * cardHeight))
        guard cardWidth >= 16, cardHeight >= 16, boxWidth >= 16, boxHeight >= 16 else { return prob }

        let w = Double(boxWidth)
        let h = Double(boxHeight)
        let halfW = w * 0.5
        let halfH = h * 0.5
        let hasTopRound = (archParams.topRxRatio > 0.005 && archParams.topRyRatio > 0.005)
        let hasBotRound = (archParams.botRxRatio > 0.005 && archParams.botRyRatio > 0.005)
        let isFullTopArch = hasTopRound && archParams.topRxRatio >= 0.48
        let topRx = hasTopRound ? max(2.0, w * archParams.topRxRatio) : 0.0
        let topRy = hasTopRound ? max(2.0, h * archParams.topRyRatio) : 0.0
        let botRx = hasBotRound ? max(2.0, w * archParams.botRxRatio) : 0.0
        let botRy = hasBotRound ? max(2.0, h * archParams.botRyRatio) : 0.0

        let cosT = cos(theta)
        let sinT = sin(theta)
        let pad = 4.0
        let boundHalfW = abs(halfW * cosT) + abs(halfH * sinT) + pad
        let boundHalfH = abs(halfW * sinT) + abs(halfH * cosT) + pad
        let xMin = max(0, Int(floor(cx - boundHalfW)))
        let xMax = min(cardWidth - 1, Int(ceil(cx + boundHalfW)))
        let yMin = max(0, Int(floor(cy - boundHalfH)))
        let yMax = min(cardHeight - 1, Int(ceil(cy + boundHalfH)))
        guard xMax >= xMin, yMax >= yMin else { return prob }

        prob.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: yMax - yMin + 1) { dy in
                let y = yMin + dy
                let relY = (Double(y) + 0.5) - cy
                let rowOff = y * cardWidth
                for x in xMin...xMax {
                    let relX = (Double(x) + 0.5) - cx
                    // 回転クロップ座標系への逆射影 (rx, ry) ∈ [0, w] × [0, h]
                    let u = relX * cosT + relY * sinT
                    let v = -relX * sinT + relY * cosT
                    let px = u + halfW
                    let py = v + halfH

                    let d = signedArchShapeDistance(
                        px: px, py: py,
                        ax0: 0.0, ax1: w, ay0: 0.0, y1: h,
                        rxTop: topRx, ryTop: topRy, rxBot: botRx, ryBot: botRy,
                        hasTopRound: hasTopRound, hasBotRound: hasBotRound,
                        isFullTopArch: isFullTopArch, topArchExp: archParams.topArchExp
                    )
                    if d >= 2.5 {
                        base[rowOff + x] = 1.0
                    } else if d > -2.5 {
                        let t = (d + 2.5) / 5.0
                        base[rowOff + x] = Float(t * t * (3.0 - 2.0 * t))
                    }
                }
            }
        }
        return prob
    }

    /// 1ch アルファマスク (0..255) を `cropRotatedRGB` と完全同一座標でバイリニア回転クロップする
    static func cropRotatedMask8(
        _ src: [UInt8],
        srcW: Int,
        srcH: Int,
        centerX cx: Double,
        centerY cy: Double,
        width w: Int,
        height h: Int,
        angleRad theta: Double
    ) -> [UInt8] {
        guard srcW > 0, srcH > 0, src.count >= srcW * srcH else {
            return [UInt8](repeating: 255, count: max(0, w * h))
        }
        if abs(theta) < 0.002 {
            let x0 = max(0, min(srcW - w, Int(round(cx - Double(w) * 0.5))))
            let y0 = max(0, min(srcH - h, Int(round(cy - Double(h) * 0.5))))
            var out = [UInt8](repeating: 0, count: w * h)
            for row in 0..<h {
                let srcOff = (y0 + row) * srcW + x0
                let dstOff = row * w
                out[dstOff..<(dstOff + w)] = src[srcOff..<(srcOff + w)]
            }
            return out
        }

        var out = [UInt8](repeating: 0, count: w * h)
        let cosT = cos(theta)
        let sinT = sin(theta)
        let halfW = Double(w) * 0.5
        let halfH = Double(h) * 0.5
        src.withUnsafeBufferPointer { sPtr in
            out.withUnsafeMutableBufferPointer { dPtr in
                guard let s = sPtr.baseAddress, let d = dPtr.baseAddress else { return }
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let v = Double(y) - halfH
                    let dRow = y * w
                    for x in 0..<w {
                        let u = Double(x) - halfW
                        let sx = cx + u * cosT - v * sinT
                        let sy = cy + u * sinT + v * cosT
                        if sx >= 0 && sx < Double(srcW - 1) && sy >= 0 && sy < Double(srcH - 1) {
                            let x0 = Int(sx), x1 = x0 + 1
                            let y0 = Int(sy), y1 = y0 + 1
                            let ax = Float(sx - Double(x0))
                            let ay = Float(sy - Double(y0))
                            let v00 = Float(s[y0 * srcW + x0])
                            let v10 = Float(s[y0 * srcW + x1])
                            let v01 = Float(s[y1 * srcW + x0])
                            let v11 = Float(s[y1 * srcW + x1])
                            let val = (v00 * (1 - ax) + v10 * ax) * (1 - ay) + (v01 * (1 - ax) + v11 * ax) * ay
                            d[dRow + x] = UInt8(min(255, max(0, Int(val + 0.5))))
                        }
                    }
                }
            }
        }
        return out
    }

    /// マスク外側 (`alpha < 128`) の `radius` ピクセル帯を直近の有効写真画素 (`alpha >= 128`) 色で安全パディングする。
    /// Lanczos-3 ワープが境界付近をサンプリングしても元の台紙色が写真エッジに滲まないようにするための処理で、マスク内部画素は一切変更しない。
    static func extendBoundaryColorsOutsideMask(
        rgb: inout [UInt8],
        alpha: [UInt8],
        width w: Int,
        height h: Int,
        radius: Int = 5
    ) {
        guard w >= 4, h >= 4, rgb.count >= w * h * 3, alpha.count >= w * h, radius >= 1 else { return }
        var known = alpha.map { $0 >= 128 }
        var nextKnown = known
        var nextRGB = rgb
        let dx4 = [-1, 1, 0, 0, -1, 1, -1, 1]
        let dy4 = [0, 0, -1, 1, -1, -1, 1, 1]

        for _ in 0..<radius {
            var changed = false
            for y in 0..<h {
                let row = y * w
                for x in 0..<w {
                    let idx = row + x
                    guard !known[idx] else { continue }
                    var sumR = 0, sumG = 0, sumB = 0, cnt = 0
                    for k in 0..<8 {
                        let nx = x + dx4[k], ny = y + dy4[k]
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        let nIdx = ny * w + nx
                        if known[nIdx] {
                            let nOff = nIdx * 3
                            sumR += Int(rgb[nOff])
                            sumG += Int(rgb[nOff + 1])
                            sumB += Int(rgb[nOff + 2])
                            cnt += 1
                        }
                    }
                    if cnt > 0 {
                        let off = idx * 3
                        nextRGB[off] = UInt8(sumR / cnt)
                        nextRGB[off + 1] = UInt8(sumG / cnt)
                        nextRGB[off + 2] = UInt8(sumB / cnt)
                        nextKnown[idx] = true
                        changed = true
                    }
                }
            }
            if !changed { break }
            rgb = nextRGB
            known = nextKnown
        }
    }

    /// 1ch アルファマスクを黒背景に対して適用する (`.keepArchBlack` 用)
    static func applyAlphaMaskBlack(_ rgb: inout [UInt8], alpha: [UInt8], width w: Int, height h: Int) {
        let count = w * h
        guard rgb.count >= count * 3, alpha.count >= count else { return }
        rgb.withUnsafeMutableBufferPointer { rPtr in
            alpha.withUnsafeBufferPointer { aPtr in
                guard let rp = rPtr.baseAddress, let ap = aPtr.baseAddress else { return }
                for i in 0..<count {
                    let a = Int(ap[i])
                    if a >= 255 { continue }
                    let off = i * 3
                    if a <= 0 {
                        rp[off] = 0; rp[off + 1] = 0; rp[off + 2] = 0
                    } else {
                        rp[off]     = UInt8((Int(rp[off])     * a + 127) / 255)
                        rp[off + 1] = UInt8((Int(rp[off + 1]) * a + 127) / 255)
                        rp[off + 2] = UInt8((Int(rp[off + 2]) * a + 127) / 255)
                    }
                }
            }
        }
    }

    /// 写真枠の上下外側の台紙帯（スキャナ黒・白余白を除く）から 3 チャンネル台紙 RGB カラーをサンプリングする
    private static func sampleLocalCardRGB(
        rgb: [UInt8],
        srcW: Int,
        srcH: Int,
        yTop: Int,
        yBot: Int,
        xLeft: Int? = nil,
        xRight: Int? = nil,
        fallbackLuma: Double?
    ) -> (r: Double, g: Double, b: Double)? {
        guard srcW >= 32, srcH >= 32, rgb.count >= srcW * srcH * 3 else {
            return fallbackLuma.map { ($0, $0, $0) }
        }

        // 1. 外周 4 辺から均一なスキャナ余白（白・黒バック）を検出し、実カード範囲 [cardX0..<cardX1, cardY0..<cardY1] を特定
        var cardX0 = 0
        var cardX1 = srcW
        var cardY0 = 0
        var cardY1 = srcH

        rgb.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }

            func rowMeanAndStd(_ y: Int, xStart: Int, xEnd: Int) -> (r: Double, g: Double, b: Double, std: Double) {
                let step = max(1, (xEnd - xStart) / 48)
                var sr = 0.0, sg = 0.0, sb = 0.0, slSq = 0.0
                var n = 0
                var x = xStart
                while x < xEnd {
                    let i = (y * srcW + x) * 3
                    let r = Double(base[i]), g = Double(base[i + 1]), b = Double(base[i + 2])
                    sr += r; sg += g; sb += b
                    let l = (r + g + b) / 3.0
                    slSq += l * l
                    n += 1
                    x += step
                }
                guard n > 0 else { return (0, 0, 0, 255) }
                let mr = sr / Double(n), mg = sg / Double(n), mb = sb / Double(n)
                let ml = (mr + mg + mb) / 3.0
                return (mr, mg, mb, sqrt(max(0.0, slSq / Double(n) - ml * ml)))
            }

            func colMeanAndStd(_ x: Int, yStart: Int, yEnd: Int) -> (r: Double, g: Double, b: Double, std: Double) {
                let step = max(1, (yEnd - yStart) / 48)
                var sr = 0.0, sg = 0.0, sb = 0.0, slSq = 0.0
                var n = 0
                var y = yStart
                while y < yEnd {
                    let i = (y * srcW + x) * 3
                    let r = Double(base[i]), g = Double(base[i + 1]), b = Double(base[i + 2])
                    sr += r; sg += g; sb += b
                    let l = (r + g + b) / 3.0
                    slSq += l * l
                    n += 1
                    y += step
                }
                guard n > 0 else { return (0, 0, 0, 255) }
                let mr = sr / Double(n), mg = sg / Double(n), mb = sb / Double(n)
                let ml = (mr + mg + mb) / 3.0
                return (mr, mg, mb, sqrt(max(0.0, slSq / Double(n) - ml * ml)))
            }

            let maxMarginY = min(srcH / 5, max(8, Int(Double(srcH) * 0.18)))
            let maxMarginX = min(srcW / 5, max(8, Int(Double(srcW) * 0.18)))
            let midX0 = srcW / 4, midX1 = srcW * 3 / 4
            let midY0 = srcH / 4, midY1 = srcH * 3 / 4

            // スキャナのドロップシャドウ勾配を飛び越えてカード本体平坦面へ着地するヘルパー
            func findStableCardBoundary(
                limit: Int,
                ref: (r: Double, g: Double, b: Double, std: Double),
                measure: (Int) -> (r: Double, g: Double, b: Double, std: Double)
            ) -> Int? {
                var jumpIdx: Int? = nil
                for d in 2..<limit {
                    let st = measure(d)
                    let diff = max(abs(st.r - ref.r), max(abs(st.g - ref.g), abs(st.b - ref.b)))
                    if diff >= 18.0 || st.std > 18.0 {
                        jumpIdx = d
                        break
                    }
                }
                guard let start = jumpIdx else { return nil }
                // シャドウの斜面を通過し、隣接2ステップの輝度変化が <= 4.0 かつ標準偏差 <= 16.0 の平坦面に到達した先を選ぶ
                var prevL = { let s = measure(start); return (s.r + s.g + s.b) / 3.0 }()
                let searchEnd = min(limit, start + 22)
                var stableStreak = 0
                for d in (start + 1)..<searchEnd {
                    let st = measure(d)
                    let curL = (st.r + st.g + st.b) / 3.0
                    let diffFromRef = max(abs(st.r - ref.r), max(abs(st.g - ref.g), abs(st.b - ref.b)))
                    if abs(curL - prevL) <= 4.0 && st.std <= 16.0 && diffFromRef >= 24.0 {
                        stableStreak += 1
                        if stableStreak >= 2 {
                            return d + 2
                        }
                    } else {
                        stableStreak = 0
                    }
                    prevL = curL
                }
                return min(limit - 1, start + 8)
            }

            // 上スキャナ余白
            let topRef = rowMeanAndStd(1, xStart: midX0, xEnd: midX1)
            let topRefL = (topRef.r + topRef.g + topRef.b) / 3.0
            if topRef.std <= 14.0 && (topRefL >= 218.0 || topRefL <= 35.0) {
                if let y = findStableCardBoundary(limit: maxMarginY, ref: topRef, measure: { rowMeanAndStd($0, xStart: midX0, xEnd: midX1) }) {
                    cardY0 = min(srcH / 4, y)
                }
            }
            // 下スキャナ余白
            let botRef = rowMeanAndStd(srcH - 2, xStart: midX0, xEnd: midX1)
            let botRefL = (botRef.r + botRef.g + botRef.b) / 3.0
            if botRef.std <= 14.0 && (botRefL >= 218.0 || botRefL <= 35.0) {
                if let dy = findStableCardBoundary(limit: maxMarginY, ref: botRef, measure: { rowMeanAndStd(srcH - 1 - $0, xStart: midX0, xEnd: midX1) }) {
                    cardY1 = max(srcH * 3 / 4, srcH - 1 - dy)
                }
            }
            // 左スキャナ余白
            let leftRef = colMeanAndStd(1, yStart: midY0, yEnd: midY1)
            let leftRefL = (leftRef.r + leftRef.g + leftRef.b) / 3.0
            if leftRef.std <= 14.0 && (leftRefL >= 218.0 || leftRefL <= 35.0) {
                if let x = findStableCardBoundary(limit: maxMarginX, ref: leftRef, measure: { colMeanAndStd($0, yStart: midY0, yEnd: midY1) }) {
                    cardX0 = min(srcW / 4, x)
                }
            }
            // 右スキャナ余白
            let rightRef = colMeanAndStd(srcW - 2, yStart: midY0, yEnd: midY1)
            let rightRefL = (rightRef.r + rightRef.g + rightRef.b) / 3.0
            if rightRef.std <= 14.0 && (rightRefL >= 218.0 || rightRefL <= 35.0) {
                if let dx = findStableCardBoundary(limit: maxMarginX, ref: rightRef, measure: { colMeanAndStd(srcW - 1 - $0, yStart: midY0, yEnd: midY1) }) {
                    cardX1 = max(srcW * 3 / 4, srcW - 1 - dx)
                }
            }
        }

        // 2. 実カード枠内側かつ写真窓外側の余白（上・下・左右）から低勾配（平坦領域）の RGB サンプルを収集
        var samples: [(r: Double, g: Double, b: Double)] = []
        samples.reserveCapacity(1024)

        rgb.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            let cardW = max(32, cardX1 - cardX0)
            let cardH = max(32, cardY1 - cardY0)
            let sx0 = max(cardX0 + 4, cardX0 + cardW / 5)
            let sx1 = min(cardX1 - 4, cardX1 - cardW / 5)
            let xStep = max(1, (sx1 - sx0) / 48)

            func collectPoint(_ x: Int, _ y: Int, requireFlat: Bool = true) {
                guard x >= 2, x < srcW - 2, y >= 2, y < srcH - 2 else { return }
                let i = (y * srcW + x) * 3
                let r = Double(base[i]), g = Double(base[i + 1]), b = Double(base[i + 2])
                let luma = (r + g + b) / 3.0
                guard luma > 18.0 && luma < 244.0 else { return }
                if requireFlat {
                    let iR = (y * srcW + (x + 2)) * 3
                    let iD = ((y + 2) * srcW + x) * 3
                    let lR = (Double(base[iR]) + Double(base[iR + 1]) + Double(base[iR + 2])) / 3.0
                    let lD = (Double(base[iD]) + Double(base[iD + 1]) + Double(base[iD + 2])) / 3.0
                    if abs(luma - lR) > 7.0 || abs(luma - lD) > 7.0 { return }
                }
                samples.append((r, g, b))
            }

            // 1. 下マージン（カード内 yBot より下）からサンプル収集
            let botLo = min(cardY1 - 1, max(cardY0, yBot + 2))
            let botHi = min(cardY1 - 1, max(botLo, yBot + 36))
            if botHi > botLo && sx1 > sx0 {
                let yStep = max(1, (botHi - botLo) / 12)
                var y = botLo
                while y < botHi {
                    var x = sx0
                    while x < sx1 { collectPoint(x, y); x += xStep }
                    y += yStep
                }
            }

            // 2. 左右マージン（面積広く安定しているため密にサンプル収集）
            let my0 = cardY0 + cardH / 5
            let my1 = cardY1 - cardH / 5
            let yStep = max(1, (my1 - my0) / 48)
            if let xL = xLeft, xL > cardX0 + 4 {
                let lxEnd = max(cardX0 + 2, xL - 2)
                let lxStep = max(1, (lxEnd - cardX0) / 20)
                var y = my0
                while y < my1 {
                    var x = cardX0
                    while x < lxEnd { collectPoint(x, y); x += lxStep }
                    y += yStep
                }
            }
            if let xR = xRight, cardX1 > xR + 4 {
                let rxStart = min(cardX1 - 2, xR + 2)
                let rxStep = max(1, (cardX1 - rxStart) / 20)
                var y = my0
                while y < my1 {
                    var x = rxStart
                    while x < cardX1 { collectPoint(x, y); x += rxStep }
                    y += yStep
                }
            }

            // 3. 上マージン（カード内 yTop より上）
            // 注意: 空や天井などの誤サンプリング防止
            // 下部または左右マージンからサンプルが得られている場合は、その平均色と整合する場合のみ上部を採用。
            // 下部・左右マージンから十分なサンプルが得られていない場合、上マージンが明色（luma >= 165.0）なら空とみなして採用しない。
            let topLo = max(cardY0, min(yTop - 2, yTop - 22))
            let topHi = max(topLo, min(srcH - 2, yTop - 2))
            if topHi > topLo && sx1 > sx0 {
                var topSamples: [(r: Double, g: Double, b: Double)] = []
                let yStep = max(1, (topHi - topLo) / 10)
                var y = topLo
                while y < topHi {
                    var x = sx0
                    while x < sx1 {
                        if x >= 2, x < srcW - 2, y >= 2, y < srcH - 2 {
                            let i = (y * srcW + x) * 3
                            let r = Double(base[i]), g = Double(base[i + 1]), b = Double(base[i + 2])
                            let luma = (r + g + b) / 3.0
                            if luma > 18.0 && luma < 244.0 {
                                let iR = (y * srcW + (x + 2)) * 3
                                let iD = ((y + 2) * srcW + x) * 3
                                let lR = (Double(base[iR]) + Double(base[iR + 1]) + Double(base[iR + 2])) / 3.0
                                let lD = (Double(base[iD]) + Double(base[iD + 1]) + Double(base[iD + 2])) / 3.0
                                if abs(luma - lR) <= 7.0 && abs(luma - lD) <= 7.0 {
                                    topSamples.append((r, g, b))
                                }
                            }
                        }
                        x += xStep
                    }
                    y += yStep
                }

                if !topSamples.isEmpty {
                    let topMeanLuma = topSamples.reduce(0.0) { $0 + ($1.r + $1.g + $1.b) / 3.0 } / Double(topSamples.count)
                    if samples.count >= 16 {
                        let baseMeanR = samples.reduce(0.0) { $0 + $1.r } / Double(samples.count)
                        let baseMeanG = samples.reduce(0.0) { $0 + $1.g } / Double(samples.count)
                        let baseMeanB = samples.reduce(0.0) { $0 + $1.b } / Double(samples.count)
                        let baseMeanLuma = (baseMeanR + baseMeanG + baseMeanB) / 3.0
                        if abs(topMeanLuma - baseMeanLuma) <= 32.0 {
                            samples.append(contentsOf: topSamples)
                        }
                    } else if topMeanLuma < 165.0 {
                        samples.append(contentsOf: topSamples)
                    }
                }
            }

            // 第2段フォールバック（02_white_columns 等のカード外枠が写真ボックスに含まれており外側マージンが狭い場合）
            // ボックス4辺最外周 3.5% 以内の低勾配平坦面から台紙色を直接抽出（無彩色 fallbackLuma 返却を回避）
            if samples.count < 24 {
                let fb = fallbackLuma
                func collectBorderFlat(_ x: Int, _ y: Int) {
                    guard x >= 2, x < srcW - 2, y >= 2, y < srcH - 2 else { return }
                    let i = (y * srcW + x) * 3
                    let r = Double(base[i]), g = Double(base[i + 1]), b = Double(base[i + 2])
                    let luma = (r + g + b) / 3.0
                    guard luma > 20.0 && luma < 242.0 else { return }
                    if let fb, abs(luma - fb) > 42.0 { return }
                    let iR = (y * srcW + (x + 2)) * 3
                    let iD = ((y + 2) * srcW + x) * 3
                    let lR = (Double(base[iR]) + Double(base[iR + 1]) + Double(base[iR + 2])) / 3.0
                    let lD = (Double(base[iD]) + Double(base[iD + 1]) + Double(base[iD + 2])) / 3.0
                    if abs(luma - lR) <= 4.0 && abs(luma - lD) <= 4.0 {
                        samples.append((r, g, b))
                    }
                }
                let bandY = max(6, min(20, (yBot - yTop) / 24))
                let bandX = max(6, min(24, cardW / 32))
                let topY0 = max(cardY0, yTop), topY1 = min(cardY1, yTop + bandY)
                if topY0 < topY1 {
                    for y in topY0..<topY1 {
                        var x = sx0
                        while x < sx1 { collectBorderFlat(x, y); x += xStep }
                    }
                }
                let botY0 = max(cardY0, yBot - bandY), botY1 = min(cardY1, yBot)
                if botY0 < botY1 {
                    for y in botY0..<botY1 {
                        var x = sx0
                        while x < sx1 { collectBorderFlat(x, y); x += xStep }
                    }
                }
                if let xL = xLeft {
                    let leftX0 = max(cardX0, xL), leftX1 = min(cardX1, xL + bandX)
                    if leftX0 < leftX1 {
                        for x in leftX0..<leftX1 {
                            var y = my0
                            while y < my1 { collectBorderFlat(x, y); y += yStep }
                        }
                    }
                }
                if let xR = xRight {
                    let rightX0 = max(cardX0, xR - bandX), rightX1 = min(cardX1, xR)
                    if rightX0 < rightX1 {
                        for x in rightX0..<rightX1 {
                            var y = my0
                            while y < my1 { collectBorderFlat(x, y); y += yStep }
                        }
                    }
                }
            }
        }

        guard samples.count >= 16 else {
            return fallbackLuma.map { ($0, $0, $0) }
        }

        // 3. 量子化RGBヒストグラムの最頻クラスタ（±1ビン）から代表色を取り、文字インク・黒枠・傷ノイズを排除
        var counts: [Int: Int] = [:]
        counts.reserveCapacity(128)
        for s in samples {
            let kr = min(31, Int(s.r) / 8)
            let kg = min(31, Int(s.g) / 8)
            let kb = min(31, Int(s.b) / 8)
            let key = (kr << 10) | (kg << 5) | kb
            counts[key, default: 0] += 1
        }
        guard let (peakKey, _) = counts.max(by: { $0.value < $1.value }) else {
            return fallbackLuma.map { ($0, $0, $0) }
        }
        let pr = (peakKey >> 10) & 31
        let pg = (peakKey >> 5) & 31
        let pb = peakKey & 31

        var crs: [Double] = []
        var cgs: [Double] = []
        var cbs: [Double] = []
        for s in samples {
            let kr = min(31, Int(s.r) / 8)
            let kg = min(31, Int(s.g) / 8)
            let kb = min(31, Int(s.b) / 8)
            if abs(kr - pr) <= 1 && abs(kg - pg) <= 1 && abs(kb - pb) <= 1 {
                crs.append(s.r); cgs.append(s.g); cbs.append(s.b)
            }
        }
        if crs.count < 8 {
            crs = samples.map(\.r)
            cgs = samples.map(\.g)
            cbs = samples.map(\.b)
        }
        crs.sort(); cgs.sort(); cbs.sort()
        let mid = crs.count / 2
        return (crs[mid], cgs[mid], cbs[mid])
    }

    /// パラメトリック角丸アーチ SDF マスクをフル解像度で滑らかに適用（ジャギーゼロ・白フリンジ除去）
    /// 上部アーチ（topRxRatio >= 0.45）または楕円角丸・下部角丸の矩形領域からの符号付き法線距離（内側が正 [px]）
    static func signedArchShapeDistance(
        px: Double,
        py: Double,
        ax0: Double,
        ax1: Double,
        ay0: Double,
        y1: Double,
        rxTop: Double,
        ryTop: Double,
        rxBot: Double,
        ryBot: Double,
        hasTopRound: Bool,
        hasBotRound: Bool,
        isFullTopArch: Bool,
        topArchExp: Double
    ) -> Double {
        var d = min(min(px - ax0, ax1 - px), min(py - ay0, y1 - py))
        if d > -1.5 {
            if hasTopRound && py < ay0 + ryTop {
                if isFullTopArch {
                    let halfW = max(4.0, (ax1 - ax0) * 0.5)
                    let midX = (ax0 + ax1) * 0.5
                    let a = abs(px - midX) / halfW
                    let b = max(0.0, (ay0 + ryTop - py) / max(1.0, ryTop))
                    if b > 0.0 {
                        // 指数 q < 2.0 による尖頭化（とんがりすぎ）を防止し、自然な半円〜扁平ドーム（2.0〜3.5）を保証
                        let q = max(2.0, min(3.5, topArchExp))
                        let g = pow(a, q) + b * b - 1.0
                        let dgdx = (a > 1e-6) ? (q * pow(a, q - 1.0) / halfW) : 0.0
                        let dgdy = 2.0 * b / max(1.0, ryTop)
                        let grad = max(1e-6, hypot(dgdx, dgdy))
                        d = min(d, -g / grad)
                    }
                } else {
                    let topScale = min(rxTop, ryTop)
                    if px < ax0 + rxTop {
                        let nx = (ax0 + rxTop - px) / rxTop
                        let ny = (ay0 + ryTop - py) / ryTop
                        let dCorner = (1.0 - hypot(nx, ny)) * topScale
                        d = min(d, dCorner)
                    } else if px > ax1 - rxTop {
                        let nx = (px - (ax1 - rxTop)) / rxTop
                        let ny = (ay0 + ryTop - py) / ryTop
                        let dCorner = (1.0 - hypot(nx, ny)) * topScale
                        d = min(d, dCorner)
                    }
                }
            } else if hasBotRound && py > y1 - ryBot {
                let botScale = min(rxBot, ryBot)
                if px < ax0 + rxBot {
                    let nx = (ax0 + rxBot - px) / rxBot
                    let ny = (py - (y1 - ryBot)) / ryBot
                    let dCorner = (1.0 - hypot(nx, ny)) * botScale
                    d = min(d, dCorner)
                } else if px > ax1 - rxBot {
                    let nx = (px - (ax1 - rxBot)) / rxBot
                    let ny = (py - (y1 - ryBot)) / ryBot
                    let dCorner = (1.0 - hypot(nx, ny)) * botScale
                    d = min(d, dCorner)
                }
            }
        }
        return d
    }

    static func applyParametricArchMask(
        _ rgb: inout [UInt8],
        width w: Int,
        height h: Int,
        params: ArchShapeParams,
        extraInsetRatio: Double = 0.015,
        archInnerOffsetPx: Double = 2.0,
        edgeInsets: (top: Int, bottom: Int, left: Int, right: Int) = (0, 0, 0, 0)
    ) {
        guard w >= 16, h >= 16, rgb.count >= w * h * 3 else { return }
        let fw = Double(w)
        let fh = Double(h)

        let hasTopRound = (params.topRxRatio > 0.005 && params.topRyRatio > 0.005)
        let hasBotRound = (params.botRxRatio > 0.005 && params.botRyRatio > 0.005)
        let isFullTopArch = hasTopRound && params.topRxRatio >= 0.48

        let insetX = fw * max(0.0, extraInsetRatio)
        let insetYTop = fh * max(0.0, extraInsetRatio)
        // 下端に角丸がない場合でも、最外周の微小な台紙フリンジ・平行化回転誤差を除去するため極小インセットを適用
        let insetYBot = hasBotRound ? (fh * max(0.0, extraInsetRatio)) : max(1.5, fh * max(0.0, extraInsetRatio * 0.5))

        let x0 = insetX + Double(edgeInsets.left)
        let x1 = fw - insetX - Double(edgeInsets.right)
        let y0 = insetYTop + Double(edgeInsets.top)
        let y1 = fh - insetYBot - Double(edgeInsets.bottom)
        let innerW = max(8.0, x1 - x0)
        let innerH = max(8.0, y1 - y0)

        let archOff = hasTopRound ? max(0.0, archInnerOffsetPx) : 0.0
        let ax0 = x0 + archOff
        let ax1 = x1 - archOff
        let ay0 = y0 + archOff

        let rxTop = hasTopRound ? max(2.0, innerW * params.topRxRatio) : 0.0
        let ryTop = hasTopRound ? max(2.0, innerH * params.topRyRatio) : 0.0
        let rxBot = hasBotRound ? max(2.0, innerW * params.botRxRatio) : 0.0
        let ryBot = hasBotRound ? max(2.0, innerH * params.botRyRatio) : 0.0

        let safeY0 = Int(ceil(ay0 + ryTop + 2.5))
        let safeY1 = Int(floor(y1 - ryBot - 2.5))
        let safeX0 = Int(ceil(ax0 + 2.5))
        let safeX1 = Int(floor(ax1 - 2.5))

        rgb.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for y in 0..<h {
                let py = Double(y) + 0.5
                let dTop = py - ay0
                let dBot = y1 - py
                let dY = min(dTop, dBot)
                let rowOff = y * w * 3

                // 上下とも完全に外側の行は一括で黒塗り
                if dY <= -1.5 {
                    for i in rowOff..<(rowOff + w * 3) { base[i] = 0 }
                    continue
                }

                let isSafeMiddleRow = (y >= safeY0 && y < safeY1)

                for x in 0..<w {
                    if isSafeMiddleRow && x >= safeX0 && x < safeX1 {
                        continue
                    }
                    let px = Double(x) + 0.5
                    let d = signedArchShapeDistance(
                        px: px, py: py,
                        ax0: ax0, ax1: ax1, ay0: ay0, y1: y1,
                        rxTop: rxTop, ryTop: ryTop, rxBot: rxBot, ryBot: ryBot,
                        hasTopRound: hasTopRound, hasBotRound: hasBotRound,
                        isFullTopArch: isFullTopArch, topArchExp: params.topArchExp
                    )

                    if d <= -1.2 {
                        let idx = rowOff + x * 3
                        base[idx] = 0; base[idx + 1] = 0; base[idx + 2] = 0
                    } else if d < 1.2 {
                        let t = (d + 1.2) / 2.4
                        let alpha = t * t * (3.0 - 2.0 * t)
                        let idx = rowOff + x * 3
                        base[idx]     = UInt8(Double(base[idx])     * alpha)
                        base[idx + 1] = UInt8(Double(base[idx + 1]) * alpha)
                        base[idx + 2] = UInt8(Double(base[idx + 2]) * alpha)
                    }
                }
            }
        }
    }

    /// 平行化後の左右画像に共通アーチマスクを適用する。
    /// 射影変換で窓の外側（台紙帯の細い楔）が上下左右の縁に入り込んだ場合は、
    /// 台紙輝度に一致する画素が多い縁の行・列を検出し、左右の最大値だけマスクを内側へ寄せる。
    static func applyArchMaskPair(
        _ left: inout [UInt8],
        _ right: inout [UInt8],
        width w: Int,
        height h: Int,
        params: ArchShapeParams,
        extraInsetRatio: Double,
        cardLuma: Double?
    ) {
        var insets = (top: 0, bottom: 0, left: 0, right: 0)
        if let card = cardLuma, card >= 85.0, w >= 64, h >= 64 {
            let a = residualBorderInsets(left, width: w, height: h, cardLuma: card)
            let b = residualBorderInsets(right, width: w, height: h, cardLuma: card)
            // 下端（bottom）の微小クロップ漏れ・平行化楔によるアナグリフ横線を除去
            // （足先や車輪の過度な切り上げを防ぐため最大でも 4px / 0.8% に制限）
            let safeBottom = min(max(4, Int(Double(h) * 0.008)), max(a.bottom, b.bottom))
            insets = (max(a.top, b.top), safeBottom, max(a.left, b.left), max(a.right, b.right))
        }
        applyParametricArchMask(&left, width: w, height: h, params: params, extraInsetRatio: extraInsetRatio, edgeInsets: insets)
        applyParametricArchMask(&right, width: w, height: h, params: params, extraInsetRatio: extraInsetRatio, edgeInsets: insets)
    }

    /// 縁から最大 3% の範囲で「台紙色の画素が 20% 以上ある行・列」を探し、その最深位置 +2px を返す。
    /// 写真本体に到達した（台紙色画素 5% 未満が 3 行連続）時点で探索を打ち切る。
    static func residualBorderInsets(
        _ rgb: [UInt8], width w: Int, height h: Int, cardLuma: Double
    ) -> (top: Int, bottom: Int, left: Int, right: Int) {
        guard rgb.count >= w * h * 3 else { return (0, 0, 0, 0) }
        let tol = 18.0
        func luma(_ x: Int, _ y: Int) -> Double {
            let i = (y * w + x) * 3
            return (Double(rgb[i]) + Double(rgb[i + 1]) + Double(rgb[i + 2])) / 3.0
        }
        // line: 縁からの距離 d に対し、走査線上の (台紙色比率, 非黒画素数) を返す
        func scan(maxDepth: Int, line: (Int) -> (card: Double, valid: Int)) -> Int {
            var deepest = -1
            var clearRun = 0
            for d in 0..<maxDepth {
                let r = line(d)
                if r.valid < 8 { continue } // 平行化で生じた黒の余白はマスクで消えるため無視
                if r.card >= 0.20 {
                    deepest = d
                    clearRun = 0
                } else if r.card < 0.05 {
                    clearRun += 1
                    if clearRun >= 3 { break }
                }
            }
            return deepest >= 0 ? deepest + 3 : 0
        }
        func row(_ y: Int) -> (card: Double, valid: Int) {
            let xs = w / 10, xe = w - w / 10
            let step = max(1, (xe - xs) / 160)
            var n = 0, c = 0
            var x = xs
            while x < xe {
                let v = luma(x, y)
                if v > 8 {
                    n += 1
                    if abs(v - cardLuma) <= tol { c += 1 }
                }
                x += step
            }
            return (n > 0 ? Double(c) / Double(n) : 0, n)
        }
        func col(_ x: Int) -> (card: Double, valid: Int) {
            let ys = h / 10, ye = h - h / 10
            let step = max(1, (ye - ys) / 160)
            var n = 0, c = 0
            var y = ys
            while y < ye {
                let v = luma(x, y)
                if v > 8 {
                    n += 1
                    if abs(v - cardLuma) <= tol { c += 1 }
                }
                y += step
            }
            return (n > 0 ? Double(c) / Double(n) : 0, n)
        }
        let maxY = max(4, Int(Double(h) * 0.03))
        let maxX = max(4, Int(Double(w) * 0.03))
        let top = scan(maxDepth: maxY) { row($0) }
        let bottom = scan(maxDepth: maxY) { row(h - 1 - $0) }
        let left = scan(maxDepth: maxX) { col($0) }
        let right = scan(maxDepth: maxX) { col(w - 1 - $0) }
        return (top, bottom, left, right)
    }

    private func largestConnectedComponent(_ mask: [Bool], w: Int, h: Int) -> [Bool] {
        let count = w * h
        var visited = [Bool](repeating: false, count: count)
        var bestComponent: [Int] = []
        var queue: [Int] = []
        queue.reserveCapacity(4096)

        for start in 0..<count where mask[start] && !visited[start] {
            visited[start] = true
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var head = 0
            while head < queue.count {
                let cur = queue[head]
                head += 1
                let cx = cur % w
                let cy = cur / w
                if cx > 0 {
                    let n = cur - 1
                    if mask[n] && !visited[n] { visited[n] = true; queue.append(n) }
                }
                if cx + 1 < w {
                    let n = cur + 1
                    if mask[n] && !visited[n] { visited[n] = true; queue.append(n) }
                }
                if cy > 0 {
                    let n = cur - w
                    if mask[n] && !visited[n] { visited[n] = true; queue.append(n) }
                }
                if cy + 1 < h {
                    let n = cur + w
                    if mask[n] && !visited[n] { visited[n] = true; queue.append(n) }
                }
            }
            if queue.count > bestComponent.count {
                bestComponent = queue
            }
        }

        var out = [Bool](repeating: false, count: count)
        for idx in bestComponent {
            out[idx] = true
        }
        return out
    }

    private func boundingBox(mask: [Bool], w: Int, h: Int) -> IntBox? {
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX > minX + 8, maxY > minY + 8 else { return nil }
        return IntBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private func largestInscribedRect(mask: [Bool], w: Int, h: Int) -> IntBox? {
        var heights = [Int](repeating: 0, count: w)
        var bestArea = 0
        var best: IntBox? = nil
        var stack: [Int] = []
        stack.reserveCapacity(w)

        for y in 0..<h {
            for x in 0..<w {
                heights[x] = mask[y * w + x] ? (heights[x] + 1) : 0
            }
            stack.removeAll(keepingCapacity: true)
            for x in 0...w {
                let curH = (x == w) ? 0 : heights[x]
                while let top = stack.last, heights[top] > curH {
                    stack.removeLast()
                    let rectH = heights[top]
                    let leftBound = stack.last.map { $0 + 1 } ?? 0
                    let rectW = x - leftBound
                    let area = rectW * rectH
                    if area > bestArea {
                        bestArea = area
                        best = IntBox(minX: leftBound, minY: y - rectH + 1, maxX: x, maxY: y + 1)
                    }
                }
                stack.append(x)
            }
        }
        return best
    }

    private func applyProbMask(
        _ rgb: inout [UInt8],
        w: Int,
        h: Int,
        cropX: Int,
        cropY: Int,
        srcW: Int,
        srcH: Int,
        probMap: [Float],
        mw: Int,
        mh: Int
    ) {
        let sxScale = Float(mw) / Float(srcW)
        let syScale = Float(mh) / Float(srcH)

        rgb.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for y in 0..<h {
                let fy = min(Float(mh - 1), max(0, (Float(cropY + y) + 0.5) * syScale - 0.5))
                let y0 = Int(fy), y1 = min(mh - 1, y0 + 1)
                let ay = fy - Float(y0)
                let rowOff = y * w * 3
                for x in 0..<w {
                    let fx = min(Float(mw - 1), max(0, (Float(cropX + x) + 0.5) * sxScale - 0.5))
                    let x0 = Int(fx), x1 = min(mw - 1, x0 + 1)
                    let ax = fx - Float(x0)

                    let p = probMap[y0 * mw + x0] * (1 - ax) * (1 - ay)
                          + probMap[y0 * mw + x1] * ax * (1 - ay)
                          + probMap[y1 * mw + x0] * (1 - ax) * ay
                          + probMap[y1 * mw + x1] * ax * ay

                    // 確率 0.35〜0.65 の間を滑らかにフェード
                    let alpha = min(1.0, max(0.0, (p - 0.35) / 0.30))
                    if alpha < 0.999 {
                        let idx = rowOff + x * 3
                        base[idx]     = UInt8(Float(base[idx])     * alpha)
                        base[idx + 1] = UInt8(Float(base[idx + 1]) * alpha)
                        base[idx + 2] = UInt8(Float(base[idx + 2]) * alpha)
                    }
                }
            }
        }
    }

    /// マスクの下辺（Bottom edge）から写真の傾き角（ラジアン）をロバストに推定する
    private static func estimateSkewAngle(
        maskL: [Bool], boxL: IntBox,
        maskR: [Bool], boxR: IntBox,
        w mw: Int, h mh: Int
    ) -> Double {
        func lineSlope(mask: [Bool], box: IntBox) -> (slope: Double, confidence: Double)? {
            let bw = box.maxX - box.minX + 1
            let bh = box.maxY - box.minY + 1
            guard bw >= 32, bh >= 32 else { return nil }
            let x0 = box.minX + Int(Double(bw) * 0.20)
            let x1 = box.maxX - Int(Double(bw) * 0.20)
            guard x1 > x0 + 16 else { return nil }

            var points: [(x: Double, y: Double)] = []
            points.reserveCapacity(x1 - x0)
            let yMinScan = max(0, box.maxY - Int(Double(bh) * 0.25))
            for x in x0..<x1 {
                for y in stride(from: box.maxY, through: yMinScan, by: -1) {
                    if mask[y * mw + x] {
                        points.append((Double(x), Double(y)))
                        break
                    }
                }
            }
            guard points.count >= 16 else { return nil }

            let n = Double(points.count)
            let sumX = points.reduce(0.0) { $0 + $1.x }
            let sumY = points.reduce(0.0) { $0 + $1.y }
            let meanX = sumX / n
            let meanY = sumY / n
            var num = 0.0, den = 0.0
            for p in points {
                num += (p.x - meanX) * (p.y - meanY)
                den += (p.x - meanX) * (p.x - meanX)
            }
            guard den > 1e-6 else { return nil }
            let slope = num / den

            var resSumSq = 0.0
            for p in points {
                let err = (p.y - meanY) - slope * (p.x - meanX)
                resSumSq += err * err
            }
            let resStd = sqrt(resSumSq / n)
            let confidence = max(0.0, 1.0 - resStd / 3.0)
            return (slope, confidence)
        }

        let fitL = lineSlope(mask: maskL, box: boxL)
        let fitR = lineSlope(mask: maskR, box: boxR)

        // 左右両眼の写真下辺が十分な直線性を持ち、かつ互いに傾きが整合一致（差 <= 0.025 ≈ 1.4°）するときのみ傾きを採用
        guard let l = fitL, let r = fitR,
              l.confidence >= 0.35, r.confidence >= 0.35,
              abs(l.slope - r.slope) <= 0.025 else {
            return 0.0
        }
        let slope = (l.slope + r.slope) * 0.5

        let angle = atan(slope)
        let deg = abs(angle * 180.0 / .pi)
        if deg >= 0.15 && deg <= 3.5 {
            return angle
        }
        return 0.0
    }

    /// 指定された中心 (cx, cy) と回転角 theta (ラジアン) で、高精度バイリニア補間により切り出す
    func cropRotatedRGB(
        _ src: [UInt8],
        srcW: Int,
        srcH: Int,
        centerX cx: Double,
        centerY cy: Double,
        width w: Int,
        height h: Int,
        angleRad theta: Double
    ) -> [UInt8] {
        guard abs(theta) >= 0.002 else {
            let x0 = max(0, min(srcW - w, Int(round(cx - Double(w) * 0.5))))
            let y0 = max(0, min(srcH - h, Int(round(cy - Double(h) * 0.5))))
            return cropRGB(src, srcW: srcW, x: x0, y: y0, w: w, h: h)
        }

        var out = [UInt8](repeating: 0, count: w * h * 3)
        let cosT = cos(theta)
        let sinT = sin(theta)
        let halfW = Double(w) * 0.5
        let halfH = Double(h) * 0.5

        src.withUnsafeBufferPointer { sPtr in
            out.withUnsafeMutableBufferPointer { dPtr in
                guard let s = sPtr.baseAddress, let d = dPtr.baseAddress else { return }
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let v = Double(y) - halfH
                    let dRowOff = y * w * 3
                    for x in 0..<w {
                        let u = Double(x) - halfW
                        let sx = cx + u * cosT - v * sinT
                        let sy = cy + u * sinT + v * cosT

                        let di = dRowOff + x * 3
                        if sx >= 0 && sx < Double(srcW - 1) && sy >= 0 && sy < Double(srcH - 1) {
                            let x0 = Int(sx), x1 = x0 + 1
                            let y0 = Int(sy), y1 = y0 + 1
                            let ax = Float(sx - Double(x0))
                            let ay = Float(sy - Double(y0))

                            let w00 = (1 - ax) * (1 - ay)
                            let w10 = ax * (1 - ay)
                            let w01 = (1 - ax) * ay
                            let w11 = ax * ay

                            let r0 = y0 * srcW * 3
                            let r1 = y1 * srcW * 3
                            let p00 = r0 + x0 * 3
                            let p10 = r0 + x1 * 3
                            let p01 = r1 + x0 * 3
                            let p11 = r1 + x1 * 3

                            d[di]     = UInt8(min(255, max(0, Int(Float(s[p00])     * w00 + Float(s[p10])     * w10 + Float(s[p01])     * w01 + Float(s[p11])     * w11 + 0.5))))
                            d[di + 1] = UInt8(min(255, max(0, Int(Float(s[p00 + 1]) * w00 + Float(s[p10 + 1]) * w10 + Float(s[p01 + 1]) * w01 + Float(s[p11 + 1]) * w11 + 0.5))))
                            d[di + 2] = UInt8(min(255, max(0, Int(Float(s[p00 + 2]) * w00 + Float(s[p10 + 2]) * w10 + Float(s[p01 + 2]) * w01 + Float(s[p11 + 2]) * w11 + 0.5))))
                        }
                    }
                }
            }
        }
        return out
    }

    private func cropRGB(_ src: [UInt8], srcW: Int, x: Int, y: Int, w: Int, h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 3)
        let rowBytes = w * 3
        for row in 0..<h {
            let srcOff = ((y + row) * srcW + x) * 3
            let dstOff = row * rowBytes
            out[dstOff..<(dstOff + rowBytes)] = src[srcOff..<(srcOff + rowBytes)]
        }
        return out
    }

    func makeCGImage(from rgb: [UInt8], width: Int, height: Int) -> CGImage? {
        let count = width * height
        guard rgb.count >= count * 3 else { return nil }
        var rgba = [UInt8](repeating: 255, count: count * 4)
        rgb.withUnsafeBufferPointer { sPtr in
            rgba.withUnsafeMutableBufferPointer { dPtr in
                guard let s = sPtr.baseAddress, let d = dPtr.baseAddress else { return }
                for i in 0..<count {
                    let si = i * 3, di = i * 4
                    d[di] = s[si]; d[di + 1] = s[si + 1]; d[di + 2] = s[si + 2]
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
}
// MARK: - 19世紀ステレオカード（Stereoview Card）仕様定義（レポート準拠）

/// 台紙（マウント）の年代・様式プリセット
enum StereoCardMountPreset: String, CaseIterable, Identifiable, Sendable {
    case autoSampleColor = "Auto Sample Source Color"
    case keystoneDark    = "1900s Keystone Dark"
    case classicBuff     = "1880s Classic Buff"
    case vividTerracotta = "1870s Cabinet Terracotta"
    case victorianGreen  = "1870s Victorian Green"
    case chromeYellow    = "1860s Chrome Yellow"
    case earlyIvory      = "1850s Early Ivory"

    var id: String { rawValue }

    /// プリセットの標準台紙RGBカラー
    var baseRGB: (r: UInt8, g: UInt8, b: UInt8) {
        switch self {
        case .autoSampleColor:
            return (54, 56, 58) // サンプルがない場合のフォールバック（Keystone Dark）
        case .keystoneDark:
            return (52, 54, 57)   // チャコール・スレートグレー（1890s–1920s Keystone / Underwood）
        case .classicBuff:
            return (207, 182, 144) // バフ・黄褐色（1880s–1890s）
        case .vividTerracotta:
            return (208, 102, 64)  // テラコッタオレンジ（1870s）
        case .victorianGreen:
            return (52, 92, 70)    // フォレストグリーン（1870s）
        case .chromeYellow:
            return (232, 184, 56)  // カナリア〜クロームイエロー（1860s）
        case .earlyIvory:
            return (242, 237, 226) // アイボリー・ブリストル紙（1850s）
        }
    }

    /// 1870年代バイカラー（裏面色が縁にわずかに覗く仕様）のエッジ色
    var bicolorEdgeRGB: (r: UInt8, g: UInt8, b: UInt8)? {
        switch self {
        case .vividTerracotta:
            return (226, 200, 214) // 裏面ペールラベンダー／ピンク
        case .victorianGreen:
            return (212, 182, 110) // ゴールド／バフ縁
        default:
            return nil
        }
    }

    /// 曲面マウント（1879年以降の水平方向湾曲シェーディング）の有無
    var hasCurvedMountShading: Bool {
        switch self {
        case .keystoneDark, .classicBuff, .autoSampleColor:
            return true
        case .vividTerracotta, .victorianGreen, .chromeYellow:
            return true
        case .earlyIvory:
            return false
        }
    }

    /// 台紙の四隅が角丸（1868年以降）か直角（1850s〜1860s前半）か
    var hasRoundedMountCorners: Bool {
        switch self {
        case .earlyIvory:
            return false
        default:
            return true
        }
    }

    /// プリセットに応じた標準の印画カット形状
    var defaultPrintCutStyle: StereoCardPrintCutStyle {
        switch self {
        case .chromeYellow, .vividTerracotta, .victorianGreen, .keystoneDark, .autoSampleColor:
            return .archTop
        case .classicBuff:
            return .roundedCorners
        case .earlyIvory:
            return .square
        }
    }

    /// プリセットに応じた左右プリント間の隙間有無
    var defaultHasCenterGap: Bool {
        switch self {
        case .earlyIvory, .chromeYellow:
            return true // 1850s–1860s は中央に 2〜4mm の台紙隙間あり
        default:
            return false // 1870s 以降は密着
        }
    }
}

/// 台紙のサイズ規格（横幅 7.0 インチ基準）
enum StereoCardSizeSpec: String, CaseIterable, Identifiable, Sendable {
    case standard = "Standard (7 × 3.5 in)"
    case cabinet  = "Cabinet (7 × 4.0 in)"
    case imperial = "Imperial (7 × 4.5 in)"

    var id: String { rawValue }

    var heightInches: Double {
        switch self {
        case .standard: return 3.5
        case .cabinet:  return 4.0
        case .imperial: return 4.5
        }
    }

    var aspectRatio: Double {
        7.0 / heightInches
    }
}

/// 印画（プリント）のカット形状
enum StereoCardPrintCutStyle: String, CaseIterable, Identifiable, Sendable {
    case autoFromPreset = "Auto (Match Era)"
    case archTop        = "Arched Top"
    case roundedCorners = "Rounded Corners"
    case square         = "Square"

    var id: String { rawValue }
}

/// 左右プリント間の境界スタイル
enum StereoCardCenterGapStyle: String, CaseIterable, Identifiable, Sendable {
    case autoFromPreset = "Auto"
    case joined         = "Joined (Seamless)"
    case separated      = "Separated (3mm)"

    var id: String { rawValue }
}

/// 台紙テキスト・クレジットの再現モード
enum StereoCardTextMode: String, CaseIterable, Identifiable, Sendable {
    case ocrAuto       = "Letterpress (Auto OCR)"
    case manualTypeset = "Letterpress (Manual)"
    case none          = "No Text"

    var id: String { rawValue }
}

/// ステレオカード合成の設定一式
struct StereoCardMountConfig: Equatable, Sendable {
    var preset: StereoCardMountPreset = .autoSampleColor
    var sizeSpec: StereoCardSizeSpec = .standard
    var printCutStyle: StereoCardPrintCutStyle = .autoFromPreset
    var centerGapStyle: StereoCardCenterGapStyle = .autoFromPreset
    var textMode: StereoCardTextMode = .ocrAuto
    var topCenterText: String = ""
    var bottomCaption: String = ""
    var leftMarginText: String = ""
    var rightMarginText: String = ""
    var useFilenameAsCaption: Bool = false
    var sourceFilename: String = ""
    var preservedArchFromAI: Bool = false

    /// 印字すべきテキスト（OCR抽出または手動入力）が存在するかどうか
    var hasPrintableText: Bool {
        guard textMode != .none else { return false }
        let trimmedCap = bottomCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCap = !trimmedCap.isEmpty || (useFilenameAsCaption && !sourceFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let hasTop = !topCenterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasLeft = !leftMarginText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasRight = !rightMarginText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasCap || hasTop || hasLeft || hasRight
    }
}

// MARK: - ステレオカード・マウント合成 & 活版タイポグラフィエンジン

enum StereoCardMountRenderer {

    /// 左右の整準済みプリントからステレオカード（台紙付き）RGBA 画像を生成する
    /// - Returns: `(rgba: [UInt8], width: Int, height: Int)`
    static func renderCardRGBA(
        leftRGB: [UInt8],
        rightRGB: [UInt8],
        printWidth: Int,
        printHeight: Int,
        config: StereoCardMountConfig,
        mountContext: StereoCardSegmenter.OriginalCardMountContext?,
        transparentOuterCorners: Bool,
        printAlphaMask: [UInt8]? = nil
    ) -> (rgba: [UInt8], width: Int, height: Int) {
        guard printWidth >= 16, printHeight >= 16,
              leftRGB.count >= printWidth * printHeight * 3,
              rightRGB.count >= printWidth * printHeight * 3 else {
            return ([UInt8](repeating: 0, count: 64 * 32 * 4), 64, 32)
        }

        // プロシージャル年代別台紙（または元カード色スポイト台紙）の生成
        return renderProceduralMount(
            leftRGB: leftRGB,
            rightRGB: rightRGB,
            printWidth: printWidth,
            printHeight: printHeight,
            config: config,
            mountContext: mountContext,
            transparentOuterCorners: transparentOuterCorners,
            printAlphaMask: printAlphaMask
        )
    }

    /// RGB 3チャンネル配列として取得（JPEG 書き出し等向け）
    static func renderCardRGB(
        leftRGB: [UInt8],
        rightRGB: [UInt8],
        printWidth: Int,
        printHeight: Int,
        config: StereoCardMountConfig,
        mountContext: StereoCardSegmenter.OriginalCardMountContext?,
        backgroundColor: (r: UInt8, g: UInt8, b: UInt8) = (18, 18, 20),
        printAlphaMask: [UInt8]? = nil
    ) -> (rgb: [UInt8], width: Int, height: Int) {
        let (rgba, cw, ch) = renderCardRGBA(
            leftRGB: leftRGB,
            rightRGB: rightRGB,
            printWidth: printWidth,
            printHeight: printHeight,
            config: config,
            mountContext: mountContext,
            transparentOuterCorners: true,
            printAlphaMask: printAlphaMask
        )
        let count = cw * ch
        var rgb = [UInt8](repeating: 0, count: count * 3)
        for i in 0..<count {
            let si = i * 4
            let di = i * 3
            let a = Int(rgba[si + 3])
            if a >= 255 {
                rgb[di]     = rgba[si]
                rgb[di + 1] = rgba[si + 1]
                rgb[di + 2] = rgba[si + 2]
            } else if a <= 0 {
                rgb[di]     = backgroundColor.r
                rgb[di + 1] = backgroundColor.g
                rgb[di + 2] = backgroundColor.b
            } else {
                let invA = 255 - a
                rgb[di]     = UInt8((Int(rgba[si])     * a + Int(backgroundColor.r) * invA + 127) / 255)
                rgb[di + 1] = UInt8((Int(rgba[si + 1]) * a + Int(backgroundColor.g) * invA + 127) / 255)
                rgb[di + 2] = UInt8((Int(rgba[si + 2]) * a + Int(backgroundColor.b) * invA + 127) / 255)
            }
        }
        return (rgb, cw, ch)
    }

    // MARK: - 年代別プロシージャル台紙生成 + 4領域インク転写 / 活版組版印字

    private static func renderProceduralMount(
        leftRGB: [UInt8],
        rightRGB: [UInt8],
        printWidth: Int,
        printHeight: Int,
        config: StereoCardMountConfig,
        mountContext: StereoCardSegmenter.OriginalCardMountContext?,
        transparentOuterCorners: Bool,
        printAlphaMask: [UInt8]? = nil
    ) -> (rgba: [UInt8], width: Int, height: Int) {
        let effectivePreset: StereoCardMountPreset = config.preset
        let baseRGB: (r: UInt8, g: UInt8, b: UInt8)
        if effectivePreset == .autoSampleColor, let ctx = mountContext {
            baseRGB = ctx.sampledCardRGB
        } else {
            baseRGB = effectivePreset.baseRGB
        }

        // 1. 7インチ物理規格（Keystone 実測黄金比：左右マージン各 0.49"、上マージン 0.095"、下マージン 0.345"）
        let hasGap: Bool
        switch config.centerGapStyle {
        case .autoFromPreset:
            if let ctx = mountContext {
                let rawGap = max(0, ctx.rightBox.x0 - ctx.leftBox.x1)
                let gapRatio = Double(rawGap) / Double(max(1, ctx.cardWidth))
                // 元カードが月カードのように中央分離のない密着カード（隙間1.5%未満）なら密着を自動選択
                if gapRatio < 0.015 {
                    hasGap = false
                } else {
                    hasGap = effectivePreset.defaultHasCenterGap
                }
            } else {
                hasGap = effectivePreset.defaultHasCenterGap
            }
        case .joined:         hasGap = false
        case .separated:      hasGap = true
        }
        let gapInches = hasGap ? 0.09 : 0.008 // 分離時は約 2.3mm、密着時は 0.2mm
        let sideMarginInches = 0.49
        let singleSlotWidthInches = (7.0 - sideMarginInches * 2.0 - gapInches) * 0.5 // 約 3.00 inch
        let cardHeightInches = config.sizeSpec.heightInches
        let hasText = config.hasPrintableText
        let topMarginInches: Double
        let bottomMarginInches: Double
        if hasText {
            topMarginInches = 0.095
            bottomMarginInches = 0.345
        } else {
            // OCR等で文字がない場合：上下マージンを均等にして垂直軸の中央に配置
            let totalVerticalMargin = 0.095 + 0.345
            topMarginInches = totalVerticalMargin * 0.5
            bottomMarginInches = totalVerticalMargin * 0.5
        }
        let slotHeightInches = cardHeightInches - topMarginInches - bottomMarginInches // Standard 3.5" 時に 3.06 inch

        let ppiFromW = Double(printWidth) / singleSlotWidthInches
        let ppiFromH = Double(printHeight) / slotHeightInches
        let ppi = max(140.0, min(650.0, max(ppiFromW, ppiFromH)))

        let cardW = max(560, Int((7.0 * ppi).rounded()))
        let cardH = max(280, Int((cardHeightInches * ppi).rounded()))

        let sideMarginPx = Int((sideMarginInches * ppi).rounded())
        let topMarginPx = Int((topMarginInches * ppi).rounded())
        let bottomMarginPx = Int((bottomMarginInches * ppi).rounded())
        let gapPx = max(hasGap ? 4 : 1, Int((gapInches * ppi).rounded()))

        let availTotalW = cardW - sideMarginPx * 2 - gapPx
        let slotW = max(32, availTotalW / 2)
        let slotH = max(32, cardH - topMarginPx - bottomMarginPx)

        // SBS表示のアスペクト比・全構図を100%維持（拡大クロップによる切断をゼロに抑える Aspect Fit 配置）
        let printAspect = Double(printWidth) / Double(printHeight)
        let slotAspect = Double(slotW) / Double(slotH)

        let dstPrintW: Int
        let dstPrintH: Int
        if printAspect > slotAspect {
            dstPrintW = slotW
            dstPrintH = max(16, Int((Double(slotW) / printAspect).rounded()))
        } else {
            dstPrintH = slotH
            dstPrintW = max(16, Int((Double(slotH) * printAspect).rounded()))
        }

        let centerX = cardW / 2
        let pasteLX = centerX - gapPx / 2 - dstPrintW
        let pasteRX = centerX + (gapPx + 1) / 2
        let pasteY: Int
        if hasText {
            pasteY = topMarginPx + max(0, (slotH - dstPrintH) / 2)
        } else {
            pasteY = max(0, (cardH - dstPrintH) / 2)
        }

        // 2. 台紙ベース（カラー + 曲面マウント陰影 + 紙質グレイン + 1870sバイカラーベベル）の生成
        var canvasRGB = generateMountBoardSurface(
            width: cardW,
            height: cardH,
            baseRGB: baseRGB,
            curvedShading: effectivePreset.hasCurvedMountShading,
            bicolorEdge: effectivePreset.bicolorEdgeRGB
        )

        // 3. 左右プリントの変倍 & 実輪郭（または指定カット）貼付合成
        let scaledL = resizeBilinearRGB(leftRGB, sw: printWidth, sh: printHeight, dw: dstPrintW, dh: dstPrintH)
        let scaledR = resizeBilinearRGB(rightRGB, sw: printWidth, sh: printHeight, dw: dstPrintW, dh: dstPrintH)
        let scaledAlphaMask: [UInt8]? = (printAlphaMask.flatMap { mask in
            guard mask.count >= printWidth * printHeight else { return nil }
            return resizeBilinearMask8(mask, sw: printWidth, sh: printHeight, dw: dstPrintW, dh: dstPrintH)
        })
        let combineWithParametric = (config.printCutStyle != .autoFromPreset)

        let cutStyle: StereoCardPrintCutStyle = (config.printCutStyle == .autoFromPreset)
            ? effectivePreset.defaultPrintCutStyle
            : config.printCutStyle
        let archParams = resolveArchParams(
            cutStyle: cutStyle,
            aiArchParams: mountContext?.archParams,
            useAIArch: config.printCutStyle == .autoFromPreset && mountContext != nil
        )

        pastePrintOntoMount(
            canvasRGB: &canvasRGB,
            cardW: cardW,
            cardH: cardH,
            printRGB: scaledL,
            pw: dstPrintW,
            ph: dstPrintH,
            dstX: pasteLX,
            dstY: pasteY,
            archParams: archParams,
            alphaMask: scaledAlphaMask,
            combineWithParametric: combineWithParametric
        )

        pastePrintOntoMount(
            canvasRGB: &canvasRGB,
            cardW: cardW,
            cardH: cardH,
            printRGB: scaledR,
            pw: dstPrintW,
            ph: dstPrintH,
            dstX: pasteRX,
            dstY: pasteY,
            archParams: archParams,
            alphaMask: scaledAlphaMask,
            combineWithParametric: combineWithParametric
        )

        // 4. 台紙テキスト・クレジットの再現（活版2行組版タイポグラフィ印字）
        let leftRect = CGRect(x: pasteLX, y: pasteY, width: dstPrintW, height: dstPrintH)
        let rightRect = CGRect(x: pasteRX, y: pasteY, width: dstPrintW, height: dstPrintH)

        switch config.textMode {
        case .none:
            break
        case .ocrAuto, .manualTypeset:
            drawLetterpressTypography(
                canvasRGB: &canvasRGB,
                cardW: cardW,
                cardH: cardH,
                leftPrintRect: leftRect,
                rightPrintRect: rightRect,
                archParams: archParams,
                mountBaseRGB: baseRGB,
                config: config
            )
        }

        // 5. 台紙の四隅コーナー処理（1868年以降の角丸マウント / 1850s直角マウント）
        let rgba = convertMountToRGBA(
            canvasRGB: canvasRGB,
            width: cardW,
            height: cardH,
            roundedCorners: effectivePreset.hasRoundedMountCorners,
            transparentCorners: transparentOuterCorners
        )
        return (rgba, cardW, cardH)
    }

    // MARK: - 台紙サーフェス生成（年代別カラー + 曲面マウント陰影 + 紙質グレイン）

    private static func generateMountBoardSurface(
        width: Int,
        height: Int,
        baseRGB: (r: UInt8, g: UInt8, b: UInt8),
        curvedShading: Bool,
        bicolorEdge: (r: UInt8, g: UInt8, b: UInt8)?
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 3)
        let br = Double(baseRGB.r)
        let bg = Double(baseRGB.g)
        let bb = Double(baseRGB.b)

        var xShade = [Double](repeating: 1.0, count: width)
        if curvedShading {
            for x in 0..<width {
                let nx = (Double(x) / Double(max(1, width - 1))) * 2.0 - 1.0
                let curve = 1.0 + 0.032 * cos(nx * .pi * 0.65) - 0.040 * (nx * nx)
                xShade[x] = curve
            }
        }

        let borderBevelPx = max(2, min(width, height) / 220)

        for y in 0..<height {
            let ny = (Double(y) / Double(max(1, height - 1))) * 2.0 - 1.0
            let yShade = curvedShading ? (1.0 - 0.016 * (ny * ny)) : 1.0
            let rowOff = y * width * 3

            for x in 0..<width {
                let shade = xShade[x] * yShade
                let grain = paperGrainNoise(x: x, y: y, seed: 777) * 2.0

                var r = br * shade + grain
                var g = bg * shade + grain
                var b = bb * shade + grain * 0.85

                let distEdge = min(min(x, width - 1 - x), min(y, height - 1 - y))
                if distEdge < borderBevelPx {
                    let t = 1.0 - Double(distEdge) / Double(borderBevelPx)
                    if let bi = bicolorEdge {
                        let blend = t * 0.65
                        r = r * (1.0 - blend) + Double(bi.r) * blend
                        g = g * (1.0 - blend) + Double(bi.g) * blend
                        b = b * (1.0 - blend) + Double(bi.b) * blend
                    } else {
                        let isTopLeft = (y < borderBevelPx || x < borderBevelPx)
                        let delta = (isTopLeft ? 7.0 : -9.0) * t
                        r += delta; g += delta; b += delta
                    }
                }

                let idx = rowOff + x * 3
                out[idx]     = UInt8(max(0, min(255, Int(r.rounded()))))
                out[idx + 1] = UInt8(max(0, min(255, Int(g.rounded()))))
                out[idx + 2] = UInt8(max(0, min(255, Int(b.rounded()))))
            }
        }
        return out
    }

    // MARK: - プリントの貼付合成（ドームアーチ + 下辺フラット直角 + 虫食いゼロ保証）

    private static func resolveArchParams(
        cutStyle: StereoCardPrintCutStyle,
        aiArchParams: StereoCardSegmenter.ArchShapeParams?,
        useAIArch: Bool
    ) -> StereoCardSegmenter.ArchShapeParams {
        if useAIArch, let ai = aiArchParams {
            let topRx = (ai.topRxRatio < 0.02 || ai.topRyRatio < 0.02) ? 0.0 : min(0.50, ai.topRxRatio)
            let topRy = (ai.topRxRatio < 0.02 || ai.topRyRatio < 0.02) ? 0.0 : min(0.45, ai.topRyRatio)
            let botRx = (ai.botRxRatio < 0.04 || ai.botRyRatio < 0.04) ? 0.0 : min(0.24, ai.botRxRatio)
            let botRy = (ai.botRxRatio < 0.04 || ai.botRyRatio < 0.04) ? 0.0 : min(0.18, ai.botRyRatio)
            return StereoCardSegmenter.ArchShapeParams(
                topRxRatio: topRx,
                topRyRatio: topRy,
                botRxRatio: botRx,
                botRyRatio: botRy,
                topArchExp: max(2.0, min(3.5, ai.topArchExp))
            )
        }
        switch cutStyle {
        case .autoFromPreset, .archTop:
            // 19世紀ステレオカード & Keystone 標準「上部アーチ角丸（中央フラット） + 下部フラット直角」
            return StereoCardSegmenter.ArchShapeParams(
                topRxRatio: 0.26,
                topRyRatio: 0.14,
                botRxRatio: 0.0,
                botRyRatio: 0.0,
                topArchExp: 2.0
            )
        case .roundedCorners:
            return StereoCardSegmenter.ArchShapeParams(
                topRxRatio: 0.08,
                topRyRatio: 0.08,
                botRxRatio: 0.08,
                botRyRatio: 0.08
            )
        case .square:
            return StereoCardSegmenter.ArchShapeParams(
                topRxRatio: 0.0,
                topRyRatio: 0.0,
                botRxRatio: 0.0,
                botRyRatio: 0.0
            )
        }
    }

    private static func pastePrintOntoMount(
        canvasRGB: inout [UInt8],
        cardW: Int,
        cardH: Int,
        printRGB: [UInt8],
        pw: Int,
        ph: Int,
        dstX: Int,
        dstY: Int,
        archParams: StereoCardSegmenter.ArchShapeParams,
        alphaMask: [UInt8]? = nil,
        combineWithParametric: Bool = false
    ) {
        let hasDirectMask = (alphaMask != nil && (alphaMask?.count ?? 0) >= pw * ph)
        let w = Double(pw)
        let h = Double(ph)

        // Keep Arch 適用済み（外周黒マスク済み）のプリントでは黒フリンジや元台紙残りをゼロにするため同一インセット & 内側オフセットで切り抜く
        let hasKeepArchBlackFrame: Bool = {
            if hasDirectMask { return false }
            guard pw >= 16, ph >= 16, printRGB.count >= pw * ph * 3 else { return false }
            let xs = [pw / 4, pw / 2, (pw * 3) / 4]
            for x in xs {
                let tOff = x * 3
                let bOff = ((ph - 1) * pw + x) * 3
                if printRGB[tOff] > 8 || printRGB[tOff + 1] > 8 || printRGB[tOff + 2] > 8 { return false }
                if printRGB[bOff] > 8 || printRGB[bOff + 1] > 8 || printRGB[bOff + 2] > 8 { return false }
            }
            return true
        }()

        let hasTopRound = (archParams.topRxRatio > 0.005 && archParams.topRyRatio > 0.005)
        let hasBotRound = (archParams.botRxRatio > 0.005 && archParams.botRyRatio > 0.005)
        let isFullTopArch = hasTopRound && archParams.topRxRatio >= 0.48

        // 黒マスク済みプリントの縁に残った追加黒帯（residualBorderInsets 由来等）の厚みを実測して内側に寄せる
        var blackEdgeTop = 0, blackEdgeBot = 0, blackEdgeLeft = 0, blackEdgeRight = 0
        if hasKeepArchBlackFrame && pw >= 32 && ph >= 32 && printRGB.count >= pw * ph * 3 {
            let maxEdgeScanY = max(4, Int(h * 0.035))
            let maxEdgeScanX = max(4, Int(w * 0.035))
            func isBlackRow(_ y: Int) -> Bool {
                let x0 = pw / 5, x1 = (pw * 4) / 5
                var b = 0, n = 0
                for x in stride(from: x0, to: x1, by: max(1, (x1 - x0) / 48)) {
                    let i = (y * pw + x) * 3
                    n += 1
                    if printRGB[i] <= 12 && printRGB[i + 1] <= 12 && printRGB[i + 2] <= 12 { b += 1 }
                }
                return n > 0 && Double(b) / Double(n) >= 0.90
            }
            func isBlackCol(_ x: Int) -> Bool {
                let y0 = ph / 4, y1 = (ph * 3) / 4
                var b = 0, n = 0
                for y in stride(from: y0, to: y1, by: max(1, (y1 - y0) / 48)) {
                    let i = (y * pw + x) * 3
                    n += 1
                    if printRGB[i] <= 12 && printRGB[i + 1] <= 12 && printRGB[i + 2] <= 12 { b += 1 }
                }
                return n > 0 && Double(b) / Double(n) >= 0.90
            }
            for dy in 0..<maxEdgeScanY { if isBlackRow(dy) { blackEdgeTop = dy + 1 } else { break } }
            for dy in 0..<maxEdgeScanY { if isBlackRow(ph - 1 - dy) { blackEdgeBot = dy + 1 } else { break } }
            for dx in 0..<maxEdgeScanX { if isBlackCol(dx) { blackEdgeLeft = dx + 1 } else { break } }
            for dx in 0..<maxEdgeScanX { if isBlackCol(pw - 1 - dx) { blackEdgeRight = dx + 1 } else { break } }
        }

        let insetX = hasKeepArchBlackFrame ? max(Double(blackEdgeLeft) + 1.0, w * 0.009 + 1.2) : 0.0
        let insetXRight = hasKeepArchBlackFrame ? max(Double(blackEdgeRight) + 1.0, w * 0.009 + 1.2) : 0.0
        let insetYTop = hasKeepArchBlackFrame ? max(Double(blackEdgeTop) + 1.0, h * 0.009 + 1.2) : 0.0
        let insetYBot = hasKeepArchBlackFrame ? max(Double(blackEdgeBot) + 1.0, (hasBotRound ? (h * 0.009) : max(2.2, h * 0.005)) + 1.2) : 0.0
        let archOff = (hasKeepArchBlackFrame && hasTopRound) ? 2.6 : 0.0

        let x0 = insetX
        let x1 = w - insetXRight
        let y0 = insetYTop
        let y1 = h - insetYBot
        let innerW = max(8.0, x1 - x0)
        let innerH = max(8.0, y1 - y0)
        let ax0 = x0 + archOff
        let ax1 = x1 - archOff
        let ay0 = y0 + archOff

        let topRx = hasTopRound ? max(2.0, innerW * archParams.topRxRatio) : 0.0
        let topRy = hasTopRound ? max(2.0, innerH * archParams.topRyRatio) : 0.0
        let botRx = hasBotRound ? max(2.0, innerW * archParams.botRxRatio) : 0.0
        let botRy = hasBotRound ? max(2.0, innerH * archParams.botRyRatio) : 0.0

        @inline(__always)
        func printAlphaAt(_ px: Double, _ py: Double) -> Double {
            if let mask = alphaMask, hasDirectMask {
                let ipx = min(pw - 1, max(0, Int(px)))
                let ipy = min(ph - 1, max(0, Int(py)))
                let realAlpha = Double(mask[ipy * pw + ipx]) / 255.0
                if !combineWithParametric {
                    return realAlpha
                }
                let d = StereoCardSegmenter.signedArchShapeDistance(
                    px: px, py: py,
                    ax0: ax0, ax1: ax1, ay0: ay0, y1: y1,
                    rxTop: topRx, ryTop: topRy, rxBot: botRx, ryBot: botRy,
                    hasTopRound: hasTopRound, hasBotRound: hasBotRound,
                    isFullTopArch: isFullTopArch, topArchExp: archParams.topArchExp
                )
                if d <= -1.2 { return 0.0 }
                if d >= 1.2 { return realAlpha }
                let t = (d + 1.2) / 2.4
                let paramAlpha = t * t * (3.0 - 2.0 * t)
                return min(realAlpha, paramAlpha)
            }

            let d = StereoCardSegmenter.signedArchShapeDistance(
                px: px, py: py,
                ax0: ax0, ax1: ax1, ay0: ay0, y1: y1,
                rxTop: topRx, ryTop: topRy, rxBot: botRx, ryBot: botRy,
                hasTopRound: hasTopRound, hasBotRound: hasBotRound,
                isFullTopArch: isFullTopArch, topArchExp: archParams.topArchExp
            )
            if d <= -1.2 { return 0.0 }
            if hasKeepArchBlackFrame && d < 3.5 {
                let ipx = min(pw - 1, max(0, Int(px)))
                let ipy = min(ph - 1, max(0, Int(py)))
                let pOff = (ipy * pw + ipx) * 3
                if printRGB[pOff] <= 10 && printRGB[pOff + 1] <= 10 && printRGB[pOff + 2] <= 10 {
                    return 0.0
                }
            }
            if d >= 1.2 { return 1.0 }
            let t = (d + 1.2) / 2.4
            return t * t * (3.0 - 2.0 * t)
        }

        // 1. 印画の紙厚を表現する微細なドロップシャドウ（右下へ 1〜2px）
        let shadowOff = max(1, min(2, cardW / 1000))
        for py in 0..<ph {
            let cy = dstY + py + shadowOff
            guard cy >= 0 && cy < cardH else { continue }
            for px in 0..<pw {
                let cx = dstX + px + shadowOff
                guard cx >= 0 && cx < cardW else { continue }
                let alpha = printAlphaAt(Double(px) + 0.5, Double(py) + 0.5)
                if alpha > 0.25 {
                    let shade = 1.0 - 0.16 * alpha
                    let cIdx = (cy * cardW + cx) * 3
                    canvasRGB[cIdx]     = UInt8(Double(canvasRGB[cIdx]) * shade)
                    canvasRGB[cIdx + 1] = UInt8(Double(canvasRGB[cIdx + 1]) * shade)
                    canvasRGB[cIdx + 2] = UInt8(Double(canvasRGB[cIdx + 2]) * shade)
                }
            }
        }

        // 2. プリント本体のアンチエイリアス貼付合成（フラッドフィルを使わず幾何学的アーチのみで抜くため宇宙背景でも虫食いゼロ）
        for py in 0..<ph {
            let cy = dstY + py
            guard cy >= 0 && cy < cardH else { continue }
            for px in 0..<pw {
                let cx = dstX + px
                guard cx >= 0 && cx < cardW else { continue }
                let alpha = printAlphaAt(Double(px) + 0.5, Double(py) + 0.5)
                guard alpha > 0.0 else { continue }

                let pIdx = (py * pw + px) * 3
                let cIdx = (cy * cardW + cx) * 3
                if alpha >= 0.995 {
                    canvasRGB[cIdx]     = printRGB[pIdx]
                    canvasRGB[cIdx + 1] = printRGB[pIdx + 1]
                    canvasRGB[cIdx + 2] = printRGB[pIdx + 2]
                } else {
                    let inv = 1.0 - alpha
                    canvasRGB[cIdx]     = UInt8(max(0, min(255, Int((Double(printRGB[pIdx])     * alpha + Double(canvasRGB[cIdx])     * inv).rounded()))))
                    canvasRGB[cIdx + 1] = UInt8(max(0, min(255, Int((Double(printRGB[pIdx + 1]) * alpha + Double(canvasRGB[cIdx + 1]) * inv).rounded()))))
                    canvasRGB[cIdx + 2] = UInt8(max(0, min(255, Int((Double(printRGB[pIdx + 2]) * alpha + Double(canvasRGB[cIdx + 2]) * inv).rounded()))))
                }
            }
        }
    }

    private static func archCornerAlpha(
        x: Double, y: Double, w: Double, h: Double,
        topRx: Double, topRy: Double, botRx: Double, botRy: Double
    ) -> Double {
        if topRx > 1.0 && topRy > 1.0 && y < topRy {
            let dy = (topRy - y) / topRy
            if x < topRx {
                let dx = (topRx - x) / topRx
                let dist = sqrt(dx * dx + dy * dy)
                let feather = 1.2 / max(topRx, topRy)
                if dist > 1.0 + feather { return 0.0 }
                if dist > 1.0 - feather { return (1.0 + feather - dist) / (2.0 * feather) }
            } else if x > w - topRx {
                let dx = (x - (w - topRx)) / topRx
                let dist = sqrt(dx * dx + dy * dy)
                let feather = 1.2 / max(topRx, topRy)
                if dist > 1.0 + feather { return 0.0 }
                if dist > 1.0 - feather { return (1.0 + feather - dist) / (2.0 * feather) }
            }
        }
        if botRx > 1.0 && botRy > 1.0 && y > h - botRy {
            let dy = (y - (h - botRy)) / botRy
            if x < botRx {
                let dx = (botRx - x) / botRx
                let dist = sqrt(dx * dx + dy * dy)
                let feather = 1.2 / max(botRx, botRy)
                if dist > 1.0 + feather { return 0.0 }
                if dist > 1.0 - feather { return (1.0 + feather - dist) / (2.0 * feather) }
            } else if x > w - botRx {
                let dx = (x - (w - botRx)) / botRx
                let dist = sqrt(dx * dx + dy * dy)
                let feather = 1.2 / max(botRx, botRy)
                if dist > 1.0 + feather { return 0.0 }
                if dist > 1.0 - feather { return (1.0 + feather - dist) / (2.0 * feather) }
            }
        }
        return 1.0
    }

    // MARK: - CoreGraphics / CoreText 本格活版2行組版タイポグラフィ印字（レポート5章準拠）

    private static func drawLetterpressTypography(
        canvasRGB: inout [UInt8],
        cardW: Int,
        cardH: Int,
        leftPrintRect: CGRect,
        rightPrintRect: CGRect,
        archParams: StereoCardSegmenter.ArchShapeParams,
        mountBaseRGB: (r: UInt8, g: UInt8, b: UInt8),
        config: StereoCardMountConfig
    ) {
        let captionText: String
        let trimmedCap = config.bottomCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCap.isEmpty {
            captionText = trimmedCap
        } else if config.useFilenameAsCaption && !config.sourceFilename.isEmpty {
            captionText = (config.sourceFilename as NSString).deletingPathExtension
        } else {
            captionText = ""
        }

        let topNumberText = config.topCenterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let leftText = config.leftMarginText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightText = config.rightMarginText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !captionText.isEmpty || !topNumberText.isEmpty || !leftText.isEmpty || !rightText.isEmpty else { return }

        var rgba = [UInt8](repeating: 255, count: cardW * cardH * 4)
        for i in 0..<(cardW * cardH) {
            let si = i * 3
            let di = i * 4
            rgba[di]     = canvasRGB[si]
            rgba[di + 1] = canvasRGB[si + 1]
            rgba[di + 2] = canvasRGB[si + 2]
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: cardW,
            height: cardH,
            bitsPerComponent: 8,
            bytesPerRow: cardW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)

        // Keystone のチャコールグレー台紙（luma ~ 72）を含め、実物の活版文字は重厚なチャコールブラック
        let luma = 0.299 * Double(mountBaseRGB.r) + 0.587 * Double(mountBaseRGB.g) + 0.114 * Double(mountBaseRGB.b)
        let inkColor: NSColor
        if luma < 36.0 {
            inkColor = NSColor(calibratedRed: 0.84, green: 0.82, blue: 0.78, alpha: 0.88)
        } else {
            inkColor = NSColor(calibratedRed: 0.09, green: 0.085, blue: 0.08, alpha: 0.88)
        }

        let captionFontSize = max(11.0, CGFloat(cardH) * 0.025)
        let topNumFontSize = max(16.0, CGFloat(cardH) * 0.052)
        let marginOuterFontSize = max(11.5, CGFloat(cardH) * 0.028)
        let marginInnerFontSize = max(9.5, CGFloat(cardH) * 0.021)

        let captionFont = NSFont(name: "Baskerville-SemiBold", size: captionFontSize)
            ?? NSFont(name: "Hiragino Mincho ProN W6", size: captionFontSize)
            ?? NSFont.systemFont(ofSize: captionFontSize, weight: .semibold)

        let topNumFont = NSFont(name: "Baskerville-Bold", size: topNumFontSize)
            ?? NSFont.systemFont(ofSize: topNumFontSize, weight: .bold)

        let marginOuterFont = NSFont(name: "Baskerville-SemiBoldItalic", size: marginOuterFontSize)
            ?? NSFont(name: "Baskerville-Bold", size: marginOuterFontSize)
            ?? NSFont.systemFont(ofSize: marginOuterFontSize, weight: .bold)

        let marginInnerFont = NSFont(name: "Baskerville-SemiBold", size: marginInnerFontSize)
            ?? NSFont.systemFont(ofSize: marginInnerFontSize, weight: .medium)

        // 1. 下部タイトル（右プリント直下の中央〜やや左寄り：Keystone 規格）
        if !captionText.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: captionFont,
                .foregroundColor: inkColor,
                .kern: captionFontSize * 0.03
            ]
            let attrStr = NSAttributedString(string: captionText, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

            let bottomSpaceTopY = rightPrintRect.maxY
            let bottomSpaceH = CGFloat(cardH) - bottomSpaceTopY
            let centerTopY = bottomSpaceTopY + bottomSpaceH * 0.46
            let cgY = CGFloat(cardH) - centerTopY - bounds.height * 0.35
            let cgX = rightPrintRect.midX - bounds.width * 0.5

            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: cgX, y: cgY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        // 2. 中央上部のアーチ谷間番号（例: 594）
        if !topNumberText.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: topNumFont,
                .foregroundColor: inkColor,
                .kern: topNumFontSize * 0.04
            ]
            let attrStr = NSAttributedString(string: topNumberText, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

            let midX = (leftPrintRect.maxX + rightPrintRect.minX) * 0.5
            let archDropPx = leftPrintRect.height * CGFloat(max(0.14, archParams.topRyRatio))
            let topY = leftPrintRect.minY + archDropPx * 0.36
            let cgY = CGFloat(cardH) - topY - bounds.height * 0.5
            let cgX = midX - bounds.width * 0.5

            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: cgX, y: cgY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        // 3. 左マージン縦書き（下から上へ 90°回転：1行または `/` 区切りの2行組み対応）
        if !leftText.isEmpty {
            let lines = leftText.components(separatedBy: CharacterSet(charactersIn: "/\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let centerY = CGFloat(cardH) - leftPrintRect.midY
            let marginW = leftPrintRect.minX

            if lines.count >= 2 {
                // 外側行（例: Keystone View Company）と内側行（例: Manufacturers MADE IN U.S.A. Publishers）
                let outerStr = NSAttributedString(string: lines[0], attributes: [
                    .font: marginOuterFont, .foregroundColor: inkColor, .kern: marginOuterFontSize * 0.05
                ])
                let innerStr = NSAttributedString(string: lines.dropFirst().joined(separator: "   "), attributes: [
                    .font: marginInnerFont, .foregroundColor: inkColor, .kern: marginInnerFontSize * 0.04
                ])
                let outerLine = CTLineCreateWithAttributedString(outerStr)
                let innerLine = CTLineCreateWithAttributedString(innerStr)
                let outerB = CTLineGetBoundsWithOptions(outerLine, .useOpticalBounds)
                let innerB = CTLineGetBoundsWithOptions(innerLine, .useOpticalBounds)

                ctx.saveGState()
                ctx.translateBy(x: marginW * 0.36, y: centerY)
                ctx.rotate(by: .pi * 0.5)
                ctx.textMatrix = .identity
                ctx.textPosition = CGPoint(x: -outerB.width * 0.5, y: -outerB.height * 0.35)
                CTLineDraw(outerLine, ctx)
                ctx.restoreGState()

                ctx.saveGState()
                ctx.translateBy(x: marginW * 0.72, y: centerY)
                ctx.rotate(by: .pi * 0.5)
                ctx.textMatrix = .identity
                ctx.textPosition = CGPoint(x: -innerB.width * 0.5, y: -innerB.height * 0.35)
                CTLineDraw(innerLine, ctx)
                ctx.restoreGState()
            } else {
                let singleStr = NSAttributedString(string: lines[0], attributes: [
                    .font: marginOuterFont, .foregroundColor: inkColor, .kern: marginOuterFontSize * 0.05
                ])
                let singleLine = CTLineCreateWithAttributedString(singleStr)
                let b = CTLineGetBoundsWithOptions(singleLine, .useOpticalBounds)
                ctx.saveGState()
                ctx.translateBy(x: marginW * 0.52, y: centerY)
                ctx.rotate(by: .pi * 0.5)
                ctx.textMatrix = .identity
                ctx.textPosition = CGPoint(x: -b.width * 0.5, y: -b.height * 0.35)
                CTLineDraw(singleLine, ctx)
                ctx.restoreGState()
            }
        }

        // 4. 右マージン縦書き（上から下へ 90°回転：1行または `/` 区切りの2行組み対応）
        if !rightText.isEmpty {
            let lines = rightText.components(separatedBy: CharacterSet(charactersIn: "/\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let centerY = CGFloat(cardH) - rightPrintRect.midY
            let rightMarginW = CGFloat(cardW) - rightPrintRect.maxX

            if lines.count >= 2 {
                let innerStr = NSAttributedString(string: lines[0], attributes: [
                    .font: marginInnerFont, .foregroundColor: inkColor, .kern: marginInnerFontSize * 0.04
                ])
                let outerStr = NSAttributedString(string: lines.dropFirst().joined(separator: " "), attributes: [
                    .font: marginInnerFont, .foregroundColor: inkColor, .kern: marginInnerFontSize * 0.04
                ])
                let innerLine = CTLineCreateWithAttributedString(innerStr)
                let outerLine = CTLineCreateWithAttributedString(outerStr)
                let innerB = CTLineGetBoundsWithOptions(innerLine, .useOpticalBounds)
                let outerB = CTLineGetBoundsWithOptions(outerLine, .useOpticalBounds)

                ctx.saveGState()
                ctx.translateBy(x: rightPrintRect.maxX + rightMarginW * 0.62, y: centerY)
                ctx.rotate(by: -.pi * 0.5)
                ctx.textMatrix = .identity
                ctx.textPosition = CGPoint(x: -innerB.width * 0.5, y: -innerB.height * 0.35)
                CTLineDraw(innerLine, ctx)
                ctx.restoreGState()

                ctx.saveGState()
                ctx.translateBy(x: rightPrintRect.maxX + rightMarginW * 0.28, y: centerY)
                ctx.rotate(by: -.pi * 0.5)
                ctx.textMatrix = .identity
                ctx.textPosition = CGPoint(x: -outerB.width * 0.5, y: -outerB.height * 0.35)
                CTLineDraw(outerLine, ctx)
                ctx.restoreGState()
            } else {
                let singleStr = NSAttributedString(string: lines[0], attributes: [
                    .font: marginInnerFont, .foregroundColor: inkColor, .kern: marginInnerFontSize * 0.04
                ])
                let singleLine = CTLineCreateWithAttributedString(singleStr)
                let b = CTLineGetBoundsWithOptions(singleLine, .useOpticalBounds)
                ctx.saveGState()
                ctx.translateBy(x: rightPrintRect.maxX + rightMarginW * 0.48, y: centerY)
                ctx.rotate(by: -.pi * 0.5)
                ctx.textMatrix = .identity
                ctx.textPosition = CGPoint(x: -b.width * 0.5, y: -b.height * 0.35)
                CTLineDraw(singleLine, ctx)
                ctx.restoreGState()
            }
        }

        for i in 0..<(cardW * cardH) {
            let si = i * 4
            let di = i * 3
            canvasRGB[di]     = rgba[si]
            canvasRGB[di + 1] = rgba[si + 1]
            canvasRGB[di + 2] = rgba[si + 2]
        }
    }

    // MARK: - Apple Vision OCR による元台紙の4領域テキスト自動抽出（コントラスト正規化前処理付き）

    static func recognizeTextsFromOriginalMount(
        ctx: StereoCardSegmenter.OriginalCardMountContext
    ) async -> (bottomCaption: String, topCenter: String, leftMargin: String, rightMargin: String) {
        await Task.detached(priority: .userInitiated) {
            let w = ctx.cardWidth
            let h = ctx.cardHeight
            let rgb = ctx.cardRGB

            // 1. 下部キャプション領域（左右プリントの下辺+4px〜カード下端98.5%）
            let botY0 = max(Int(Double(h) * 0.85), min(h - 16, max(ctx.leftBox.y1, ctx.rightBox.y1) + 4))
            let botY1 = min(h, Int(Double(h) * 0.985))
            let botH = botY1 - botY0
            var bottomText = ""
            if botH >= 12 {
                let sub = cropSubRectRGB(rgb, srcW: w, srcH: h, x0: ctx.leftBox.x0, y0: botY0, cw: ctx.rightBox.x1 - ctx.leftBox.x0, ch: botH)
                bottomText = performEnhancedVisionOCR(rgb: sub.rgb, width: sub.w, height: sub.h, joinSeparator: " ")
            }

            // 2. 中央上部のアーチ谷間領域（例: 594）
            var topCenterText = ""
            let midX = (ctx.leftBox.x1 + ctx.rightBox.x0) / 2
            let wedgeW = max(24, Int(Double(ctx.leftBox.x1 - ctx.leftBox.x0) * 0.24))
            let wedgeH = max(24, Int(Double(ctx.leftBox.y1 - ctx.leftBox.y0) * 0.16))
            let topY0 = max(0, min(ctx.leftBox.y0, ctx.rightBox.y0))
            if wedgeW >= 20, wedgeH >= 20 {
                let sub = cropSubRectRGB(rgb, srcW: w, srcH: h, x0: midX - wedgeW / 2, y0: topY0, cw: wedgeW, ch: wedgeH)
                topCenterText = performEnhancedVisionOCR(rgb: sub.rgb, width: sub.w, height: sub.h, joinSeparator: " ")
            }

            // 3. 左マージン領域（時計回り90°回転して水平化してからOCR、2行は " / " で連結）
            var leftText = ""
            let leftMarginW = ctx.leftBox.x0
            if leftMarginW >= 14 {
                let sub = cropSubRectRGB(rgb, srcW: w, srcH: h, x0: 0, y0: ctx.leftBox.y0, cw: leftMarginW, ch: ctx.leftBox.y1 - ctx.leftBox.y0)
                let rotated = rotate90ClockwiseRGB(sub.rgb, width: sub.w, height: sub.h)
                leftText = performEnhancedVisionOCR(rgb: rotated.rgb, width: rotated.w, height: rotated.h, joinSeparator: " / ")
            }

            // 4. 右マージン領域（反時計回り90°回転して水平化してからOCR、2行は " / " で連結）
            var rightText = ""
            let rightMarginW = w - ctx.rightBox.x1
            if rightMarginW >= 14 {
                let sub = cropSubRectRGB(rgb, srcW: w, srcH: h, x0: ctx.rightBox.x1, y0: ctx.rightBox.y0, cw: rightMarginW, ch: ctx.rightBox.y1 - ctx.rightBox.y0)
                let rotated = rotate90CounterClockwiseRGB(sub.rgb, width: sub.w, height: sub.h)
                rightText = performEnhancedVisionOCR(rgb: rotated.rgb, width: rotated.w, height: rotated.h, joinSeparator: " / ")
            }

            return (bottomText, topCenterText, leftText, rightText)
        }.value
    }

    /// 暗いグレー台紙上の黒文字でも確実に認識できるよう、背景を白・文字インクを黒にコントラスト正規化＋余白パディングしてOCRを実行
    private static func performEnhancedVisionOCR(rgb: [UInt8], width: Int, height: Int, joinSeparator: String) -> String {
        guard width >= 8, height >= 8 else { return "" }
        let count = width * height
        var luma = [Double](repeating: 0, count: count)
        var isRedWatermark = [Bool](repeating: false, count: count)
        for i in 0..<count {
            let si = i * 3
            let r = Double(rgb[si])
            let g = Double(rgb[si + 1])
            let b = Double(rgb[si + 2])
            luma[i] = 0.299 * r + 0.587 * g + 0.114 * b
            // Web透かしスタンプ（赤い「PROTECTED IMAGE」等）の高彩度赤・マゼンタ画素を検出
            if r >= 115.0 && (r - max(g, b)) >= 28.0 {
                isRedWatermark[i] = true
            }
        }
        // 赤スタンプのアンチエイリアス縁も完全に無害化するため 3px 膨張マスクを生成
        var watermarkMask = isRedWatermark
        let hasRedPixels = isRedWatermark.contains(true)
        if hasRedPixels {
            for y in 0..<height {
                let y0 = max(0, y - 3), y1 = min(height - 1, y + 3)
                for x in 0..<width {
                    guard isRedWatermark[y * width + x] else { continue }
                    let x0 = max(0, x - 3), x1 = min(width - 1, x + 3)
                    for ny in y0...y1 {
                        let rowOff = ny * width
                        for nx in x0...x1 {
                            watermarkMask[rowOff + nx] = true
                        }
                    }
                }
            }
        }

        // 外周の黒フチ・赤透かしを除いた内部ピクセルから背景輝度（72%tile）と文字輝度（2%tile）を推定
        var innerLumas: [Double] = []
        innerLumas.reserveCapacity(count)
        let mx = max(1, width / 20)
        let my = max(1, height / 10)
        for y in my..<(height - my) {
            for x in mx..<(width - mx) {
                let idx = y * width + x
                if watermarkMask[idx] { continue }
                let v = luma[idx]
                if v > 12.0 { innerLumas.append(v) }
            }
        }
        let sorted = (innerLumas.isEmpty ? luma : innerLumas).sorted()
        let bg = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.72))]
        let fg = sorted[max(0, Int(Double(sorted.count) * 0.02))]
        let span = max(16.0, bg - fg)

        let pad = 20
        let pw = width + pad * 2
        let ph = height + pad * 2
        var rgba = [UInt8](repeating: 250, count: pw * ph * 4)
        for i in 0..<(pw * ph) {
            rgba[i * 4 + 3] = 255
        }

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let v = watermarkMask[idx] ? bg : luma[idx]
                let norm = min(1.0, max(0.0, (v - fg) / span))
                let u8 = UInt8(min(250.0, max(0.0, pow(norm, 0.75) * 250.0)))
                let di = ((y + pad) * pw + (x + pad)) * 4
                rgba[di]     = u8
                rgba[di + 1] = u8
                rgba[di + 2] = u8
                rgba[di + 3] = 255
            }
        }

        guard let cfData = CFDataCreate(kCFAllocatorDefault, rgba, rgba.count),
              let provider = CGDataProvider(data: cfData),
              let cgImage = CGImage(
                  width: pw,
                  height: ph,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: pw * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "fr-FR", "de-DE", "ja-JP"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results else { return "" }
            // 上から下（CG座標では maxY の大きい順）にソートして連結
            let sortedObs = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            let lines = sortedObs.compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { line in
                    guard !line.isEmpty else { return false }
                    let alnumCount = line.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
                    guard alnumCount >= 2 else { return false }
                    let upper = line.uppercased()
                    if upper.contains("PROTECTED") || upper.contains("TED IMAG") || upper.contains("WATERMARK") || upper.contains("CONTENT COPY") {
                        return false
                    }
                    return true
                }
            return lines.joined(separator: joinSeparator)
        } catch {
            return ""
        }
    }

    // MARK: - 画像変換・ユーティリティ

    /// プリント枠 (dw × dh) に対してアスペクト比を維持しつつ中央クロップ充填（Aspect Fill）でリサイズする
    private static func resizeAspectFillRGB(_ src: [UInt8], sw: Int, sh: Int, dw: Int, dh: Int) -> [UInt8] {
        guard dw > 0, dh > 0, sw > 0, sh > 0 else { return [] }
        if sw == dw && sh == dh { return src }
        let scale = max(Double(dw) / Double(sw), Double(dh) / Double(sh))
        let cropW = min(Double(sw), Double(dw) / scale)
        let cropH = min(Double(sh), Double(dh) / scale)
        let startX = (Double(sw) - cropW) * 0.5
        let startY = (Double(sh) - cropH) * 0.5

        var dst = [UInt8](repeating: 0, count: dw * dh * 3)
        let scaleX = Float(cropW) / Float(dw)
        let scaleY = Float(cropH) / Float(dh)
        let offX = Float(startX)
        let offY = Float(startY)

        src.withUnsafeBufferPointer { sPtr in
            dst.withUnsafeMutableBufferPointer { dPtr in
                guard let s = sPtr.baseAddress, let d = dPtr.baseAddress else { return }
                for y in 0..<dh {
                    let fy = min(Float(sh - 1), max(0.0, offY + (Float(y) + 0.5) * scaleY - 0.5))
                    let y0 = Int(fy), y1 = min(y0 + 1, sh - 1)
                    let ay = fy - Float(y0)
                    let row0 = y0 * sw * 3
                    let row1 = y1 * sw * 3
                    let dRow = y * dw * 3
                    for x in 0..<dw {
                        let fx = min(Float(sw - 1), max(0.0, offX + (Float(x) + 0.5) * scaleX - 0.5))
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

    private static func convertMountToRGBA(
        canvasRGB: [UInt8],
        width: Int,
        height: Int,
        roundedCorners: Bool,
        transparentCorners: Bool
    ) -> [UInt8] {
        let count = width * height
        var rgba = [UInt8](repeating: 255, count: count * 4)
        let cornerR = roundedCorners ? (Double(height) * 0.045) : 0.0
        let w = Double(width)
        let h = Double(height)

        for y in 0..<height {
            let fy = Double(y) + 0.5
            for x in 0..<width {
                let fx = Double(x) + 0.5
                let si = (y * width + x) * 3
                let di = (y * width + x) * 4

                var alpha = 1.0
                if roundedCorners && cornerR > 1.0 {
                    alpha = archCornerAlpha(x: fx, y: fy, w: w, h: h, topRx: cornerR, topRy: cornerR, botRx: cornerR, botRy: cornerR)
                }

                if transparentCorners {
                    rgba[di]     = canvasRGB[si]
                    rgba[di + 1] = canvasRGB[si + 1]
                    rgba[di + 2] = canvasRGB[si + 2]
                    rgba[di + 3] = UInt8(max(0, min(255, Int((alpha * 255.0).rounded()))))
                } else {
                    let bg: Double = 18.0
                    let inv = 1.0 - alpha
                    rgba[di]     = UInt8(max(0, min(255, Int((Double(canvasRGB[si])     * alpha + bg * inv).rounded()))))
                    rgba[di + 1] = UInt8(max(0, min(255, Int((Double(canvasRGB[si + 1]) * alpha + bg * inv).rounded()))))
                    rgba[di + 2] = UInt8(max(0, min(255, Int((Double(canvasRGB[si + 2]) * alpha + bg * inv).rounded()))))
                    rgba[di + 3] = 255
                }
            }
        }
        return rgba
    }

    private static func paperGrainNoise(x: Int, y: Int, seed: UInt64) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 374761393 &+ y &* 668265263)) ^ seed
        h = (h ^ (h >> 13)) &* 1274126177
        h = h ^ (h >> 16)
        return (Double(h & 0xFFFF) / 32767.5) - 1.0 // -1.0 ... +1.0
    }

    private static func cropSubRectRGB(_ src: [UInt8], srcW: Int, srcH: Int, x0: Int, y0: Int, cw: Int, ch: Int) -> (rgb: [UInt8], w: Int, h: Int) {
        let sx0 = max(0, min(srcW - 1, x0))
        let sy0 = max(0, min(srcH - 1, y0))
        let sx1 = max(sx0 + 1, min(srcW, x0 + cw))
        let sy1 = max(sy0 + 1, min(srcH, y0 + ch))
        let w = sx1 - sx0
        let h = sy1 - sy0
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            let sRow = ((sy0 + y) * srcW + sx0) * 3
            let dRow = y * w * 3
            out[dRow..<(dRow + w * 3)] = src[sRow..<(sRow + w * 3)]
        }
        return (out, w, h)
    }

    private static func rotate90ClockwiseRGB(_ src: [UInt8], width: Int, height: Int) -> (rgb: [UInt8], w: Int, h: Int) {
        let nw = height
        let nh = width
        var out = [UInt8](repeating: 0, count: nw * nh * 3)
        for y in 0..<height {
            for x in 0..<width {
                let sIdx = (y * width + x) * 3
                let nx = height - 1 - y
                let ny = x
                let dIdx = (ny * nw + nx) * 3
                out[dIdx]     = src[sIdx]
                out[dIdx + 1] = src[sIdx + 1]
                out[dIdx + 2] = src[sIdx + 2]
            }
        }
        return (out, nw, nh)
    }

    private static func rotate90CounterClockwiseRGB(_ src: [UInt8], width: Int, height: Int) -> (rgb: [UInt8], w: Int, h: Int) {
        let nw = height
        let nh = width
        var out = [UInt8](repeating: 0, count: nw * nh * 3)
        for y in 0..<height {
            for x in 0..<width {
                let sIdx = (y * width + x) * 3
                let nx = y
                let ny = width - 1 - x
                let dIdx = (ny * nw + nx) * 3
                out[dIdx]     = src[sIdx]
                out[dIdx + 1] = src[sIdx + 1]
                out[dIdx + 2] = src[sIdx + 2]
            }
        }
        return (out, nw, nh)
    }

    private static func resizeBilinearRGB(_ src: [UInt8], sw: Int, sh: Int, dw: Int, dh: Int) -> [UInt8] {
        guard dw > 0, dh > 0, sw > 0, sh > 0 else { return [] }
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

    private static func resizeBilinearMask8(_ src: [UInt8], sw: Int, sh: Int, dw: Int, dh: Int) -> [UInt8] {
        guard dw > 0, dh > 0, sw > 0, sh > 0, src.count >= sw * sh else { return [] }
        if sw == dw && sh == dh { return Array(src.prefix(dw * dh)) }
        var dst = [UInt8](repeating: 0, count: dw * dh)
        let scaleX = Float(sw) / Float(dw), scaleY = Float(sh) / Float(dh)
        src.withUnsafeBufferPointer { sPtr in
            dst.withUnsafeMutableBufferPointer { dPtr in
                guard let s = sPtr.baseAddress, let d = dPtr.baseAddress else { return }
                for y in 0..<dh {
                    let fy = max(0.0, min(Float(sh - 1), (Float(y) + 0.5) * scaleY - 0.5))
                    let y0 = Int(fy), y1 = min(y0 + 1, sh - 1)
                    let ay = fy - Float(y0)
                    let row0 = y0 * sw
                    let row1 = y1 * sw
                    let dRow = y * dw
                    for x in 0..<dw {
                        let fx = max(0.0, min(Float(sw - 1), (Float(x) + 0.5) * scaleX - 0.5))
                        let x0 = Int(fx), x1 = min(x0 + 1, sw - 1)
                        let ax = fx - Float(x0)
                        let v00 = Float(s[row0 + x0])
                        let v10 = Float(s[row0 + x1])
                        let v01 = Float(s[row1 + x0])
                        let v11 = Float(s[row1 + x1])
                        let val = (v00 * (1 - ax) + v10 * ax) * (1 - ay) + (v01 * (1 - ax) + v11 * ax) * ay
                        d[dRow + x] = UInt8(min(255, max(0, Int(val + 0.5))))
                    }
                }
            }
        }
        return dst
    }
}
