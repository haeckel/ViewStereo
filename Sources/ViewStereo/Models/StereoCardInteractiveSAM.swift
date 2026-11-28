import CoreGraphics
import CoreML
import Foundation
import StereoCore

// MARK: - Step 2 Phase 2-1: 対話的 SAM 2.1 埋め込みキャッシュ＆プロンプト推論 API

enum CardPrintSide: String, CaseIterable, Identifiable, Codable, Sendable {
    case left
    case right

    var id: String { rawValue }
}

struct InteractivePromptPoint: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let side: CardPrintSide
    /// 元カード画像 (cardRGB) に対する正規化座標 [0.0, 1.0]
    let normX: Double
    let normY: Double
    /// true = 正プロンプト（写真内側）, false = 負プロンプト（台紙・外側）
    let isPositive: Bool

    init(id: UUID = UUID(), side: CardPrintSide, normX: Double, normY: Double, isPositive: Bool) {
        self.id = id
        self.side = side
        self.normX = min(1.0, max(0.0, normX))
        self.normY = min(1.0, max(0.0, normY))
        self.isPositive = isPositive
    }
}

struct InteractivePromptBox: Equatable, Codable, Sendable {
    var normMinX: Double
    var normMinY: Double
    var normMaxX: Double
    var normMaxY: Double

    var centerNorm: (normX: Double, normY: Double) {
        ((normMinX + normMaxX) * 0.5, (normMinY + normMaxY) * 0.5)
    }

    /// Box アンカー維持が ON の状態で、Box 外側に正点 (+) が打たれた場合に余裕を持って自動拡張する
    func expandedToInclude(
        positivePoints: [InteractivePromptPoint],
        padX: Double = 0.025,
        padY: Double = 0.035
    ) -> InteractivePromptBox {
        var box = self
        for pt in positivePoints where pt.isPositive {
            if pt.normX < box.normMinX {
                box.normMinX = max(0.0, pt.normX - padX)
            }
            if pt.normX > box.normMaxX {
                box.normMaxX = min(1.0, pt.normX + padX)
            }
            if pt.normY < box.normMinY {
                box.normMinY = max(0.0, pt.normY - padY)
            }
            if pt.normY > box.normMaxY {
                box.normMaxY = min(1.0, pt.normY + padY)
            }
        }
        return box
    }
}

struct SAMImageEmbeddingCache: @unchecked Sendable {
    let cardSignature: UInt64
    let cardWidth: Int
    let cardHeight: Int
    let resizedW: Int
    let resizedH: Int
    let validW: Int
    let validH: Int
    let imageEmbedding: MLMultiArray
    let featsS0: MLMultiArray
    let featsS1: MLMultiArray
    let usedCPUAndGPU: Bool
}

struct InteractiveMaskResult: Sendable {
    let mask: [Bool]
    let softProb: [Float]
    let validW: Int
    let validH: Int
    let areaRatio: Double
    let fillRatio: Double
    let score: Double
    let elapsedMs: Double
    let effectiveBox: InteractivePromptBox?
}

struct InteractiveFinalizedOutput: Sendable {
    let cropResult: StereoCardCropper.CropResult
    let mountContext: StereoCardSegmenter.OriginalCardMountContext
    let fullAlphaL: [UInt8]
    let fullAlphaR: [UInt8]
}

extension StereoCardSegmenter {

    /// 上半分（赤スタンプ中和の影響を受けない領域）のグリッドサンプル＋寸法から FNV-1a 64-bit シグネチャを生成
    static func computeCardSignature(rgb: [UInt8], width: Int, height: Int) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        let prime: UInt64 = 1099511628211
        func mix(_ value: UInt64) {
            hash ^= value
            hash = hash &* prime
        }
        mix(UInt64(max(0, width)))
        mix(UInt64(max(0, height)))
        guard width > 0, height > 0, rgb.count >= width * height * 3 else {
            return hash
        }
        let rows = 8
        let cols = 16
        for r in 0..<rows {
            let ny = 0.05 + 0.38 * (Double(r) / Double(max(1, rows - 1)))
            let y = min(height - 1, max(0, Int((ny * Double(height - 1)).rounded())))
            for c in 0..<cols {
                let nx = 0.05 + 0.90 * (Double(c) / Double(max(1, cols - 1)))
                let x = min(width - 1, max(0, Int((nx * Double(width - 1)).rounded())))
                let off = (y * width + x) * 3
                mix(UInt64(rgb[off]))
                mix(UInt64(rgb[off + 1]))
                mix(UInt64(rgb[off + 2]))
            }
        }
        return hash
    }

    /// アクティブ画素の重心を正規化座標 [0.0, 1.0] で返す（動的対向負点追従用）
    static func computeMaskCentroid(mask: [Bool], width: Int, height: Int) -> (normX: Double, normY: Double)? {
        guard width > 0, height > 0, mask.count >= width * height else { return nil }
        var sumX = 0
        var sumY = 0
        var count = 0
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where mask[row + x] {
                sumX += x
                sumY += y
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let nx = Double(sumX) / Double(count) / Double(max(1, width - 1))
        let ny = Double(sumY) / Double(count) / Double(max(1, height - 1))
        return (min(1.0, max(0.0, nx)), min(1.0, max(0.0, ny)))
    }

    func storeInteractiveEmbeddingCache(
        cardRGB: [UInt8],
        cardWidth: Int,
        cardHeight: Int,
        resizedW: Int,
        resizedH: Int,
        validW: Int,
        validH: Int,
        imageEmbedding: MLMultiArray,
        featsS0: MLMultiArray,
        featsS1: MLMultiArray,
        usedCPUAndGPU: Bool
    ) {
        let sig = Self.computeCardSignature(rgb: cardRGB, width: cardWidth, height: cardHeight)
        let entry = SAMImageEmbeddingCache(
            cardSignature: sig,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            resizedW: resizedW,
            resizedH: resizedH,
            validW: validW,
            validH: validH,
            imageEmbedding: imageEmbedding,
            featsS0: featsS0,
            featsS1: featsS1,
            usedCPUAndGPU: usedCPUAndGPU
        )
        lock.lock()
        interactiveEmbeddingCache = entry
        lock.unlock()
    }

    /// SAM 2.1 Tiny の画像埋め込みを準備（同一カードのキャッシュがあれば 0ms で即返却）
    func prepareInteractiveEmbedding(
        cardRGB: [UInt8],
        width srcW: Int,
        height srcH: Int
    ) -> SAMImageEmbeddingCache? {
        guard srcW >= 32, srcH >= 32, cardRGB.count >= srcW * srcH * 3 else { return nil }
        let sig = Self.computeCardSignature(rgb: cardRGB, width: srcW, height: srcH)

        lock.lock()
        let cached = interactiveEmbeddingCache
        lock.unlock()
        if let cached,
           cached.cardSignature == sig,
           cached.cardWidth == srcW,
           cached.cardHeight == srcH {
            return cached
        }

        guard let initialEncoder = loadModel(name: "SAM2_1TinyImageEncoderFLOAT16", cache: &cachedSam2Encoder),
              let cgImage = makeCGImage(from: cardRGB, width: srcW, height: srcH) else {
            return nil
        }

        let scale = Double(samSize) / Double(max(srcW, srcH))
        let resizedW = max(1, Int((Double(srcW) * scale).rounded()))
        let resizedH = max(1, Int((Double(srcH) * scale).rounded()))
        let validW = max(1, Int((Double(resizedW) / 4.0).rounded()))
        let validH = max(1, Int((Double(resizedH) / 4.0).rounded()))

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
        guard let encOut = try? initialEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": imgFeature])),
              var imgEmb = encOut.featureValue(for: "image_embedding")?.multiArrayValue,
              var featsS0 = encOut.featureValue(for: "feats_s0")?.multiArrayValue,
              var featsS1 = encOut.featureValue(for: "feats_s1")?.multiArrayValue else {
            return nil
        }

        var usedCPUAndGPU = false
        if containsNonFinite(imgEmb) || containsNonFinite(featsS0) || containsNonFinite(featsS1) {
            NSLog("[SAM2-Interactive] Non-finite values in ImageEncoder; retrying on .cpuAndGPU")
            if let cpuEnc = cachedSam2EncoderCPU ?? loadModel(name: "SAM2_1TinyImageEncoderFLOAT16", cache: &cachedSam2EncoderCPU, computeUnitsOverride: .cpuAndGPU),
               let retryEnc = try? cpuEnc.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": imgFeature])),
               let rEmb = retryEnc.featureValue(for: "image_embedding")?.multiArrayValue,
               let rS0 = retryEnc.featureValue(for: "feats_s0")?.multiArrayValue,
               let rS1 = retryEnc.featureValue(for: "feats_s1")?.multiArrayValue,
               !containsNonFinite(rEmb), !containsNonFinite(rS0), !containsNonFinite(rS1) {
                imgEmb = rEmb
                featsS0 = rS0
                featsS1 = rS1
                usedCPUAndGPU = true
            } else {
                return nil
            }
        }

        let entry = SAMImageEmbeddingCache(
            cardSignature: sig,
            cardWidth: srcW,
            cardHeight: srcH,
            resizedW: resizedW,
            resizedH: resizedH,
            validW: validW,
            validH: validH,
            imageEmbedding: imgEmb,
            featsS0: featsS0,
            featsS1: featsS1,
            usedCPUAndGPU: usedCPUAndGPU
        )
        lock.lock()
        interactiveEmbeddingCache = entry
        lock.unlock()
        return entry
    }

    /// キャッシュ済み画像埋め込みを使い、PromptEncoder + MaskDecoder のみで高速に片側マスクを対話再推論
    func predictInteractiveMask(
        cache: SAMImageEmbeddingCache,
        side: CardPrintSide,
        points: [InteractivePromptPoint],
        anchorBox: InteractivePromptBox,
        otherBoxCenter: (normX: Double, normY: Double)?,
        useBoxAnchor: Bool
    ) -> InteractiveMaskResult? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let initialPromptEnc = loadModel(name: "SAM2_1TinyPromptEncoderFLOAT16", cache: &cachedSam2Prompt),
              let initialDecoder = loadModel(name: "SAM2_1TinyMaskDecoderFLOAT16", cache: &cachedSam2Decoder) else {
            return nil
        }

        func toSAMX(_ normX: Double) -> Float {
            Float(max(0.0, min(Double(samSize - 1), normX * Double(cache.resizedW))))
        }
        func toSAMY(_ normY: Double) -> Float {
            Float(max(0.0, min(Double(samSize - 1), normY * Double(cache.resizedH))))
        }

        let sidePoints = points.filter { $0.side == side }
        let userPositivePoints = sidePoints.filter { $0.isPositive }
        let effectiveBox = useBoxAnchor ? anchorBox.expandedToInclude(positivePoints: userPositivePoints) : nil

        // PromptEncoder の N ∈ [2, 14] 制約を守る
        let boxReserve = useBoxAnchor ? 2 : 0
        let maxUserPoints = 14 - boxReserve - 2 // 対向負点 + 暗黙正点分を確保
        let activeUserPoints = sidePoints.count > maxUserPoints ? Array(sidePoints.suffix(maxUserPoints)) : sidePoints

        var promptTuples: [(x: Float, y: Float, label: Float)] = []
        promptTuples.reserveCapacity(14)

        for pt in activeUserPoints {
            promptTuples.append((toSAMX(pt.normX), toSAMY(pt.normY), pt.isPositive ? 1.0 : 0.0))
        }

        // ユーザーが負点しか打っていない場合でもプリント中心のアンカー正点を 1 点入れる
        if !activeUserPoints.contains(where: { $0.isPositive }) {
            let center = (effectiveBox ?? anchorBox).centerNorm
            promptTuples.append((toSAMX(center.normX), toSAMY(center.normY), 1.0))
        }

        // 左右癒着抑止のための対向プリント中央負点（ユーザーが対向側に正点を意図的に打った場合は除く）
        if let other = otherBoxCenter {
            let hasPositiveNearOther = userPositivePoints.contains { pt in
                hypot(pt.normX - other.normX, pt.normY - other.normY) < 0.08
            }
            if !hasPositiveNearOther && promptTuples.count < (14 - boxReserve) {
                promptTuples.append((toSAMX(other.normX), toSAMY(other.normY), 0.0))
            }
        }

        if let box = effectiveBox {
            promptTuples.append((toSAMX(box.normMinX), toSAMY(box.normMinY), 2.0))
            promptTuples.append((toSAMX(box.normMaxX), toSAMY(box.normMaxY), 3.0))
        }

        let pointCount = min(14, max(2, promptTuples.count))
        guard let ptsArr = try? MLMultiArray(shape: [1, NSNumber(value: pointCount), 2], dataType: .float16),
              let lblArr = try? MLMultiArray(shape: [1, NSNumber(value: pointCount)], dataType: .float16) else {
            return nil
        }

        for i in 0..<pointCount {
            ptsArr[[0, NSNumber(value: i), 0] as [NSNumber]] = NSNumber(value: promptTuples[i].x)
            ptsArr[[0, NSNumber(value: i), 1] as [NSNumber]] = NSNumber(value: promptTuples[i].y)
            lblArr[[0, NSNumber(value: i)] as [NSNumber]] = NSNumber(value: promptTuples[i].label)
        }

        func runPromptAndDecode(
            pEnc: MLModel,
            mDec: MLModel
        ) -> (masks: MLMultiArray, scores: MLMultiArray?)? {
            guard let pProvider = try? MLDictionaryFeatureProvider(dictionary: [
                "points": MLFeatureValue(multiArray: ptsArr),
                "labels": MLFeatureValue(multiArray: lblArr)
            ]),
            let pOut = try? pEnc.prediction(from: pProvider),
            let sparseEmb = pOut.featureValue(for: "sparse_embeddings")?.multiArrayValue,
            let denseEmb = pOut.featureValue(for: "dense_embeddings")?.multiArrayValue,
            let decProvider = try? MLDictionaryFeatureProvider(dictionary: [
                "image_embedding": MLFeatureValue(multiArray: cache.imageEmbedding),
                "sparse_embedding": MLFeatureValue(multiArray: sparseEmb),
                "dense_embedding": MLFeatureValue(multiArray: denseEmb),
                "feats_s0": MLFeatureValue(multiArray: cache.featsS0),
                "feats_s1": MLFeatureValue(multiArray: cache.featsS1)
            ]),
            let decOut = try? mDec.prediction(from: decProvider),
            let masks = decOut.featureValue(for: "low_res_masks")?.multiArrayValue else {
                return nil
            }
            let scores = decOut.featureValue(for: "scores")?.multiArrayValue
            return (masks, scores)
        }

        let activePromptEnc = cache.usedCPUAndGPU
            ? (cachedSam2PromptCPU ?? loadModel(name: "SAM2_1TinyPromptEncoderFLOAT16", cache: &cachedSam2PromptCPU, computeUnitsOverride: .cpuAndGPU) ?? initialPromptEnc)
            : initialPromptEnc

        guard var decoded = runPromptAndDecode(pEnc: activePromptEnc, mDec: initialDecoder) else {
            return nil
        }

        if containsNonFinite(decoded.masks) || (decoded.scores.map { containsNonFinite($0) } ?? false) {
            NSLog("[SAM2-Interactive] Non-finite MaskDecoder output; falling back to .cpuAndGPU / .cpuOnly")
            let cpuPrompt = cachedSam2PromptCPU ?? loadModel(name: "SAM2_1TinyPromptEncoderFLOAT16", cache: &cachedSam2PromptCPU, computeUnitsOverride: .cpuAndGPU) ?? activePromptEnc
            if let retryDec = runPromptAndDecode(pEnc: cpuPrompt, mDec: initialDecoder),
               !containsNonFinite(retryDec.masks) {
                decoded = retryDec
            } else if let cpuOnlyDec = cachedSam2DecoderCPU ?? loadModel(name: "SAM2_1TinyMaskDecoderFLOAT16", cache: &cachedSam2DecoderCPU, computeUnitsOverride: .cpuOnly),
                      let cpuOnlyRes = runPromptAndDecode(pEnc: cpuPrompt, mDec: cpuOnlyDec),
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

        let validW = cache.validW
        let validH = cache.validH
        let totalValidArea = max(1, validW * validH)

        struct InteractiveCandidate {
            let mask: [Bool]
            let softProb: [Float]
            let areaRatio: Double
            let fillRatio: Double
            let score: Double
            let composite: Double
        }

        var bestCandidate: InteractiveCandidate? = nil
        var fallbackCandidate: InteractiveCandidate? = nil

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
            var softProb = rawSigmoid
            for i in 0..<(validW * validH) {
                if filled[i] && !raw[i] {
                    softProb[i] = max(softProb[i], 0.95)
                } else if !filled[i] && raw[i] {
                    softProb[i] = 0.0
                }
            }

            let area = filled.reduce(0) { $0 + ($1 ? 1 : 0) }
            let areaRatio = Double(area) / Double(totalValidArea)
            let box = robustBoundingBox(mask: filled, w: validW, h: validH)
            let boxArea = box.map { max(1, ($0.maxX - $0.minX + 1) * ($0.maxY - $0.minY + 1)) } ?? totalValidArea
            let fillRatio = min(1.0, Double(area) / Double(boxArea))

            // ユーザー打点への適合度（正点は内側、負点は外側）
            var promptMatches = 0
            for pt in activeUserPoints {
                let vx = min(validW - 1, max(0, Int((pt.normX * Double(validW - 1)).rounded())))
                let vy = min(validH - 1, max(0, Int((pt.normY * Double(validH - 1)).rounded())))
                let inside = filled[vy * validW + vx]
                if (pt.isPositive && inside) || (!pt.isPositive && !inside) {
                    promptMatches += 1
                }
            }
            let promptMatchRatio = activeUserPoints.isEmpty ? 1.0 : Double(promptMatches) / Double(activeUserPoints.count)

            let areaBonus: Double = (areaRatio >= 0.14 && areaRatio <= 0.50) ? 1.0 : 0.2
            let composite = promptMatchRatio * 0.58 + candScores[k] * 0.22 + fillRatio * 0.15 + areaBonus * 0.05

            let cand = InteractiveCandidate(
                mask: filled,
                softProb: softProb,
                areaRatio: areaRatio,
                fillRatio: fillRatio,
                score: candScores[k],
                composite: composite
            )

            if fallbackCandidate == nil || cand.score > fallbackCandidate!.score {
                fallbackCandidate = cand
            }

            if areaRatio >= 0.05 && areaRatio <= 0.62 && fillRatio >= 0.55 {
                if bestCandidate == nil || cand.composite > bestCandidate!.composite {
                    bestCandidate = cand
                }
            }
        }

        guard let chosen = bestCandidate ?? fallbackCandidate else {
            return nil
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        return InteractiveMaskResult(
            mask: chosen.mask,
            softProb: chosen.softProb,
            validW: validW,
            validH: validH,
            areaRatio: chosen.areaRatio,
            fillRatio: chosen.fillRatio,
            score: chosen.score,
            elapsedMs: elapsedMs,
            effectiveBox: effectiveBox
        )
    }

    /// 既存の OriginalCardMountContext から対話エディタの初期マスク・確率マップを生成
    static func makeInitialInteractiveMasks(
        from mountContext: OriginalCardMountContext,
        targetW: Int,
        targetH: Int
    ) -> (maskL: [Bool], probL: [Float], maskR: [Bool], probR: [Float]) {
        let sw = mountContext.maskWidth
        let sh = mountContext.maskHeight
        let count = targetW * targetH
        guard sw > 0, sh > 0,
              mountContext.maskL.count >= sw * sh,
              mountContext.maskR.count >= sw * sh else {
            return (
                [Bool](repeating: false, count: count),
                [Float](repeating: 0, count: count),
                [Bool](repeating: false, count: count),
                [Float](repeating: 0, count: count)
            )
        }

        func resample(_ src: [Bool]) -> ([Bool], [Float]) {
            var outMask = [Bool](repeating: false, count: count)
            var outProb = [Float](repeating: 0, count: count)
            for y in 0..<targetH {
                let sy = min(sh - 1, max(0, (y * sh) / targetH))
                let sRow = sy * sw
                let dRow = y * targetW
                for x in 0..<targetW {
                    let sx = min(sw - 1, max(0, (x * sw) / targetW))
                    let val = src[sRow + sx]
                    outMask[dRow + x] = val
                    outProb[dRow + x] = val ? 1.0 : 0.0
                }
            }
            return (outMask, outProb)
        }

        let (mL, pL) = resample(mountContext.maskL)
        let (mR, pR) = resample(mountContext.maskR)
        return (mL, pL, mR, pR)
    }

    /// ユーザー確定後の左右マスクから四隅の角丸・アーチ曲率パラメータを滑らかに実測フィットする
    private func estimateInteractiveArchParams(
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
                let y = min(h - 1, max(0, box.minY + dy))
                let row = y * w
                for dx in 0..<cwTop {
                    let lx = min(w - 1, max(0, box.minX + dx))
                    let rx = min(w - 1, max(0, box.maxX - dx))
                    if !mask[row + lx] { missTL += 1 }
                    if !mask[row + rx] { missTR += 1 }
                }
            }

            var missBL = 0, missBR = 0
            for dy in 0..<chBot {
                let y = min(h - 1, max(0, box.maxY - dy))
                let row = y * w
                for dx in 0..<cwBot {
                    let lx = min(w - 1, max(0, box.minX + dx))
                    let rx = min(w - 1, max(0, box.maxX - dx))
                    if !mask[row + lx] { missBL += 1 }
                    if !mask[row + rx] { missBR += 1 }
                }
            }

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
        let leftPair = (cL.tl + cR.tl) * 0.5
        let rightPair = (cL.tr + cR.tr) * 0.5
        let rTop = max(min(leftPair, rightPair), min(cL.tl, cR.tr))

        let leftBotPair = (cL.bl + cR.bl) * 0.5
        let rightBotPair = (cL.br + cR.br) * 0.5
        let rBot = max(min(leftBotPair, rightBotPair), min(cL.bl, cR.br))

        let topRx: Double
        let topRy: Double
        if rTop >= 0.045 {
            if rTop >= 0.22 {
                // 深いドーム型アーチ
                topRx = 0.50
                topRy = min(0.45, max(0.16, rTop * 1.05))
            } else {
                // 水平フラット天井を保つ肩角丸・四隅角丸
                topRx = min(0.48, max(0.08, rTop * 1.15))
                topRy = min(0.35, max(0.06, rTop * 0.95))
            }
        } else {
            topRx = 0.0
            topRy = 0.0
        }

        let botRx: Double
        let botRy: Double
        if rBot >= 0.055 && min(cL.bl, cR.br) >= 0.045 {
            botRx = min(0.24, rBot * 1.05)
            botRy = min(0.20, rBot * 1.05)
        } else {
            botRx = 0.0
            botRy = 0.0
        }

        return ArchShapeParams(
            topRxRatio: topRx,
            topRyRatio: topRy,
            botRxRatio: botRx,
            botRyRatio: botRy,
            topArchExp: 2.0
        )
    }

    private struct SmoothedCardAlphas {
        let fullAlphaL: [UInt8]
        let fullAlphaR: [UInt8]
        let cw: Int
        let ch: Int
        let cxL: Double
        let cyL: Double
        let cxR: Double
        let cyR: Double
        let archParams: ArchShapeParams
    }

    /// ガイド調整モードの「上アーチ深さ / 下角丸」スライダー値から滑らかな ArchShapeParams を構築
    static func makeGuideArchParams(topRyRatio: Double, botRyRatio: Double) -> ArchShapeParams {
        let topRx: Double
        let topRy: Double
        if topRyRatio < 0.01 {
            topRx = 0.0
            topRy = 0.0
        } else if topRyRatio >= 0.20 {
            topRx = 0.50
            topRy = min(0.45, topRyRatio)
        } else {
            topRx = min(0.48, max(0.08, topRyRatio * 1.35))
            topRy = topRyRatio
        }

        let botRx: Double
        let botRy: Double
        if botRyRatio < 0.01 {
            botRx = 0.0
            botRy = 0.0
        } else {
            botRx = min(0.24, botRyRatio * 1.15)
            botRy = min(0.20, botRyRatio)
        }

        return ArchShapeParams(
            topRxRatio: topRx,
            topRyRatio: topRy,
            botRxRatio: botRx,
            botRyRatio: botRy,
            topArchExp: 2.0
        )
    }

    /// ガイド枠＋アーチ形状から直接、ライブプレビュー・確定用の左右マスク＆連続確率マップを生成する
    static func buildGuideDirectMasks(
        boxL: InteractivePromptBox,
        boxR: InteractivePromptBox,
        archParams: ArchShapeParams,
        maskW: Int,
        maskH: Int
    ) -> (maskL: [Bool], probL: [Float], maskR: [Bool], probR: [Float]) {
        guard maskW >= 8, maskH >= 8 else {
            return ([], [], [], [])
        }
        let wL = max(8, Int(((boxL.normMaxX - boxL.normMinX) * Double(maskW)).rounded()))
        let hL = max(8, Int(((boxL.normMaxY - boxL.normMinY) * Double(maskH)).rounded()))
        let cxL = (boxL.normMinX + boxL.normMaxX) * 0.5 * Double(maskW)
        let cyL = (boxL.normMinY + boxL.normMaxY) * 0.5 * Double(maskH)

        let wR = max(8, Int(((boxR.normMaxX - boxR.normMinX) * Double(maskW)).rounded()))
        let hR = max(8, Int(((boxR.normMaxY - boxR.normMinY) * Double(maskH)).rounded()))
        let cxR = (boxR.normMinX + boxR.normMaxX) * 0.5 * Double(maskW)
        let cyR = (boxR.normMinY + boxR.normMaxY) * 0.5 * Double(maskH)

        let probL = buildCardSpaceGeometricProbMask(
            cardWidth: maskW,
            cardHeight: maskH,
            centerX: cxL,
            centerY: cyL,
            boxWidth: wL,
            boxHeight: hL,
            angleRad: 0.0,
            archParams: archParams
        )
        let probR = buildCardSpaceGeometricProbMask(
            cardWidth: maskW,
            cardHeight: maskH,
            centerX: cxR,
            centerY: cyR,
            boxWidth: wR,
            boxHeight: hR,
            angleRad: 0.0,
            archParams: archParams
        )
        let maskL = probL.map { $0 >= 0.5 }
        let maskR = probR.map { $0 >= 0.5 }
        return (maskL, probL, maskR, probR)
    }

    /// 確定した左右マスクから滑らかな幾何学確率マップを生成し、Step 1 と同一の GPU 4ステップ仕上げを適用する
    private func buildSmoothedFullCardAlphas(
        cardRGB: [UInt8],
        cardW: Int,
        cardH: Int,
        maskL: [Bool],
        softProbL: [Float],
        maskR: [Bool],
        softProbR: [Float],
        maskW: Int,
        maskH: Int,
        skewAngleRad: Double,
        fallbackLeftBox: (x0: Int, y0: Int, x1: Int, y1: Int)? = nil,
        fallbackRightBox: (x0: Int, y0: Int, x1: Int, y1: Int)? = nil,
        overrideArchParams: ArchShapeParams? = nil,
        overrideBoxes: (left: InteractivePromptBox, right: InteractivePromptBox)? = nil
    ) -> SmoothedCardAlphas? {
        guard cardW >= 32, cardH >= 32,
              cardRGB.count >= cardW * cardH * 3,
              maskW >= 8, maskH >= 8,
              maskL.count >= maskW * maskH,
              maskR.count >= maskW * maskH,
              softProbL.count >= maskW * maskH,
              softProbR.count >= maskW * maskH else {
            return nil
        }

        let lx0: Double, lx1: Double, ly0: Double, ly1: Double
        let rx0: Double, rx1: Double, ry0: Double, ry1: Double
        let fittedArch: ArchShapeParams

        if let ovBoxes = overrideBoxes {
            lx0 = ovBoxes.left.normMinX * Double(cardW)
            lx1 = ovBoxes.left.normMaxX * Double(cardW)
            ly0 = ovBoxes.left.normMinY * Double(cardH)
            ly1 = ovBoxes.left.normMaxY * Double(cardH)

            rx0 = ovBoxes.right.normMinX * Double(cardW)
            rx1 = ovBoxes.right.normMaxX * Double(cardW)
            ry0 = ovBoxes.right.normMinY * Double(cardH)
            ry1 = ovBoxes.right.normMaxY * Double(cardH)

            if let ovArch = overrideArchParams {
                fittedArch = ovArch
            } else {
                let samBoxL = IntBox(
                    minX: max(0, min(maskW - 1, Int((ovBoxes.left.normMinX * Double(maskW)).rounded()))),
                    minY: max(0, min(maskH - 1, Int((ovBoxes.left.normMinY * Double(maskH)).rounded()))),
                    maxX: max(0, min(maskW - 1, Int((ovBoxes.left.normMaxX * Double(maskW)).rounded()) - 1)),
                    maxY: max(0, min(maskH - 1, Int((ovBoxes.left.normMaxY * Double(maskH)).rounded()) - 1))
                )
                let samBoxR = IntBox(
                    minX: max(0, min(maskW - 1, Int((ovBoxes.right.normMinX * Double(maskW)).rounded()))),
                    minY: max(0, min(maskH - 1, Int((ovBoxes.right.normMinY * Double(maskH)).rounded()))),
                    maxX: max(0, min(maskW - 1, Int((ovBoxes.right.normMaxX * Double(maskW)).rounded()) - 1)),
                    maxY: max(0, min(maskH - 1, Int((ovBoxes.right.normMaxY * Double(maskH)).rounded()) - 1))
                )
                fittedArch = estimateInteractiveArchParams(
                    maskL: maskL, boxL: samBoxL,
                    maskR: maskR, boxR: samBoxR,
                    w: maskW, h: maskH
                )
            }
        } else {
            func resolveMaskBox(_ mask: [Bool], prob: [Float], fallback: (x0: Int, y0: Int, x1: Int, y1: Int)?) -> IntBox {
                if let b = robustBoundingBox(mask: mask, w: maskW, h: maskH) {
                    return b
                }
                let probMask = prob.map { $0 >= 0.5 }
                if let b = robustBoundingBox(mask: probMask, w: maskW, h: maskH) {
                    return b
                }
                if let fb = fallback {
                    return IntBox(
                        minX: max(0, min(maskW - 1, fb.x0 * maskW / cardW)),
                        minY: max(0, min(maskH - 1, fb.y0 * maskH / cardH)),
                        maxX: max(0, min(maskW - 1, (fb.x1 - 1) * maskW / cardW)),
                        maxY: max(0, min(maskH - 1, (fb.y1 - 1) * maskH / cardH))
                    )
                }
                return IntBox(minX: 0, minY: 0, maxX: maskW - 1, maxY: maskH - 1)
            }

            let samBoxL = resolveMaskBox(maskL, prob: softProbL, fallback: fallbackLeftBox)
            let samBoxR = resolveMaskBox(maskR, prob: softProbR, fallback: fallbackRightBox)
            fittedArch = overrideArchParams ?? estimateInteractiveArchParams(
                maskL: maskL, boxL: samBoxL,
                maskR: maskR, boxR: samBoxR,
                w: maskW, h: maskH
            )

            let scaleX = Double(cardW) / Double(maskW)
            let scaleY = Double(cardH) / Double(maskH)

            lx0 = Double(samBoxL.minX) * scaleX
            lx1 = Double(samBoxL.maxX + 1) * scaleX
            ly0 = Double(samBoxL.minY) * scaleY
            ly1 = Double(samBoxL.maxY + 1) * scaleY

            rx0 = Double(samBoxR.minX) * scaleX
            rx1 = Double(samBoxR.maxX + 1) * scaleX
            ry0 = Double(samBoxR.minY) * scaleY
            ry1 = Double(samBoxR.maxY + 1) * scaleY
        }

        let wL = max(16, Int((lx1 - lx0).rounded()))
        let hL = max(16, Int((ly1 - ly0).rounded()))
        let wR = max(16, Int((rx1 - rx0).rounded()))
        let hR = max(16, Int((ry1 - ry0).rounded()))
        let cw = min(cardW, max(wL, wR))
        let ch = min(cardH, max(hL, hR))

        let cxL = (lx0 + lx1) * 0.5
        let cyL = (ly0 + ly1) * 0.5
        let cxR = (rx0 + rx1) * 0.5
        let cyR = (ry0 + ry1) * 0.5

        let boxWL = (overrideBoxes != nil) ? min(cardW, wL) : cw
        let boxHL = (overrideBoxes != nil) ? min(cardH, hL) : ch
        let boxWR = (overrideBoxes != nil) ? min(cardW, wR) : cw
        let boxHR = (overrideBoxes != nil) ? min(cardH, hR) : ch
        let effTheta = (overrideBoxes != nil) ? 0.0 : skewAngleRad

        let geomProbL = Self.buildCardSpaceGeometricProbMask(
            cardWidth: cardW,
            cardHeight: cardH,
            centerX: cxL,
            centerY: cyL,
            boxWidth: boxWL,
            boxHeight: boxHL,
            angleRad: effTheta,
            archParams: fittedArch
        )
        let geomProbR = Self.buildCardSpaceGeometricProbMask(
            cardWidth: cardW,
            cardHeight: cardH,
            centerX: cxR,
            centerY: cyR,
            boxWidth: boxWR,
            boxHeight: boxHR,
            angleRad: effTheta,
            archParams: fittedArch
        )

        var fullAlphaL = [UInt8]()
        var fullAlphaR = [UInt8]()
        if overrideBoxes != nil {
            // ユーザーが手動でガイド枠・アーチ曲率を確定した場合は、
            // GuidedFilter による画像エッジ追従で外側台紙へ吸着・破壊されるのを防ぎ、
            // ユーザー指定の幾何学マスク（geomProb）を忠実に直接 8-bit アルファマスクへ変換する
            fullAlphaL = [UInt8](repeating: 0, count: cardW * cardH)
            fullAlphaR = [UInt8](repeating: 0, count: cardW * cardH)
            for i in 0..<(cardW * cardH) {
                fullAlphaL[i] = UInt8(min(255, max(0, Int((geomProbL[i] * 255.0).rounded()))))
                fullAlphaR[i] = UInt8(min(255, max(0, Int((geomProbR[i] * 255.0).rounded()))))
            }
        } else {
            DispatchQueue.concurrentPerform(iterations: 2) { side in
                if side == 0 {
                    fullAlphaL = StereoCardMaskRefiner.shared.refineMask(
                        probMask: geomProbL,
                        maskWidth: cardW,
                        maskHeight: cardH,
                        guideRGB: cardRGB,
                        width: cardW,
                        height: cardH
                    )
                } else {
                    fullAlphaR = StereoCardMaskRefiner.shared.refineMask(
                        probMask: geomProbR,
                        maskWidth: cardW,
                        maskHeight: cardH,
                        guideRGB: cardRGB,
                        width: cardW,
                        height: cardH
                    )
                }
            }
        }

        return SmoothedCardAlphas(
            fullAlphaL: fullAlphaL,
            fullAlphaR: fullAlphaR,
            cw: cw,
            ch: ch,
            cxL: cxL,
            cyL: cyL,
            cxR: cxR,
            cyR: cyR,
            archParams: fittedArch
        )
    }

    /// ユーザー確定後の左右マスクを幾何学的実輪郭フィット＋GPU 4ステップ仕上げに通し、
    /// 元カード空間のアルファマスク・切り出し画像・更新済み MountContext を生成する
    func finalizeInteractiveMasks(
        mountContext: OriginalCardMountContext,
        maskL: [Bool],
        softProbL: [Float],
        maskR: [Bool],
        softProbR: [Float],
        maskW: Int,
        maskH: Int,
        mode: StereoCardCropper.ExtractionMode,
        overrideArchParams: ArchShapeParams? = nil,
        overrideBoxes: (left: InteractivePromptBox, right: InteractivePromptBox)? = nil
    ) -> InteractiveFinalizedOutput? {
        let cardW = mountContext.cardWidth
        let cardH = mountContext.cardHeight
        let theta = (overrideBoxes != nil) ? 0.0 : mountContext.skewAngleRad

        guard let smoothed = buildSmoothedFullCardAlphas(
            cardRGB: mountContext.cardRGB,
            cardW: cardW,
            cardH: cardH,
            maskL: maskL,
            softProbL: softProbL,
            maskR: maskR,
            softProbR: softProbR,
            maskW: maskW,
            maskH: maskH,
            skewAngleRad: theta,
            fallbackLeftBox: mountContext.leftBox,
            fallbackRightBox: mountContext.rightBox,
            overrideArchParams: overrideArchParams,
            overrideBoxes: overrideBoxes
        ) else {
            return nil
        }

        let fullAlphaL = smoothed.fullAlphaL
        let fullAlphaR = smoothed.fullAlphaR
        let cw = smoothed.cw
        let ch = smoothed.ch
        let cxL = smoothed.cxL
        let cyL = smoothed.cyL
        let cxR = smoothed.cxR
        let cyR = smoothed.cyR

        var fullOutL = cropRotatedRGB(
            mountContext.cardRGB,
            srcW: cardW,
            srcH: cardH,
            centerX: cxL,
            centerY: cyL,
            width: cw,
            height: ch,
            angleRad: theta
        )
        var fullOutR = cropRotatedRGB(
            mountContext.cardRGB,
            srcW: cardW,
            srcH: cardH,
            centerX: cxR,
            centerY: cyR,
            width: cw,
            height: ch,
            angleRad: theta
        )
        let outAlphaL = Self.cropRotatedMask8(
            fullAlphaL,
            srcW: cardW,
            srcH: cardH,
            centerX: cxL,
            centerY: cyL,
            width: cw,
            height: ch,
            angleRad: theta
        )
        let outAlphaR = Self.cropRotatedMask8(
            fullAlphaR,
            srcW: cardW,
            srcH: cardH,
            centerX: cxR,
            centerY: cyR,
            width: cw,
            height: ch,
            angleRad: theta
        )

        let totalOutPx = max(1, cw * ch)
        let activeL = outAlphaL.reduce(0) { $0 + ($1 >= 128 ? 1 : 0) }
        let activeR = outAlphaR.reduce(0) { $0 + ($1 >= 128 ? 1 : 0) }
        let hasValidAlphaMasks = (Double(activeL) / Double(totalOutPx) >= 0.15) && (Double(activeR) / Double(totalOutPx) >= 0.15)
        if hasValidAlphaMasks {
            Self.extendBoundaryColorsOutsideMask(rgb: &fullOutL, alpha: outAlphaL, width: cw, height: ch, radius: 5)
            Self.extendBoundaryColorsOutsideMask(rgb: &fullOutR, alpha: outAlphaR, width: cw, height: ch, radius: 5)
        }

        let startLX = max(0, min(cardW - cw, Int((cxL - Double(cw) * 0.5).rounded())))
        let startLY = max(0, min(cardH - ch, Int((cyL - Double(ch) * 0.5).rounded())))
        let startRX = max(0, min(cardW - cw, Int((cxR - Double(cw) * 0.5).rounded())))
        let startRY = max(0, min(cardH - ch, Int((cyR - Double(ch) * 0.5).rounded())))

        let finalUnmaskedAlphaL = hasValidAlphaMasks ? outAlphaL : [UInt8](repeating: 255, count: cw * ch)
        let finalUnmaskedAlphaR = hasValidAlphaMasks ? outAlphaR : [UInt8](repeating: 255, count: cw * ch)

        let updatedContext = OriginalCardMountContext(
            cardRGB: mountContext.cardRGB,
            cardWidth: cardW,
            cardHeight: cardH,
            leftBox: (x0: startLX, y0: startLY, x1: startLX + cw, y1: startLY + ch),
            rightBox: (x0: startRX, y0: startRY, x1: startRX + cw, y1: startRY + ch),
            maskL: maskL,
            maskR: maskR,
            maskWidth: maskW,
            maskHeight: maskH,
            skewAngleRad: theta,
            sampledCardRGB: mountContext.sampledCardRGB,
            archParams: smoothed.archParams,
            unmaskedLeftRGB: fullOutL,
            unmaskedRightRGB: fullOutR,
            unmaskedAlphaL: finalUnmaskedAlphaL,
            unmaskedAlphaR: finalUnmaskedAlphaR,
            unmaskedWidth: cw,
            unmaskedHeight: ch
        )

        lock.lock()
        latestArchParams = smoothed.archParams
        latestMountContext = updatedContext
        lock.unlock()

        var cropLeft = fullOutL
        var cropRight = fullOutR
        let preservedArch = (mode == .keepArchBlack)
        if preservedArch && hasValidAlphaMasks {
            Self.applyAlphaMaskBlack(&cropLeft, alpha: outAlphaL, width: cw, height: ch)
            Self.applyAlphaMaskBlack(&cropRight, alpha: outAlphaR, width: cw, height: ch)
        }

        let cropResult = StereoCardCropper.CropResult(
            leftRGB: cropLeft,
            rightRGB: cropRight,
            width: cw,
            height: ch,
            detectedCard: true,
            preservedArch: preservedArch
        )

        return InteractiveFinalizedOutput(
            cropResult: cropResult,
            mountContext: updatedContext,
            fullAlphaL: fullAlphaL,
            fullAlphaR: fullAlphaR
        )
    }

    /// 教師データ書き出し用：幾何学的実輪郭フィット＋GPU 4ステップ仕上げ済み 8-bit アルファマスク (L/R) のみを生成
    func renderFullCardAlphaMasks(
        cardRGB: [UInt8],
        cardWidth: Int,
        cardHeight: Int,
        maskL: [Bool],
        softProbL: [Float],
        maskR: [Bool],
        softProbR: [Float],
        maskW: Int,
        maskH: Int,
        skewAngleRad: Double,
        overrideArchParams: ArchShapeParams? = nil,
        overrideBoxes: (left: InteractivePromptBox, right: InteractivePromptBox)? = nil
    ) -> (alphaL: [UInt8], alphaR: [UInt8])? {
        guard let smoothed = buildSmoothedFullCardAlphas(
            cardRGB: cardRGB,
            cardW: cardWidth,
            cardH: cardHeight,
            maskL: maskL,
            softProbL: softProbL,
            maskR: maskR,
            softProbR: softProbR,
            maskW: maskW,
            maskH: maskH,
            skewAngleRad: skewAngleRad,
            overrideArchParams: overrideArchParams,
            overrideBoxes: overrideBoxes
        ) else {
            return nil
        }
        return (smoothed.fullAlphaL, smoothed.fullAlphaR)
    }
}
