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
    private let samSize = 1024
    private let samMaskSize = 256

    struct ArchShapeParams: Sendable {
        var topRxRatio: Double = 0.15
        var topRyRatio: Double = 0.18
        var botRxRatio: Double = 0.09
        var botRyRatio: Double = 0.09
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
    }

    private var cachedModel: MLModel? = nil
    private var cachedSam2Encoder: MLModel? = nil
    private var cachedSam2Prompt: MLModel? = nil
    private var cachedSam2Decoder: MLModel? = nil
    private var latestArchParams = ArchShapeParams()
    private var latestCardLuma: Double? = nil
    private var latestMountContext: OriginalCardMountContext? = nil
    private let lock = NSLock()

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

    var isModelAvailable: Bool {
        resolveModelURL(name: "StereoCardSeg") != nil
    }

    /// モデルを解決してロード（未導入時は nil）
    private func loadModel(name: String, cache: inout MLModel?) -> MLModel? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache { return existing }
        guard let url = resolveModelURL(name: name) else { return nil }

        do {
            let compiledURL: URL
            if url.pathExtension == "mlpackage" || url.pathExtension == "mlmodel" {
                compiledURL = try MLModel.compileModel(at: url)
            } else {
                compiledURL = url
            }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let model = try MLModel(contentsOf: compiledURL, configuration: config)
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

    /// Core ML でステレオカード画像をセグメンテーションし、左右写真ペアを切り出す
    func extractPhotoPair(
        from rgb: [UInt8],
        width: Int,
        height: Int,
        mode: StereoCardCropper.ExtractionMode
    ) -> StereoCardCropper.CropResult? {
        lock.lock()
        latestCardLuma = nil
        latestMountContext = nil
        lock.unlock()
        guard width >= 64, height >= 32, rgb.count >= width * height * 3,
              let model = loadModel(name: "StereoCardSeg", cache: &cachedModel),
              let cgImage = makeCGImage(from: rgb, width: width, height: height) else {
            return nil
        }

        do {
            let inputFeature = try MLFeatureValue(
                cgImage: cgImage,
                pixelsWide: inputWidth,
                pixelsHigh: inputHeight,
                pixelFormatType: kCVPixelFormatType_32BGRA,
                options: nil
            )
            let provider = try MLDictionaryFeatureProvider(dictionary: ["image": inputFeature])
            let output = try model.prediction(from: provider)
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                return nil
            }

            // logits shape: [1, 2, H=256, W=512] (0=Card/Bg, 1=Photo)
            let H = inputHeight
            let W = inputWidth
            let strideC = logits.strides[1].intValue
            let strideY = logits.strides[2].intValue
            let strideX = logits.strides[3].intValue

            var probPhoto = [Float](repeating: 0, count: W * H)
            let isFloat16 = (logits.dataType == .float16)

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
            // 外周ラベル枠（P. Rossier / Keystone 等）の垂直境界線トリミング + 台紙境界エッジへのスナップ + 帯域検証付き左右上下Y範囲同期
            trimOuterLabelBorders(rgb: rgb, srcW: width, srcH: height, boxL: &roughBoxL, boxR: &roughBoxR, maskW: W, maskH: H)
            refineVerticalBoundsInMask(rgb: rgb, srcW: width, srcH: height, boxL: &roughBoxL, boxR: &roughBoxR, maskW: W, maskH: H)
            syncRoughBoundsY(rgb: rgb, srcW: width, srcH: height, boxL: &roughBoxL, boxR: &roughBoxR, maskW: W, maskH: H)

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
                rgb: rgb, srcW: width, srcH: height,
                yTop: min(preLy0, preRy0), yBot: max(preLy1, preRy1),
                xLeft: preLx0, xRight: preRx1,
                fallbackLuma: prelimCardLuma
            )
            if let prelimCardRGB {
                let origPreLy0 = preLy0
                let origPreRy0 = preRy0
                Self.recoverOvercroppedTopEdgeRGB(
                    rgb: rgb, srcW: width, srcH: height,
                    cLx0: preLx0, cLx1: preLx1, cLy0: &preLy0, cLy1: preLy1,
                    cRx0: preRx0, cRx1: preRx1, cRy0: &preRy0, cRy1: preRy1,
                    cardRGB: prelimCardRGB
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
            var mw = W
            var mh = H

            let refinedResult = refineWithSAM21Tiny(
                cgImage: cgImage,
                rgb: rgb,
                cardRGB: prelimCardRGB,
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
                mw = refined.w
                mh = refined.h
            }

            let invScaleX = Double(width) / Double(mw)
            let invScaleY = Double(height) / Double(mh)

            // 共通: 外枠バウンディングボックス・台紙地色・傾き角・アーチ形状の推定（OriginalMountContext 用）
            guard var boxL = robustBoundingBox(mask: finalMaskL, w: mw, h: mh),
                  var boxR = robustBoundingBox(mask: finalMaskR, w: mw, h: mh) else {
                return nil
            }
            trimOuterLabelBorders(rgb: rgb, srcW: width, srcH: height, boxL: &boxL, boxR: &boxR, maskW: mw, maskH: mh)
            var archParams = estimateArchParams(maskL: finalMaskL, boxL: boxL, maskR: finalMaskR, boxR: boxR, w: mw, h: mh)
            lock.lock()
            let cardLuma = latestCardLuma
            lock.unlock()

            let rawLx0 = Double(boxL.minX) * invScaleX
            let rawLx1 = Double(boxL.maxX + 1) * invScaleX
            var rawLy0 = Double(boxL.minY) * invScaleY
            var rawLy1 = Double(boxL.maxY + 1) * invScaleY
            let insetLX = max(2.0, (rawLx1 - rawLx0) * 0.004)

            let rawRx0 = Double(boxR.minX) * invScaleX
            let rawRx1 = Double(boxR.maxX + 1) * invScaleX
            var rawRy0 = Double(boxR.minY) * invScaleY
            var rawRy1 = Double(boxR.maxY + 1) * invScaleY

            do {
                let (vl, vr) = refineVerticalBoundsPair(
                    rgb: rgb, srcW: width, srcH: height,
                    left: (Int(rawLx0), Int(rawLx1), Int(rawLy0), Int(rawLy1)),
                    right: (Int(rawRx0), Int(rawRx1), Int(rawRy0), Int(rawRy1))
                )
                rawLy0 = Double(vl.y0); rawLy1 = Double(vl.y1 + 1)
                rawRy0 = Double(vr.y0); rawRy1 = Double(vr.y1 + 1)
            }
            let insetRX = max(2.0, (rawRx1 - rawRx0) * 0.004)
            let insetRY = max(2.0, (rawRy1 - rawRy0) * 0.004)
            let insetLY = max(2.0, (rawLy1 - rawLy0) * 0.004)

            var cLx0 = max(0, Int(floor(rawLx0 + insetLX)))
            var cLx1 = min(width, Int(ceil(rawLx1 - insetLX)))
            var cLy0 = max(0, Int(floor(rawLy0 + insetLY)))
            var cLy1 = min(height, Int(ceil(rawLy1)))

            var cRx0 = max(0, Int(floor(rawRx0 + insetRX)))
            var cRx1 = min(width, Int(ceil(rawRx1 - insetRX)))
            var cRy0 = max(0, Int(floor(rawRy0 + insetRY)))
            var cRy1 = min(height, Int(ceil(rawRy1)))

            trimHorizontalCardBorders(rgb: rgb, srcW: width, srcH: height, x0: cLx0, x1: cLx1, y0: &cLy0, y1: &cLy1)
            trimHorizontalCardBorders(rgb: rgb, srcW: width, srcH: height, x0: cRx0, x1: cRx1, y0: &cRy0, y1: &cRy1)

            let effectiveCardRGB = Self.sampleLocalCardRGB(
                rgb: rgb, srcW: width, srcH: height,
                yTop: min(cLy0, cRy0), yBot: max(cLy1, cRy1),
                xLeft: cLx0, xRight: cRx1,
                fallbackLuma: cardLuma
            )

            if let effectiveCardRGB {
                Self.recoverOvercroppedTopEdgeRGB(
                    rgb: rgb, srcW: width, srcH: height,
                    cLx0: cLx0, cLx1: cLx1, cLy0: &cLy0, cLy1: cLy1,
                    cRx0: cRx0, cRx1: cRx1, cRy0: &cRy0, cRy1: cRy1,
                    cardRGB: effectiveCardRGB
                )
            }

            Self.trimHorizontalCardAndCaptionBorders(
                rgb: rgb, srcW: width, srcH: height,
                cLx0: cLx0, cLx1: cLx1, cLy0: &cLy0, cLy1: &cLy1,
                cRx0: cRx0, cRx1: cRx1, cRy0: &cRy0, cRy1: &cRy1,
                cardRGB: effectiveCardRGB
            )
            if let effectiveCardRGB {
                Self.trimOuterCardColumnsRGB(
                    rgb: rgb, srcW: width, srcH: height,
                    cLx0: &cLx0, cLx1: &cLx1, cLy0: cLy0, cLy1: cLy1,
                    cRx0: &cRx0, cRx1: &cRx1, cRy0: cRy0, cRy1: cRy1,
                    cardRGB: effectiveCardRGB
                )
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
            let startLY = cLy0 + (lh - ch) / 2
            let startRX = min(width - cw, cRx0)
            let startRY = cRy0 + (rh - ch) / 2

            let commonSkewAngle = Self.estimateSkewAngle(maskL: finalMaskL, boxL: boxL, maskR: finalMaskR, boxR: boxR, w: mw, h: mh)
            let centerLX = Double(startLX) + Double(cw) * 0.5
            let centerLY = Double(startLY) + Double(ch) * 0.5
            let centerRX = Double(startRX) + Double(cw) * 0.5
            let centerRY = Double(startRY) + Double(ch) * 0.5

            var fullOutL = cropRotatedRGB(rgb, srcW: width, srcH: height, centerX: centerLX, centerY: centerLY, width: cw, height: ch, angleRad: commonSkewAngle)
            var fullOutR = cropRotatedRGB(rgb, srcW: width, srcH: height, centerX: centerRX, centerY: centerRY, width: cw, height: ch, angleRad: commonSkewAngle)
            Self.trimOuterBlackBorders(leftRGB: &fullOutL, rightRGB: &fullOutR, width: &cw, height: &ch)

            // フル解像度のコーナー背景色（通常台紙または白/黒抜き背景）から上下の角丸／直角／アーチを独立確定
            let topBgRGB = Self.resolveCornerBackgroundRGB(
                leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch,
                cardRGB: effectiveCardRGB, isTop: true
            )
            let botBgRGB = Self.resolveCornerBackgroundRGB(
                leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch,
                cardRGB: effectiveCardRGB, isTop: false
            )

            // 上部コーナー判定・実測
            if let bgT = topBgRGB {
                let topRatios = Self.cornerCardRatiosRGB(leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch, cardRGB: bgT, isTop: true)
                let topSquare = (topRatios[0] + topRatios[1]) * 0.5 < 0.30
                let allTopHaveBg = topRatios[0] >= 0.50 && (topRatios.reduce(0.0, +) * 0.25) >= 0.70
                if topSquare {
                    archParams.topRxRatio = 0.0
                    archParams.topRyRatio = 0.0
                } else if let measured = Self.measureOuterCornerArchShapeRGB(leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch, cardRGB: bgT, isTop: true) {
                    archParams.topRxRatio = measured.rxRatio
                    archParams.topRyRatio = measured.ryRatio
                } else if !allTopHaveBg && archParams.topRyRatio < 0.24 {
                    // 4隅揃っておらず低解像度値のみが 0.24 未満（角欠け・空誤差）の場合は直角プリントとみなす
                    archParams.topRxRatio = 0.0
                    archParams.topRyRatio = 0.0
                }
            }

            // 下部コーナー判定・実測（上部アーチの有無にかかわらず独立して実測・4隅丸角に正式対応）
            if let bgB = botBgRGB {
                let botRatios = Self.cornerCardRatiosRGB(leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch, cardRGB: bgB, isTop: false)
                let botSquare = (botRatios[0] + botRatios[1]) * 0.5 < 0.30
                if botSquare {
                    archParams.botRxRatio = 0.0
                    archParams.botRyRatio = 0.0
                } else if let measured = Self.measureOuterCornerArchShapeRGB(leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch, cardRGB: bgB, isTop: false) {
                    archParams.botRxRatio = measured.rxRatio
                    archParams.botRyRatio = measured.ryRatio
                } else {
                    archParams.botRxRatio = 0.0
                    archParams.botRyRatio = 0.0
                }
            }

            let finalTopRx = (archParams.topRxRatio < 0.03 || archParams.topRyRatio < 0.03) ? 0.0 : archParams.topRxRatio
            let finalTopRy = (archParams.topRxRatio < 0.03 || archParams.topRyRatio < 0.03) ? 0.0 : archParams.topRyRatio
            let finalBotRx = (archParams.botRxRatio < 0.03 || archParams.botRyRatio < 0.03) ? 0.0 : archParams.botRxRatio
            let finalBotRy = (archParams.botRxRatio < 0.03 || archParams.botRyRatio < 0.03) ? 0.0 : archParams.botRyRatio
            archParams = ArchShapeParams(
                topRxRatio: finalTopRx,
                topRyRatio: finalTopRy,
                botRxRatio: finalBotRx,
                botRyRatio: finalBotRy
            )

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

            let mountCtx = OriginalCardMountContext(
                cardRGB: rgb,
                cardWidth: width,
                cardHeight: height,
                leftBox: (x0: startLX, y0: startLY, x1: startLX + cw, y1: startLY + ch),
                rightBox: (x0: startRX, y0: startRY, x1: startRX + cw, y1: startRY + ch),
                maskL: finalMaskL,
                maskR: finalMaskR,
                maskWidth: mw,
                maskHeight: mh,
                skewAngleRad: commonSkewAngle,
                sampledCardRGB: sampledU8,
                archParams: archParams
            )
            lock.lock()
            latestArchParams = archParams
            latestMountContext = mountCtx
            lock.unlock()

            if mode == .keepArchBlack {
                Self.applyParametricArchMask(&fullOutL, width: cw, height: ch, params: archParams, extraInsetRatio: 0.004)
                Self.applyParametricArchMask(&fullOutR, width: cw, height: ch, params: archParams, extraInsetRatio: 0.004)

                return StereoCardCropper.CropResult(leftRGB: fullOutL, rightRGB: fullOutR, width: cw, height: ch, detectedCard: true, preservedArch: true)
            } else {
                guard let rectL = largestInscribedRect(mask: finalMaskL, w: mw, h: mh),
                      let rectR = largestInscribedRect(mask: finalMaskR, w: mw, h: mh) else {
                    return nil
                }
                let pad = 2
                let cLx0 = max(0, Int(ceil(Double(rectL.minX) * invScaleX)) + pad)
                let cLy0 = max(0, Int(ceil(Double(rectL.minY) * invScaleY)) + pad)
                let cLx1 = min(width, Int(floor(Double(rectL.maxX) * invScaleX)) - pad)
                let cLy1 = min(height, Int(floor(Double(rectL.maxY) * invScaleY)) - pad)

                let cRx0 = max(0, Int(ceil(Double(rectR.minX) * invScaleX)) + pad)
                let cRy0 = max(0, Int(ceil(Double(rectR.minY) * invScaleY)) + pad)
                let cRx1 = min(width, Int(floor(Double(rectR.maxX) * invScaleX)) - pad)
                let cRy1 = min(height, Int(floor(Double(rectR.maxY) * invScaleY)) - pad)

                let lw = cLx1 - cLx0, lh = cLy1 - cLy0
                let rw = cRx1 - cRx0, rh = cRy1 - cRy0
                let cw = min(lw, rw), ch = min(lh, rh)
                guard cw >= max(64, Int(Double(width) * 0.25)),
                      ch >= max(64, Int(Double(height) * 0.40)) else {
                    return nil
                }

                let startLX = cLx0 + (lw - cw) / 2
                let startLY = cLy0 + (lh - ch) / 2
                let startRX = cRx0 + (rw - cw) / 2
                let startRY = cRy0 + (rh - ch) / 2

                let boxFromRectL = IntBox(minX: rectL.minX, minY: rectL.minY, maxX: rectL.maxX, maxY: rectL.maxY)
                let boxFromRectR = IntBox(minX: rectR.minX, minY: rectR.minY, maxX: rectR.maxX, maxY: rectR.maxY)
                let skewAngle = Self.estimateSkewAngle(maskL: finalMaskL, boxL: boxFromRectL, maskR: finalMaskR, boxR: boxFromRectR, w: mw, h: mh)
                let centerLX = Double(startLX) + Double(cw) * 0.5
                let centerLY = Double(startLY) + Double(ch) * 0.5
                let centerRX = Double(startRX) + Double(cw) * 0.5
                let centerRY = Double(startRY) + Double(ch) * 0.5

                let outL = cropRotatedRGB(rgb, srcW: width, srcH: height, centerX: centerLX, centerY: centerLY, width: cw, height: ch, angleRad: skewAngle)
                let outR = cropRotatedRGB(rgb, srcW: width, srcH: height, centerX: centerRX, centerY: centerRY, width: cw, height: ch, angleRad: skewAngle)
                return StereoCardCropper.CropResult(leftRGB: outL, rightRGB: outR, width: cw, height: ch, detectedCard: true, preservedArch: false)
            }
        } catch {
            return nil
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
        let box: IntBox
        let area: Int
        let iou: Double
        let composite: Double
    }

    private func refineWithSAM21Tiny(
        cgImage: CGImage,
        rgb: [UInt8],
        cardRGB: (r: Double, g: Double, b: Double)?,
        srcW: Int,
        srcH: Int,
        boxL: IntBox,
        boxR: IntBox,
        refMaskL: [Bool],
        refMaskR: [Bool],
        probPhoto: [Float],
        splitX: Int,
        refW: Int,
        refH: Int
    ) -> RefinedMasks? {
        guard let encoder = loadModel(name: "SAM2_1TinyImageEncoderFLOAT16", cache: &cachedSam2Encoder),
              let promptEnc = loadModel(name: "SAM2_1TinyPromptEncoderFLOAT16", cache: &cachedSam2Prompt),
              let decoder = loadModel(name: "SAM2_1TinyMaskDecoderFLOAT16", cache: &cachedSam2Decoder) else {
            return nil
        }

        let scale = Double(samSize) / Double(max(srcW, srcH))
        let resizedW = max(1, Int((Double(srcW) * scale).rounded()))
        let resizedH = max(1, Int((Double(srcH) * scale).rounded()))
        let validW = max(1, Int((Double(resizedW) / 4.0).rounded()))
        let validH = max(1, Int((Double(resizedH) / 4.0).rounded()))

        guard let paddedCG = makeTopLeftPaddedCGImage(cgImage, targetSize: samSize, drawW: resizedW, drawH: resizedH) else {
            return nil
        }

        do {
            let imgFeature = try MLFeatureValue(
                cgImage: paddedCG,
                pixelsWide: samSize,
                pixelsHigh: samSize,
                pixelFormatType: kCVPixelFormatType_32BGRA,
                options: nil
            )
            let encOut = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": imgFeature]))
            guard let imgEmb = encOut.featureValue(for: "image_embedding")?.multiArrayValue,
                  let featsS0 = encOut.featureValue(for: "feats_s0")?.multiArrayValue,
                  let featsS1 = encOut.featureValue(for: "feats_s1")?.multiArrayValue else {
                return nil
            }

            func toSAMX(_ rx: Double) -> Float {
                Float(max(0.0, min(Double(samSize - 1), rx / Double(refW) * Double(resizedW))))
            }
            func toSAMY(_ ry: Double) -> Float {
                Float(max(0.0, min(Double(samSize - 1), ry / Double(refH) * Double(resizedH))))
            }

            // Step A: 正・負ポイントプロンプト + Box（PromptEncoder は末尾にパディング +1 を付加し Decoder 上限が 15 のため N ∈ [2, 14] を厳守）
            func buildPromptPoints(
                box: IntBox,
                otherBox: IntBox,
                refMask: [Bool],
                isLeft: Bool,
                includePoints: Bool
            ) -> [(x: Float, y: Float, label: Float)] {
                var pts: [(x: Float, y: Float, label: Float)] = []
                pts.reserveCapacity(10)

                if includePoints {
                    let cx = (box.minX + box.maxX) / 2
                    let cy = (box.minY + box.maxY) / 2
                    let bh = max(1, box.maxY - box.minY + 1)

                    func isSafePositive(_ rx: Int, _ ry: Int) -> Bool {
                        guard rx >= 1, rx < refW - 1, ry >= 1, ry < refH - 1,
                              refMask[ry * refW + rx] else { return false }
                        var cnt = 0
                        for dy in -1...1 {
                            for dx in -1...1 where refMask[(ry + dy) * refW + (rx + dx)] {
                                cnt += 1
                            }
                        }
                        return cnt >= 5
                    }

                    // 正ポイント (label = 1.0, 最大 3 点)
                    let posCandidates = [
                        (cx, cy),
                        (cx, box.minY + max(2, Int(Double(bh) * 0.10))),
                        (cx, box.minY + Int(Double(bh) * 0.72)),
                    ]
                    var seenY: [Int] = []
                    for (px, py) in posCandidates where !seenY.contains(py) && isSafePositive(px, py) {
                        seenY.append(py)
                        pts.append((toSAMX(Double(px)), toSAMY(Double(py)), 1.0))
                    }

                    // 負ポイント (label = 0.0, 最大 4 点: 確信度の高い外周余白・明確な中央ギャップのみに限定し、斜めマスクや手貼り段差への干渉を防ぐ)
                    func appendNegIfBg(_ rx: Int, _ ry: Int, threshold: Float = 0.15, verifyBackgroundRGB: Bool = true) {
                        guard rx >= 0, rx < refW, ry >= 0, ry < refH,
                              probPhoto[ry * refW + rx] < threshold else { return }
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
                    let padX = max(3, Int(Double(refW) * 0.030))
                    appendNegIfBg(cx, box.minY - padY, verifyBackgroundRGB: true)
                    appendNegIfBg(cx, box.maxY + padY, verifyBackgroundRGB: true)
                    if isLeft {
                        appendNegIfBg(box.minX - padX, cy, verifyBackgroundRGB: true)
                    } else {
                        appendNegIfBg(box.maxX + padX, cy, verifyBackgroundRGB: true)
                    }

                    // 4px 以上の明確な隙間がある場合のみ中央ギャップ点に負ポイントを配置（密着カードには置かない）
                    let gapStart = isLeft ? (box.maxX + 1) : (otherBox.maxX + 1)
                    let gapEnd = isLeft ? (otherBox.minX - 1) : (box.minX - 1)
                    if gapEnd - gapStart + 1 >= 4 {
                        let midX = (gapStart + gapEnd) / 2
                        appendNegIfBg(midX, cy, threshold: 0.25, verifyBackgroundRGB: false)
                    }

                    if pts.count > 12 {
                        pts = Array(pts.prefix(12))
                    }
                }

                // Box プロンプト（末尾に label = 2.0, 3.0）
                pts.append((toSAMX(Double(box.minX)), toSAMY(Double(box.minY)), 2.0))
                pts.append((toSAMX(Double(box.maxX + 1)), toSAMY(Double(box.maxY + 1)), 3.0))
                return pts
            }

            func decodeSide(
                box: IntBox,
                otherBox: IntBox,
                refMask: [Bool],
                isLeft: Bool,
                includePoints: Bool
            ) -> SAMCandidateResult? {
                let pts = buildPromptPoints(box: box, otherBox: otherBox, refMask: refMask, isLeft: isLeft, includePoints: includePoints)
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

                let pProvider = try? MLDictionaryFeatureProvider(dictionary: [
                    "points": MLFeatureValue(multiArray: ptsArr),
                    "labels": MLFeatureValue(multiArray: lblArr),
                ])
                guard let pProvider,
                      let pOut = try? promptEnc.prediction(from: pProvider),
                      let sparseEmb = pOut.featureValue(for: "sparse_embeddings")?.multiArrayValue,
                      let denseEmb = pOut.featureValue(for: "dense_embeddings")?.multiArrayValue else {
                    return nil
                }

                let decProvider = try? MLDictionaryFeatureProvider(dictionary: [
                    "image_embedding": MLFeatureValue(multiArray: imgEmb),
                    "sparse_embedding": MLFeatureValue(multiArray: sparseEmb),
                    "dense_embedding": MLFeatureValue(multiArray: denseEmb),
                    "feats_s0": MLFeatureValue(multiArray: featsS0),
                    "feats_s1": MLFeatureValue(multiArray: featsS1),
                ])
                guard let decProvider,
                      let decOut = try? decoder.prediction(from: decProvider),
                      let masks = decOut.featureValue(for: "low_res_masks")?.multiArrayValue else {
                    return nil
                }

                let cCount = masks.shape[1].intValue
                let sC = masks.strides[1].intValue
                let sY = masks.strides[2].intValue
                let sX = masks.strides[3].intValue
                let isFP16 = (masks.dataType == .float16)

                // Step B: scores [1, 3] 出力の読み出し（IoU予測確信度）
                var candScores = [Double](repeating: 0.5, count: cCount)
                if let scoreArr = decOut.featureValue(for: "scores")?.multiArrayValue {
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

                for k in 0..<cCount {
                    var raw = [Bool](repeating: false, count: validW * validH)
                    if isFP16 {
                        let ptr16 = masks.dataPointer.assumingMemoryBound(to: Float16.self)
                        let cOff = k * sC
                        for y in 0..<validH {
                            let yOff = cOff + y * sY
                            for x in 0..<validW {
                                if ptr16[yOff + x * sX] > 0 {
                                    raw[y * validW + x] = true
                                }
                            }
                        }
                    } else {
                        let ptr32 = masks.dataPointer.assumingMemoryBound(to: Float.self)
                        let cOff = k * sC
                        for y in 0..<validH {
                            let yOff = cOff + y * sY
                            for x in 0..<validW {
                                if ptr32[yOff + x * sX] > 0 {
                                    raw[y * validW + x] = true
                                }
                            }
                        }
                    }

                    let filled = hvConvexFill(raw, w: validW, h: validH)
                    guard let samBox = robustBoundingBox(mask: filled, w: validW, h: validH) else { continue }
                    let iou = computeIoU(filled, w: validW, h: validH, refMask: refMask, refW: refW, refH: refH)
                    let area = filled.reduce(0) { $0 + ($1 ? 1 : 0) }
                    let boxArea = max(1, (samBox.maxX - samBox.minX + 1) * (samBox.maxY - samBox.minY + 1))
                    let fillRatio = min(1.0, Double(area) / Double(boxArea))
                    let composite = iou * 0.72 + candScores[k] * 0.15 + fillRatio * 0.13
                    candidates.append(SAMCandidateResult(mask: filled, box: samBox, area: area, iou: iou, composite: composite))
                }
                return selectBestSAMCandidate(candidates: candidates, w: validW, h: validH, promptBox: box, refW: refW, refH: refH)
            }

            func decodeSideWithFallback(box: IntBox, otherBox: IntBox, refMask: [Bool], isLeft: Bool) -> SAMCandidateResult? {
                if let withPts = decodeSide(box: box, otherBox: otherBox, refMask: refMask, isLeft: isLeft, includePoints: true) {
                    return withPts
                }
                return decodeSide(box: box, otherBox: otherBox, refMask: refMask, isLeft: isLeft, includePoints: false)
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
                        trustLeft = hL <= hR
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
                probL: smoothProbFromMask(resL.mask, w: validW, h: validH),
                probR: smoothProbFromMask(resR.mask, w: validW, h: validH),
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

    private func hvConvexFill(_ raw: [Bool], w: Int, h: Int) -> [Bool] {
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

    /// SAM 2.1 Tiny の複数候補マスクから複合品質スコア（U-Net IoU + モデル確信度 scores + 矩形充填率）と境界妥当性で最良候補を選別
    private func selectBestSAMCandidate(
        candidates: [SAMCandidateResult],
        w: Int,
        h: Int,
        promptBox: IntBox,
        refW: Int,
        refH: Int
    ) -> SAMCandidateResult? {
        let valid = candidates.filter {
            $0.iou >= 0.65 && isAcceptableSAMMask($0.mask, w: w, h: h, promptBox: promptBox, refW: refW, refH: refH)
        }
        guard let best = valid.max(by: { $0.composite < $1.composite }) else { return nil }
        // U-Net参照マスクが余白・黒枠・文字帯を含んでいる場合、複合スコアが僅差（0.03以内かつIoU 0.74以上）なら
        // 余白を抱え込まない引き締まった（最小面積）マスクを優先する
        let nearTop = valid.filter { $0.composite >= best.composite - 0.03 && $0.iou >= 0.74 }
        guard !nearTop.isEmpty else { return best }
        return nearTop.min { lhs, rhs in
            if lhs.area != rhs.area { return lhs.area < rhs.area }
            return lhs.composite > rhs.composite
        }
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
        guard samW >= expectedW * 0.78 && samW <= expectedW * 1.05
            && samH >= expectedH * 0.78 && samH <= expectedH * 1.05 else {
            return false
        }
        let area = Double(mask.reduce(0) { $0 + ($1 ? 1 : 0) })
        guard area >= (expectedW * expectedH) * 0.58 else {
            return false
        }
        let expectedCx = (Double(promptBox.minX + promptBox.maxX) * 0.5 + 0.5) / Double(refW) * Double(w)
        let expectedCy = (Double(promptBox.minY + promptBox.maxY) * 0.5 + 0.5) / Double(refH) * Double(h)
        let samCx = Double(samBox.minX + samBox.maxX) * 0.5 + 0.5
        let samCy = Double(samBox.minY + samBox.maxY) * 0.5 + 0.5
        return abs(samCx - expectedCx) <= expectedW * 0.12
            && abs(samCy - expectedCy) <= expectedH * 0.12
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

    private struct IntBox { var minX, minY, maxX, maxY: Int }

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
        let refT = cardRef(topBg + Int(Double(H) * 0.005), topBg + Int(Double(H) * 0.02), bgRef: topBgRef)
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

        if let ref = refT ?? refB {
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
                newY1 = max(y0 + 32, y - 3)
            }
        }
        y1 = newY1
    }

    /// U-Net / SAM が明るい天井や空などの写真上部を過小予測した場合に、
    /// フル解像度 RGB と実測台紙色 (cardRGB) から写真本体の物理上端境界まで安全に外側（上方向）へ復元する
    private static func recoverOvercroppedTopEdgeRGB(
        rgb: [UInt8],
        srcW: Int,
        srcH: Int,
        cLx0: Int, cLx1: Int, cLy0: inout Int, cLy1: Int,
        cRx0: Int, cRx1: Int, cRy0: inout Int, cRy1: Int,
        cardRGB: (r: Double, g: Double, b: Double)
    ) {
        guard srcW >= 64, srcH >= 64, rgb.count >= srcW * srcH * 3 else { return }
        let cLuma = (cardRGB.r + cardRGB.g + cardRGB.b) / 3.0

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

        func recoverSide(x0: Int, x1: Int, y0: Int, y1: Int) -> Int {
            let bw = x1 - x0
            let bh = y1 - y0
            guard bw >= 48, bh >= 64, y0 >= 4 else { return y0 }
            let sx0 = max(0, x0 + bw / 4)
            let sx1 = min(srcW, x1 - bw / 4)
            guard sx1 > sx0 + 4 else { return y0 }
            let step = max(1, (sx1 - sx0) / 64)

            func analyzeRow(_ y: Int) -> (bgRatio: Double, darkRatio: Double, distCard: Double, meanLuma: Double, scanMatch: Bool) {
                let cy = min(srcH - 1, max(0, y))
                let rowOff = cy * srcW * 3
                var rSum = 0.0, gSum = 0.0, bSum = 0.0
                var bgCnt = 0, darkCnt = 0, n = 0
                rgb.withUnsafeBufferPointer { ptr in
                    guard let base = ptr.baseAddress else { return }
                    var x = sx0
                    while x < sx1 {
                        let i = rowOff + x * 3
                        let r = Double(base[i]), g = Double(base[i + 1]), b = Double(base[i + 2])
                        let luma = (r + g + b) / 3.0
                        rSum += r; gSum += g; bSum += b
                        if max(abs(r - cardRGB.r), max(abs(g - cardRGB.g), abs(b - cardRGB.b))) <= 28.0 {
                            bgCnt += 1
                        }
                        if luma <= 85.0 {
                            darkCnt += 1
                        }
                        n += 1
                        x += step
                    }
                }
                guard n > 0 else { return (1.0, 0.0, 0.0, cLuma, false) }
                let mr = rSum / Double(n), mg = gSum / Double(n), mb = bSum / Double(n)
                let ml = (mr + mg + mb) / 3.0
                let dist = sqrt(pow(mr - cardRGB.r, 2) + pow(mg - cardRGB.g, 2) + pow(mb - cardRGB.b, 2))
                let maxDiffTop = max(abs(mr - topMeanR), max(abs(mg - topMeanG), abs(mb - topMeanB)))
                let scanMatch = (hasWhiteScan && (ml >= 212.0 || maxDiffTop <= 28.0))
                    || (hasBlackScan && (ml <= 38.0 || maxDiffTop <= 28.0))
                return (Double(bgCnt) / Double(n), Double(darkCnt) / Double(n), dist, ml, scanMatch)
            }

            let maxExpand = min(Int(Double(bh) * 0.20), Int(Double(srcH) * 0.18))
            let limitY = max(0, y0 - maxExpand)
            let minGain = max(4, Int(Double(srcH) * 0.012))
            guard y0 - 1 >= limitY else { return y0 }

            var candY = y0
            var bgSum = 0.0
            var distSum = 0.0
            var steps = 0

            for y in stride(from: y0 - 1, through: limitY, by: -1) {
                let st = analyzeRow(y)
                if st.bgRatio >= 0.35 || st.distCard < 26.0 { break }
                if st.scanMatch { break }
                if cLuma >= 115.0 && st.meanLuma >= max(210.0, cLuma + 22.0) { break }
                if cLuma >= 115.0 && ((st.darkRatio >= 0.45 && st.meanLuma <= 95.0) || st.darkRatio >= 0.55) { break }
                candY = y
                bgSum += st.bgRatio
                distSum += st.distCard
                steps += 1
            }

            guard steps >= minGain else { return y0 }
            let meanBg = bgSum / Double(steps)
            let meanDist = distSum / Double(steps)
            guard meanBg <= 0.15, meanDist >= 32.0 else { return y0 }

            var boundaryOK = (candY <= 2)
            if !boundaryOK && candY >= 1 {
                for k in 1...min(5, candY) {
                    let st = analyzeRow(candY - k)
                    if st.bgRatio >= 0.45 || (cLuma >= 115.0 && st.darkRatio >= 0.50) {
                        boundaryOK = true
                        break
                    }
                }
            }
            guard boundaryOK else { return y0 }

            let inset = max(2, Int(Double(bh) * 0.004))
            return min(y0, candY + inset)
        }

        cLy0 = recoverSide(x0: cLx0, x1: cLx1, y0: cLy0, y1: cLy1)
        cRy0 = recoverSide(x0: cRx0, x1: cRx1, y0: cRy0, y1: cRy1)
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
        cardRGB: (r: Double, g: Double, b: Double)?
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
            let capLimitY = max(yTop + 48, yBot - maxScan)
            if currentY1 > capLimitY + 3 {
                var sumBgRatio = 0.0
                var rowCount = 0
                var photoStreak = 0
                var missBudget = 0
                var lastMarginY: Int? = nil

                // 外縁から内側（上）へ向かって台紙・文字行を辿る
                for y in stride(from: currentY1 - 1, through: capLimitY, by: -1) {
                    let st = analyzeRow(y, x0: sx0, x1: sx1)
                    let isMarginOrTextRow = st.bgRatio >= 0.42
                    let isDarkRuleRow = st.darkRatio >= 0.62 && st.std <= 28.0
                    if isMarginOrTextRow || isDarkRuleRow {
                        sumBgRatio += st.bgRatio
                        rowCount += 1
                        photoStreak = 0
                        missBudget = 0
                        lastMarginY = y
                    } else if st.bgRatio >= 0.28 && missBudget < 2 && rowCount >= 1 {
                        // キャプション文字密度が濃い1〜2行を跨ぐための極小許容（写真側侵入は連続判定で弾く）
                        sumBgRatio += st.bgRatio
                        rowCount += 1
                        missBudget += 1
                    } else {
                        photoStreak += 1
                        if photoStreak >= 3 {
                            // 連続3行以上明確な写真領域に突入 → 直前までが台紙/文字帯の候補
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
                        inside1.bgRatio < 0.40 && inside2.bgRatio < 0.40 &&
                        (diff >= 18.0 || inside1.distCard >= 18.0 || inside1.std >= 11.0)
                    if overallBgMean >= 0.50 && hasBoundaryTransition {
                        currentY1 = min(currentY1, max(yTop + 32, borderY))
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
            let fw = fullX1 - fullX0
            let cx0 = max(0, fullX0 + (fw * 3) / 10)
            let cx1 = min(srcW, fullX0 + (fw * 7) / 10)
            if cx1 - cx0 >= 16 {
                let pureMaxScan = min(Int(Double(bh) * 0.14), Int(Double(srcH) * 0.13))
                let limitPureY = min(yBot - 48, yTop + pureMaxScan)
                let skipLimit = min(limitPureY, yTop + 6)
                var pStart = yTop
                while pStart < skipLimit {
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
                        let st = analyzeRow(pEnd, x0: cx0, x1: cx1)
                        if st.bgRatio >= 0.85 && st.distCard <= 13.0 && st.std <= 10.0 {
                            pureRun += 1
                            pEnd += 1
                        } else {
                            break
                        }
                    }
                    if pureRun >= 6 && pEnd < limitPureY {
                        return max(yTop, min(yBot - 32, pEnd))
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
                sumBg += (st.bgRatio + (st.darkRatio >= 0.65 && st.std <= 26 ? 0.6 : 0.0))
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

        // 左ボックスの外端トリミング
        let bwL = boxL.maxX - boxL.minX
        if bwL >= 32 {
            let i0 = max(1, boxL.minX + Int(Double(bwL) * 0.25))
            let i1 = min(maskW - 2, boxL.maxX - Int(Double(bwL) * 0.15))
            if i1 > i0 + 4 {
                let sortedL = grad[i0...i1].sorted()
                let baseL = sortedL[sortedL.count / 2]
                let thL = max(32.0, baseL * 3.5)
                let searchEnd = min(maskW - 2, boxL.minX + Int(Double(bwL) * 0.16))
                let searchStart = max(1, boxL.minX + 3)
                if searchEnd >= searchStart {
                    var newMinX = boxL.minX
                    for x in searchStart...searchEnd where grad[x] >= thL {
                        newMinX = x + 1
                    }
                    if newMinX > boxL.minX && boxL.maxX - newMinX >= 32 {
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
                let thR = max(32.0, baseR * 3.5)
                let searchStart = max(1, boxR.maxX - Int(Double(bwR) * 0.16))
                let searchEnd = min(maskW - 2, boxR.maxX - 3)
                if searchEnd >= searchStart {
                    var newMaxX = boxR.maxX
                    for x in (searchStart...searchEnd).reversed() where grad[x] >= thR {
                        newMaxX = x - 1
                    }
                    if newMaxX < boxR.maxX && newMaxX - boxR.minX >= 32 {
                        boxR.maxX = newMaxX
                    }
                }
            }
        }
    }

    /// 突出した数pxの波打ち（台紙残り）を無視して直線エッジを捉えるロバスト外接矩形
    private func robustBoundingBox(mask: [Bool], w: Int, h: Int) -> IntBox? {
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
            let cwTop = max(4, Int(Double(bw) * 0.36))
            let chTop = max(4, Int(Double(bh) * 0.40))
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
        let hasBot = rBot >= 0.045
        return ArchShapeParams(
            topRxRatio: hasTop ? min(0.38, rTop * 1.02) : 0.0,
            topRyRatio: hasTop ? min(0.35, rTop * 1.02) : 0.0,
            botRxRatio: hasBot ? min(0.34, rBot * 1.02) : 0.0,
            botRyRatio: hasBot ? min(0.34, rBot * 1.02) : 0.0
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
    ) -> (rxRatio: Double, ryRatio: Double)? {
        guard w >= 64, h >= 64, leftRGB.count >= w * h * 3, rightRGB.count >= w * h * 3 else { return nil }
        if isCornersSquareRGB(leftRGB: leftRGB, rightRGB: rightRGB, width: w, height: h, cardRGB: cardRGB, isTop: isTop) {
            return nil
        }

        let maxScanX = min(w / 2, Int(Double(w) * 0.44))
        let maxScanY = min(h / 2, Int(Double(h) * 0.40))
        guard maxScanX >= 12, maxScanY >= 12 else { return nil }

        let runLen = max(6, min(14, Int(Double(h) * 0.014)))
        let nonCardReq = runLen - max(1, runLen / 6)

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

        func tryMeasure(refCol: (r: Double, g: Double, b: Double), tol: Double) -> (rxRatio: Double, ryRatio: Double)? {
            func isBg(_ rgb: [UInt8], _ x: Int, _ y: Int) -> Bool {
                let idx = (y * w + x) * 3
                let dr = abs(Double(rgb[idx]) - refCol.r)
                let dg = abs(Double(rgb[idx + 1]) - refCol.g)
                let db = abs(Double(rgb[idx + 2]) - refCol.b)
                return max(dr, max(dg, db)) <= tol
            }

            func columnDrop(_ rgb: [UInt8], x: Int) -> Int {
                guard maxScanY > runLen else { return 0 }
                for dy in 0..<(maxScanY - runLen) {
                    var nonCardRun = 0
                    for k in 0..<runLen {
                        let y = isTop ? (dy + k) : (h - 1 - (dy + k))
                        if !isBg(rgb, x, y) { nonCardRun += 1 }
                    }
                    if nonCardRun >= nonCardReq { return dy }
                }
                return maxScanY - runLen
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
            guard dropCenterRatio <= 0.065 else { return nil }

            // L 外側・R 外側の隅先端に十分な背景色が存在することを確認（片側欠けでの誤爆防止）
            var cornerHitsL = 0
            var cornerHitsR = 0
            for dy in 2..<min(10, maxScanY) {
                let y = isTop ? dy : (h - 1 - dy)
                for dx in 2..<min(10, maxScanX) {
                    if isBg(leftRGB, dx, y) { cornerHitsL += 1 }
                    if isBg(rightRGB, w - 1 - dx, y) { cornerHitsR += 1 }
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
                if min(dL, dR) >= symMinThreshold || (dx <= stepX * 2 && min(dL, dR) >= 4) {
                    let hi = max(dL, dR), lo = min(dL, dR)
                    if Double(hi) > Double(lo) * 1.6 + Double(h) * 0.04 {
                        drop = Double(lo)
                    } else {
                        drop = Double(dL + dR) * 0.5
                    }
                } else {
                    drop = Double(min(dL, dR))
                }
                let fy = drop / Double(h)
                profile.append((Double(dx) / Double(w), fy))
                if fy < 0.005 {
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
                  maxFy - dropCenterRatio >= 0.050 else {
                return nil
            }

            // 直接 L1 非対称楕円フィッティング
            var bestLoss = Double.greatestFiniteMagnitude
            var bestRx = 0.0
            var bestRy = 0.0
            for ixStep in 6...42 {
                let rx = Double(ixStep) * 0.01
                for iyStep in 6...36 {
                    let ry = Double(iyStep) * 0.01
                    guard rx >= ry * 0.88 && rx <= ry * 1.65 else { continue }
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
                    }
                }
            }
            guard bestRx > 0.0 && bestRy > 0.0 else { return nil }
            return (min(0.42, bestRx + 0.008), min(0.36, bestRy + 0.008))
        }

        for (ref, tol) in [(cardRGB, 24.0), (localBg, 18.0), (localBg, 14.0)] {
            if let res = tryMeasure(refCol: ref, tol: tol) {
                return res
            }
        }
        return nil
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

        // 外側から内側へ向かって最大 20% 範囲でマージン/縦文字/黒枠境界を探索（dir = +1: cLx0→右, -1: cRx1-1→左）
        func scanOuterEdge(startEdge: Int, dir: Int, widthBound: Int, y0: Int, y1: Int) -> Int? {
            let maxTrim = min(Int(Double(widthBound) * 0.20), max(4, widthBound - 64))
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
            var pureRun = 0
            var bestCutIdx: Int? = nil
            var prefixBgSum = 0.0
            for idx in 0..<validLen {
                let st = cols[idx]
                prefixBgSum += st.bgRatio
                let isPure = st.bgRatio >= 0.66 && st.std <= 20.0
                let prevIsNearPure = idx > 0 && cols[idx - 1].bgRatio >= 0.64
                if isPure {
                    pureRun += 1
                    if idx < 4 || pureRun >= 2 || (prevIsNearPure && st.std <= 16.0) {
                        let meanPrefixBg = prefixBgSum / Double(idx + 1)
                        if meanPrefixBg >= 0.36 {
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
                    // 黒枠始まり1列目の抗エイリアス滲みだけ darkRatio >= 0.45 && 次が濃厚黒枠なら開始可
                    let isStartAntiAlias = darkRun == 0 && idx + 1 < validLen
                        && st.darkRatio >= 0.45 && cols[idx + 1].darkRatio >= 0.64 && st.std <= 36.0
                    if (st.darkRatio >= 0.62 && st.std <= 32.0 && st.meanLuma <= 88.0) || isStartAntiAlias {
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

        if let newLx0 = scanOuterEdge(startEdge: cLx0, dir: 1, widthBound: cLx1 - cLx0, y0: cLy0, y1: cLy1),
           newLx0 > cLx0 && cLx1 - newLx0 >= 64 {
            cLx0 = newLx0
        }

        if let newRx1 = scanOuterEdge(startEdge: cRx1 - 1, dir: -1, widthBound: cRx1 - cRx0, y0: cRy0, y1: cRy1),
           newRx1 < cRx1 && newRx1 - cRx0 >= 64 {
            cRx1 = newRx1
        }

        // 3. 中央セパレータ（cLx1, cRx0）の半端残りの太黒枠エッジを微調整除去（cardLuma >= 115 のみ）
        if cardLuma >= 115.0 {
            let maxCenterTrimL = min(12, max(2, (cLx1 - cLx0) / 32))
            var trimmedL = cLx1
            for dx in 0..<maxCenterTrimL {
                let x = cLx1 - 1 - dx
                let st = analyzeCol(x: x, y0: cLy0, y1: cLy1)
                if st.darkRatio >= 0.66 && st.std <= 30.0 && st.meanLuma <= 90.0 {
                    trimmedL = x
                } else {
                    break
                }
            }
            if trimmedL < cLx1 && trimmedL - cLx0 >= 64 {
                cLx1 = trimmedL
            }

            let maxCenterTrimR = min(12, max(2, (cRx1 - cRx0) / 32))
            var trimmedR = cRx0
            for dx in 0..<maxCenterTrimR {
                let x = cRx0 + dx
                let st = analyzeCol(x: x, y0: cRy0, y1: cRy1)
                if st.darkRatio >= 0.66 && st.std <= 30.0 && st.meanLuma <= 90.0 {
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

    /// 画像枠の上下左右に存在する完全な黒余白（スキャン黒帯やレターボックス・ピラーボックス黒枠）を検出し、
    /// 左右写真ペアから余計な外周黒枠を均等にトリミングする
    private static func trimOuterBlackBorders(
        leftRGB: inout [UInt8],
        rightRGB: inout [UInt8],
        width w: inout Int,
        height h: inout Int
    ) {
        guard w >= 64, h >= 64, leftRGB.count >= w * h * 3, rightRGB.count >= w * h * 3 else { return }
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

        guard trimTop > 0 || trimBot > 0 || trimLeft > 0 || trimRight > 0 else { return }
        let newW = w - trimLeft - trimRight
        let newH = h - trimTop - trimBot
        guard newW >= 64, newH >= 64 else { return }

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

        leftRGB = croppedL
        rightRGB = croppedR
        w = newW
        h = newH
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

            // 上マージン（カード内 yTop より上）
            let topLo = max(cardY0, min(yTop - 2, yTop - 22))
            let topHi = max(topLo, min(srcH - 2, yTop - 2))
            if topHi > topLo && sx1 > sx0 {
                let yStep = max(1, (topHi - topLo) / 10)
                var y = topLo
                while y < topHi {
                    var x = sx0
                    while x < sx1 { collectPoint(x, y); x += xStep }
                    y += yStep
                }
            }

            // 下マージン（カード内 yBot より下）
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

            // 左右マージン（面積広く安定しているため密にサンプル収集）
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
                for y in max(cardY0, yTop)..<min(cardY1, yTop + bandY) {
                    var x = sx0
                    while x < sx1 { collectBorderFlat(x, y); x += xStep }
                }
                for y in max(cardY0, yBot - bandY)..<min(cardY1, yBot) {
                    var x = sx0
                    while x < sx1 { collectBorderFlat(x, y); x += xStep }
                }
                if let xL = xLeft {
                    for x in max(cardX0, xL)..<min(cardX1, xL + bandX) {
                        var y = my0
                        while y < my1 { collectBorderFlat(x, y); y += yStep }
                    }
                }
                if let xR = xRight {
                    for x in max(cardX0, xR - bandX)..<min(cardX1, xR) {
                        var y = my0
                        while y < my1 { collectBorderFlat(x, y); y += yStep }
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
    static func applyParametricArchMask(
        _ rgb: inout [UInt8],
        width w: Int,
        height h: Int,
        params: ArchShapeParams,
        extraInsetRatio: Double = 0.015,
        edgeInsets: (top: Int, bottom: Int, left: Int, right: Int) = (0, 0, 0, 0)
    ) {
        guard w >= 16, h >= 16, rgb.count >= w * h * 3 else { return }
        let fw = Double(w)
        let fh = Double(h)

        let hasTopRound = (params.topRxRatio > 0.005 && params.topRyRatio > 0.005)
        let hasBotRound = (params.botRxRatio > 0.005 && params.botRyRatio > 0.005)

        let insetX = fw * max(0.0, extraInsetRatio)
        let insetYTop = fh * max(0.0, extraInsetRatio)
        // 下端に角丸がない（アーチトップ型）場合は、足先や車輪底の被写体を切断しないよう下端インセットはゼロ
        let insetYBot = hasBotRound ? (fh * max(0.0, extraInsetRatio)) : 0.0

        let x0 = insetX + Double(edgeInsets.left)
        let x1 = fw - insetX - Double(edgeInsets.right)
        let y0 = insetYTop + Double(edgeInsets.top)
        let y1 = fh - insetYBot - Double(edgeInsets.bottom)
        let innerW = max(8.0, x1 - x0)
        let innerH = max(8.0, y1 - y0)

        let rxTop = hasTopRound ? max(2.0, innerW * params.topRxRatio) : 0.0
        let ryTop = hasTopRound ? max(2.0, innerH * params.topRyRatio) : 0.0
        let rxBot = hasBotRound ? max(2.0, innerW * params.botRxRatio) : 0.0
        let ryBot = hasBotRound ? max(2.0, innerH * params.botRyRatio) : 0.0

        let topScale = min(rxTop, ryTop)
        let botScale = min(rxBot, ryBot)
        let safeY0 = Int(ceil(y0 + ryTop + 2.5))
        let safeY1 = hasBotRound ? Int(floor(y1 - ryBot - 2.5)) : h
        let safeX0 = Int(ceil(x0 + 2.5))
        let safeX1 = Int(floor(x1 - 2.5))

        rgb.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for y in 0..<h {
                let py = Double(y) + 0.5
                let dTop = py - y0
                let dBot = hasBotRound ? (y1 - py) : (fh - py + 2.0)
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
                    let dLeft = px - x0
                    let dRight = x1 - px
                    var d = min(min(dLeft, dRight), dY)

                    if d > -1.5 {
                        if hasTopRound && py < y0 + ryTop {
                            if px < x0 + rxTop {
                                let nx = (x0 + rxTop - px) / rxTop
                                let ny = (y0 + ryTop - py) / ryTop
                                let dCorner = (1.0 - hypot(nx, ny)) * topScale
                                d = min(d, dCorner)
                            } else if px > x1 - rxTop {
                                let nx = (px - (x1 - rxTop)) / rxTop
                                let ny = (y0 + ryTop - py) / ryTop
                                let dCorner = (1.0 - hypot(nx, ny)) * topScale
                                d = min(d, dCorner)
                            }
                        } else if hasBotRound && py > y1 - ryBot {
                            if px < x0 + rxBot {
                                let nx = (x0 + rxBot - px) / rxBot
                                let ny = (py - (y1 - ryBot)) / ryBot
                                let dCorner = (1.0 - hypot(nx, ny)) * botScale
                                d = min(d, dCorner)
                            } else if px > x1 - rxBot {
                                let nx = (px - (x1 - rxBot)) / rxBot
                                let ny = (py - (y1 - ryBot)) / ryBot
                                let dCorner = (1.0 - hypot(nx, ny)) * botScale
                                d = min(d, dCorner)
                            }
                        }
                    }

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
        if let card = cardLuma, w >= 64, h >= 64 {
            let a = residualBorderInsets(left, width: w, height: h, cardLuma: card)
            let b = residualBorderInsets(right, width: w, height: h, cardLuma: card)
            // 下端（bottom）は地面や靴・服の暗部と台紙輝度が一致して誤爆しやすいため、
            // 足先や車輪の過度な切り上げを防ぐため bottom のインセットは行わない（0に固定）
            insets = (max(a.top, b.top), 0, max(a.left, b.left), max(a.right, b.right))
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
    private func cropRotatedRGB(
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

    private func makeCGImage(from rgb: [UInt8], width: Int, height: Int) -> CGImage? {
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
    case originalRemount = "Original Mount (Remount)"
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
        case .originalRemount, .autoSampleColor:
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
        case .earlyIvory, .originalRemount:
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
        case .chromeYellow, .vividTerracotta, .victorianGreen, .keystoneDark, .autoSampleColor, .originalRemount:
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
    var preset: StereoCardMountPreset = .originalRemount
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
        transparentOuterCorners: Bool
    ) -> (rgba: [UInt8], width: Int, height: Int) {
        guard printWidth >= 16, printHeight >= 16,
              leftRGB.count >= printWidth * printHeight * 3,
              rightRGB.count >= printWidth * printHeight * 3 else {
            return ([UInt8](repeating: 0, count: 64 * 32 * 4), 64, 32)
        }

        // 1. 「元台紙を復元 (Original Mount Remount)」かつ元カードのコンテキストが存在する場合
        if config.preset == .originalRemount, let ctx = mountContext {
            return renderOriginalMountRemount(
                leftRGB: leftRGB,
                rightRGB: rightRGB,
                printWidth: printWidth,
                printHeight: printHeight,
                config: config,
                ctx: ctx,
                transparentOuterCorners: transparentOuterCorners
            )
        }

        // 2. プロシージャル年代別台紙（または元カード色スポイト台紙）の生成
        return renderProceduralMount(
            leftRGB: leftRGB,
            rightRGB: rightRGB,
            printWidth: printWidth,
            printHeight: printHeight,
            config: config,
            mountContext: mountContext,
            transparentOuterCorners: transparentOuterCorners
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
        backgroundColor: (r: UInt8, g: UInt8, b: UInt8) = (18, 18, 20)
    ) -> (rgb: [UInt8], width: Int, height: Int) {
        let (rgba, cw, ch) = renderCardRGBA(
            leftRGB: leftRGB,
            rightRGB: rightRGB,
            printWidth: printWidth,
            printHeight: printHeight,
            config: config,
            mountContext: mountContext,
            transparentOuterCorners: true
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

    // MARK: - Mode A: 元台紙のデジタル・リマウント (Original Mount Restoration)

    private static func renderOriginalMountRemount(
        leftRGB: [UInt8],
        rightRGB: [UInt8],
        printWidth: Int,
        printHeight: Int,
        config: StereoCardMountConfig,
        ctx: StereoCardSegmenter.OriginalCardMountContext,
        transparentOuterCorners: Bool
    ) -> (rgba: [UInt8], width: Int, height: Int) {
        let origSlotW = max(1, min(ctx.leftBox.x1 - ctx.leftBox.x0, ctx.rightBox.x1 - ctx.rightBox.x0))
        let scaleRatio = Double(printWidth) / Double(origSlotW)
        let targetCardW: Int
        let targetCardH: Int
        let workingCardRGB: [UInt8]
        let scaleX: Double
        let scaleY: Double

        if scaleRatio < 0.72 && ctx.cardWidth > 900 {
            targetCardW = max(400, Int((Double(ctx.cardWidth) * scaleRatio).rounded()))
            targetCardH = max(200, Int((Double(ctx.cardHeight) * scaleRatio).rounded()))
            workingCardRGB = resizeBilinearRGB(ctx.cardRGB, sw: ctx.cardWidth, sh: ctx.cardHeight, dw: targetCardW, dh: targetCardH)
            scaleX = Double(targetCardW) / Double(ctx.cardWidth)
            scaleY = Double(targetCardH) / Double(ctx.cardHeight)
        } else {
            targetCardW = ctx.cardWidth
            targetCardH = ctx.cardHeight
            workingCardRGB = ctx.cardRGB
            scaleX = 1.0
            scaleY = 1.0
        }

        // Step 1: スキャン時の台紙傾き（Deskew）補正
        var canvasRGB: [UInt8]
        if abs(ctx.skewAngleRad * 180.0 / .pi) >= 0.15 {
            canvasRGB = rotateFullImageRGB(
                workingCardRGB,
                width: targetCardW,
                height: targetCardH,
                angleRad: ctx.skewAngleRad,
                fillRGB: ctx.sampledCardRGB
            )
        } else {
            canvasRGB = workingCardRGB
        }

        let lx0 = max(0, min(targetCardW - 1, Int((Double(ctx.leftBox.x0) * scaleX).rounded())))
        let ly0 = max(0, min(targetCardH - 1, Int((Double(ctx.leftBox.y0) * scaleY).rounded())))
        let lx1 = max(lx0 + 1, min(targetCardW, Int((Double(ctx.leftBox.x1) * scaleX).rounded())))
        let ly1 = max(ly0 + 1, min(targetCardH, Int((Double(ctx.leftBox.y1) * scaleY).rounded())))

        let rx0 = max(0, min(targetCardW - 1, Int((Double(ctx.rightBox.x0) * scaleX).rounded())))
        let ry0 = max(0, min(targetCardH - 1, Int((Double(ctx.rightBox.y0) * scaleY).rounded())))
        let rx1 = max(rx0 + 1, min(targetCardW, Int((Double(ctx.rightBox.x1) * scaleX).rounded())))
        let ry1 = max(ry0 + 1, min(targetCardH, Int((Double(ctx.rightBox.y1) * scaleY).rounded())))

        let cutStyle: StereoCardPrintCutStyle = (config.printCutStyle == .autoFromPreset) ? .archTop : config.printCutStyle
        let archParams = resolveArchParams(
            cutStyle: cutStyle,
            aiArchParams: ctx.archParams,
            useAIArch: config.printCutStyle == .autoFromPreset
        )

        // Step 2: 旧印画領域の「中央谷間（594等）＆下部文字保護付き・台紙ヒーリング」
        healPhotoSlotOnMount(
            canvasRGB: &canvasRGB,
            cardW: targetCardW,
            cardH: targetCardH,
            slot: (x0: lx0, y0: ly0, x1: lx1, y1: ly1),
            archParams: archParams,
            baseColor: ctx.sampledCardRGB,
            seedOffset: 101
        )
        healPhotoSlotOnMount(
            canvasRGB: &canvasRGB,
            cardW: targetCardW,
            cardH: targetCardH,
            slot: (x0: rx0, y0: ry0, x1: rx1, y1: ry1),
            archParams: archParams,
            baseColor: ctx.sampledCardRGB,
            seedOffset: 202
        )

        // Step 3: 整準・立体窓調整済みプリントのシンメトリック再貼付（SBS表示の完全なアスペクト比・全構図を100%維持）
        let slotLW = lx1 - lx0
        let slotLH = ly1 - ly0
        let slotRW = rx1 - rx0
        let slotRH = ry1 - ry0

        let maxSlotW = max(16, min(slotLW, slotRW))
        let maxSlotH = max(16, min(slotLH, slotRH))

        let printAspect = Double(printWidth) / Double(printHeight)
        let slotAspect = Double(maxSlotW) / Double(maxSlotH)

        // 写真をクロップ（ズーム拡大）せず、SBS表示と同一の全ピクセルが収まる Aspect Fit サイズを算出
        let dstPrintW: Int
        let dstPrintH: Int
        if printAspect > slotAspect {
            dstPrintW = maxSlotW
            dstPrintH = max(16, Int((Double(maxSlotW) / printAspect).rounded()))
        } else {
            dstPrintH = maxSlotH
            dstPrintW = max(16, Int((Double(maxSlotH) * printAspect).rounded()))
        }

        let centerLY = Double(ly0 + ly1) * 0.5
        let centerRY = Double(ry0 + ry1) * 0.5
        let syncCenterY = (centerLY + centerRY) * 0.5
        let pasteY = max(0, min(targetCardH - dstPrintH, Int((syncCenterY - Double(dstPrintH) * 0.5).rounded())))

        let centerLX = Double(lx0 + lx1) * 0.5
        let centerRX = Double(rx0 + rx1) * 0.5
        let pasteLX = max(0, min(targetCardW - dstPrintW, Int((centerLX - Double(dstPrintW) * 0.5).rounded())))
        let pasteRX = max(0, min(targetCardW - dstPrintW, Int((centerRX - Double(dstPrintW) * 0.5).rounded())))

        // クロップ・ズームを排除し、アスペクト比100%維持の高品質バイリニア変倍でSBSと全く同一の構図を保つ
        let scaledL = resizeBilinearRGB(leftRGB, sw: printWidth, sh: printHeight, dw: dstPrintW, dh: dstPrintH)
        let scaledR = resizeBilinearRGB(rightRGB, sw: printWidth, sh: printHeight, dw: dstPrintW, dh: dstPrintH)

        pastePrintOntoMount(
            canvasRGB: &canvasRGB,
            cardW: targetCardW,
            cardH: targetCardH,
            printRGB: scaledL,
            pw: dstPrintW,
            ph: dstPrintH,
            dstX: pasteLX,
            dstY: pasteY,
            archParams: archParams
        )

        pastePrintOntoMount(
            canvasRGB: &canvasRGB,
            cardW: targetCardW,
            cardH: targetCardH,
            printRGB: scaledR,
            pw: dstPrintW,
            ph: dstPrintH,
            dstX: pasteRX,
            dstY: pasteY,
            archParams: archParams
        )

        if config.textMode == .manualTypeset {
            drawLetterpressTypography(
                canvasRGB: &canvasRGB,
                cardW: targetCardW,
                cardH: targetCardH,
                leftPrintRect: CGRect(x: pasteLX, y: pasteY, width: dstPrintW, height: dstPrintH),
                rightPrintRect: CGRect(x: pasteRX, y: pasteY, width: dstPrintW, height: dstPrintH),
                archParams: archParams,
                mountBaseRGB: ctx.sampledCardRGB,
                config: config
            )
        }

        let rgba = convertMountToRGBA(
            canvasRGB: canvasRGB,
            width: targetCardW,
            height: targetCardH,
            roundedCorners: true,
            transparentCorners: transparentOuterCorners
        )
        return (rgba, targetCardW, targetCardH)
    }

    // MARK: - Mode B: 年代別プロシージャル台紙生成 + 4領域インク転写 / 活版組版印字

    private static func renderProceduralMount(
        leftRGB: [UInt8],
        rightRGB: [UInt8],
        printWidth: Int,
        printHeight: Int,
        config: StereoCardMountConfig,
        mountContext: StereoCardSegmenter.OriginalCardMountContext?,
        transparentOuterCorners: Bool
    ) -> (rgba: [UInt8], width: Int, height: Int) {
        let effectivePreset: StereoCardMountPreset = (config.preset == .originalRemount) ? .keystoneDark : config.preset
        let baseRGB: (r: UInt8, g: UInt8, b: UInt8)
        if effectivePreset == .autoSampleColor, let ctx = mountContext {
            baseRGB = ctx.sampledCardRGB
        } else if config.preset == .originalRemount, let ctx = mountContext {
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
        let topMarginInches = 0.095
        let bottomMarginInches = 0.345
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
        let pasteY = topMarginPx + max(0, (slotH - dstPrintH) / 2)

        // 2. 台紙ベース（カラー + 曲面マウント陰影 + 紙質グレイン + 1870sバイカラーベベル）の生成
        var canvasRGB = generateMountBoardSurface(
            width: cardW,
            height: cardH,
            baseRGB: baseRGB,
            curvedShading: effectivePreset.hasCurvedMountShading,
            bicolorEdge: effectivePreset.bicolorEdgeRGB
        )

        // 3. 左右プリントの変倍 & ドームアーチ貼付合成（クロップなしの高品質リサイズ）
        let scaledL = resizeBilinearRGB(leftRGB, sw: printWidth, sh: printHeight, dw: dstPrintW, dh: dstPrintH)
        let scaledR = resizeBilinearRGB(rightRGB, sw: printWidth, sh: printHeight, dw: dstPrintW, dh: dstPrintH)

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
            archParams: archParams
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
            archParams: archParams
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

    // MARK: - 旧印画枠の台紙ヒーリング（中央上部アーチ谷間の番号 594 & 下部タイトル文字保護付き）

    private static func healPhotoSlotOnMount(
        canvasRGB: inout [UInt8],
        cardW: Int,
        cardH: Int,
        slot: (x0: Int, y0: Int, x1: Int, y1: Int),
        archParams: StereoCardSegmenter.ArchShapeParams,
        baseColor: (r: UInt8, g: UInt8, b: UInt8),
        seedOffset: UInt64
    ) {
        let padX = max(1, Int(Double(cardW) * 0.002))
        let padTop = max(1, Int(Double(cardH) * 0.002))
        let padBot = max(1, Int(Double(cardH) * 0.0015))

        let hx0 = max(0, slot.x0 - padX)
        let hx1 = min(cardW, slot.x1 + padX)
        let hy0 = max(0, slot.y0 - padTop)
        let hy1 = min(cardH, slot.y1 + padBot)
        let hw = hx1 - hx0
        let hh = hy1 - hy0
        guard hw > 4, hh > 4 else { return }

        let baseR = Double(baseColor.r)
        let baseG = Double(baseColor.g)
        let baseB = Double(baseColor.b)
        let baseLuma = 0.299 * baseR + 0.587 * baseG + 0.114 * baseB

        func sampleMountStrip(xRange: Range<Int>, yRange: Range<Int>) -> (r: Double, g: Double, b: Double) {
            var rs: [Double] = []
            var gs: [Double] = []
            var bs: [Double] = []
            for y in yRange where y >= 0 && y < cardH {
                for x in xRange where x >= 0 && x < cardW {
                    let idx = (y * cardW + x) * 3
                    let r = Double(canvasRGB[idx])
                    let g = Double(canvasRGB[idx + 1])
                    let b = Double(canvasRGB[idx + 2])
                    let diff = abs(r - baseR) + abs(g - baseG) + abs(b - baseB)
                    if diff < 85.0 {
                        rs.append(r); gs.append(g); bs.append(b)
                    }
                }
            }
            guard !rs.isEmpty else { return (baseR, baseG, baseB) }
            rs.sort(); gs.sort(); bs.sort()
            let mid = rs.count / 2
            return (rs[mid], gs[mid], bs[mid])
        }

        let sampleBand = max(3, min(10, cardH / 90))
        let topColors = (0..<hw).map { dx -> (r: Double, g: Double, b: Double) in
            let x = hx0 + dx
            return sampleMountStrip(xRange: max(0, x - 4)..<min(cardW, x + 5), yRange: max(0, hy0 - sampleBand)..<hy0)
        }
        let botColors = (0..<hw).map { dx -> (r: Double, g: Double, b: Double) in
            let x = hx0 + dx
            return sampleMountStrip(xRange: max(0, x - 4)..<min(cardW, x + 5), yRange: hy1..<min(cardH, hy1 + sampleBand))
        }
        let leftColors = (0..<hh).map { dy -> (r: Double, g: Double, b: Double) in
            let y = hy0 + dy
            return sampleMountStrip(xRange: max(0, hx0 - sampleBand)..<hx0, yRange: max(0, y - 4)..<min(cardH, y + 5))
        }
        let rightColors = (0..<hh).map { dy -> (r: Double, g: Double, b: Double) in
            let y = hy0 + dy
            return sampleMountStrip(xRange: hx1..<min(cardW, hx1 + sampleBand), yRange: max(0, y - 4)..<min(cardH, y + 5))
        }

        let wF = Double(hw)
        let hF = Double(hh)
        // アーチ・角丸より少しだけ広い範囲までをヒーリングし、中央谷間（594の印字領域）等は元の台紙を完全保護する
        let healTopRx = max(0.0, (archParams.topRxRatio - 0.025) * wF)
        let healTopRy = max(0.0, (archParams.topRyRatio - 0.025) * hF)
        let healBotRx = max(0.0, (archParams.botRxRatio - 0.025) * wF)
        let healBotRy = max(0.0, (archParams.botRyRatio - 0.025) * hF)

        for dy in 0..<hh {
            let y = hy0 + dy
            let ty = Double(dy) / Double(max(1, hh - 1))
            let wy = 1.0 / (min(ty, 1.0 - ty) + 0.08)
            let lCol = leftColors[dy]
            let rCol = rightColors[dy]
            let isBottomFringe = (y >= slot.y1)

            for dx in 0..<hw {
                let x = hx0 + dx

                // 上下コーナー外側の元台紙領域（中央谷間の番号 594 等がある場所）を保護
                let alpha = archCornerAlpha(
                    x: Double(dx) + 0.5,
                    y: Double(dy) + 0.5,
                    w: wF,
                    h: hF,
                    topRx: healTopRx,
                    topRy: healTopRy,
                    botRx: healBotRx,
                    botRy: healBotRy
                )
                if alpha <= 0.05 {
                    continue
                }

                let idx = (y * cardW + x) * 3
                if isBottomFringe {
                    let curR = Double(canvasRGB[idx])
                    let curG = Double(canvasRGB[idx + 1])
                    let curB = Double(canvasRGB[idx + 2])
                    let curLuma = 0.299 * curR + 0.587 * curG + 0.114 * curB
                    if baseLuma - curLuma > 25.0 {
                        continue
                    }
                }

                let tx = Double(dx) / Double(max(1, hw - 1))
                let wx = 1.0 / (min(tx, 1.0 - tx) + 0.08)

                let tCol = topColors[dx]
                let bCol = botColors[dx]

                let vR = tCol.r * (1.0 - ty) + bCol.r * ty
                let vG = tCol.g * (1.0 - ty) + bCol.g * ty
                let vB = tCol.b * (1.0 - ty) + bCol.b * ty

                let hR = lCol.r * (1.0 - tx) + rCol.r * tx
                let hG = lCol.g * (1.0 - tx) + rCol.g * tx
                let hB = lCol.b * (1.0 - tx) + rCol.b * tx

                let wSum = wx + wy
                var outR = (hR * wx + vR * wy) / wSum
                var outG = (hG * wx + vG * wy) / wSum
                var outB = (hB * wx + vB * wy) / wSum

                let grain = paperGrainNoise(x: x, y: y, seed: seedOffset) * 2.2
                outR += grain
                outG += grain
                outB += grain * 0.9

                canvasRGB[idx]     = UInt8(max(0, min(255, Int(outR.rounded()))))
                canvasRGB[idx + 1] = UInt8(max(0, min(255, Int(outG.rounded()))))
                canvasRGB[idx + 2] = UInt8(max(0, min(255, Int(outB.rounded()))))
            }
        }
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
            let topRx = (ai.topRxRatio < 0.02 || ai.topRyRatio < 0.02) ? 0.0 : ai.topRxRatio
            let topRy = (ai.topRxRatio < 0.02 || ai.topRyRatio < 0.02) ? 0.0 : ai.topRyRatio
            let botRx = (ai.botRxRatio < 0.02 || ai.botRyRatio < 0.02) ? 0.0 : ai.botRxRatio
            let botRy = (ai.botRxRatio < 0.02 || ai.botRyRatio < 0.02) ? 0.0 : ai.botRyRatio
            return StereoCardSegmenter.ArchShapeParams(
                topRxRatio: topRx,
                topRyRatio: topRy,
                botRxRatio: botRx,
                botRyRatio: botRy
            )
        }
        switch cutStyle {
        case .autoFromPreset, .archTop:
            // 19世紀ステレオカード & Keystone 標準「上部ドームアーチ + 下部フラット直角」
            return StereoCardSegmenter.ArchShapeParams(
                topRxRatio: 0.34,
                topRyRatio: 0.22,
                botRxRatio: 0.0,
                botRyRatio: 0.0
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
        archParams: StereoCardSegmenter.ArchShapeParams
    ) {
        let w = Double(pw)
        let h = Double(ph)
        let topRx = max(0.0, archParams.topRxRatio * w)
        let topRy = max(0.0, archParams.topRyRatio * h)
        let botRx = max(0.0, archParams.botRxRatio * w)
        let botRy = max(0.0, archParams.botRyRatio * h)

        // 1. 印画の紙厚を表現する微細なドロップシャドウ（右下へ 1〜2px）
        let shadowOff = max(1, min(2, cardW / 1000))
        for py in 0..<ph {
            let cy = dstY + py + shadowOff
            guard cy >= 0 && cy < cardH else { continue }
            for px in 0..<pw {
                let cx = dstX + px + shadowOff
                guard cx >= 0 && cx < cardW else { continue }
                let alpha = archCornerAlpha(x: Double(px) + 0.5, y: Double(py) + 0.5, w: w, h: h, topRx: topRx, topRy: topRy, botRx: botRx, botRy: botRy)
                if alpha > 0.5 {
                    let cIdx = (cy * cardW + cx) * 3
                    canvasRGB[cIdx]     = UInt8(Double(canvasRGB[cIdx]) * 0.84)
                    canvasRGB[cIdx + 1] = UInt8(Double(canvasRGB[cIdx + 1]) * 0.84)
                    canvasRGB[cIdx + 2] = UInt8(Double(canvasRGB[cIdx + 2]) * 0.84)
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
                let alpha = archCornerAlpha(x: Double(px) + 0.5, y: Double(py) + 0.5, w: w, h: h, topRx: topRx, topRy: topRy, botRx: botRx, botRy: botRy)
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
        for i in 0..<count {
            let si = i * 3
            luma[i] = 0.299 * Double(rgb[si]) + 0.587 * Double(rgb[si + 1]) + 0.114 * Double(rgb[si + 2])
        }

        // 外周の黒フチを除いた内部ピクセルから背景輝度（70%tile）と文字輝度（2%tile）を推定
        var innerLumas: [Double] = []
        innerLumas.reserveCapacity(count)
        let mx = max(1, width / 20)
        let my = max(1, height / 10)
        for y in my..<(height - my) {
            for x in mx..<(width - mx) {
                let v = luma[y * width + x]
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
                let v = luma[y * width + x]
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
                .filter { !$0.isEmpty }
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

    private static func rotateFullImageRGB(
        _ src: [UInt8],
        width: Int,
        height: Int,
        angleRad: Double,
        fillRGB: (r: UInt8, g: UInt8, b: UInt8)
    ) -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: width * height * 3)
        let cx = Double(width) * 0.5
        let cy = Double(height) * 0.5
        let cosA = cos(angleRad)
        let sinA = sin(angleRad)

        for y in 0..<height {
            let dy = Double(y) + 0.5 - cy
            for x in 0..<width {
                let dx = Double(x) + 0.5 - cx
                let sx = cx + dx * cosA - dy * sinA - 0.5
                let sy = cy + dx * sinA + dy * cosA - 0.5
                let dIdx = (y * width + x) * 3

                let x0 = Int(floor(sx)), y0 = Int(floor(sy))
                if x0 >= 0 && x0 + 1 < width && y0 >= 0 && y0 + 1 < height {
                    let ax = sx - Double(x0)
                    let ay = sy - Double(y0)
                    let w00 = (1.0 - ax) * (1.0 - ay)
                    let w10 = ax * (1.0 - ay)
                    let w01 = (1.0 - ax) * ay
                    let w11 = ax * ay
                    let i00 = (y0 * width + x0) * 3
                    let i10 = i00 + 3
                    let i01 = ((y0 + 1) * width + x0) * 3
                    let i11 = i01 + 3
                    dst[dIdx]     = UInt8(max(0, min(255, Int((Double(src[i00])     * w00 + Double(src[i10])     * w10 + Double(src[i01])     * w01 + Double(src[i11])     * w11).rounded()))))
                    dst[dIdx + 1] = UInt8(max(0, min(255, Int((Double(src[i00 + 1]) * w00 + Double(src[i10 + 1]) * w10 + Double(src[i01 + 1]) * w01 + Double(src[i11 + 1]) * w11).rounded()))))
                    dst[dIdx + 2] = UInt8(max(0, min(255, Int((Double(src[i00 + 2]) * w00 + Double(src[i10 + 2]) * w10 + Double(src[i01 + 2]) * w01 + Double(src[i11 + 2]) * w11).rounded()))))
                } else {
                    dst[dIdx]     = fillRGB.r
                    dst[dIdx + 1] = fillRGB.g
                    dst[dIdx + 2] = fillRGB.b
                }
            }
        }
        return dst
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
}
