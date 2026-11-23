import Accelerate
import CoreGraphics
import Foundation
import simd

// MARK: - Data Models

/// 印画紙上部のカット形状
public enum StereoPrintCutType: String, Codable, Sendable {
    case square
    case rounded
    case arch
}

/// Stage 0: スキャン余白除去および傾き補正（Deskew）の結果
public struct CardDeskewResult: Sendable {
    /// 元画像座標系での実カード範囲
    public let cardRectInSource: CGRect
    /// 水平化に適用した回転角 (rad)
    public let skewAngleRad: Double
    /// スキャン余白を除去したか
    public let hasScanMargin: Bool
    /// 水平化後の作業画像サイズ
    public let deskewedSize: CGSize
    /// 水平化・余白除去済みのカード画像
    public let deskewedImage: CGImage
    /// 水平化・余白除去済みの RGB バイト配列 (width * height * 3)
    public let deskewedRGB: [UInt8]
    public let width: Int
    public let height: Int
    /// Stage 0 バイパス時に検出された外周の支配的背景色 Lab（白台紙等）
    public let bypassedMountLab: SIMD3<Float>?
}

/// Stage 1: CIE Lab 色空間におけるカード固有の台紙色統計モデル
public struct MountColorModel: Sendable {
    public let meanLab: SIMD3<Float>
    public let invCovLab: simd_float3x3
    public let confidence: Float
}

/// Stage 1: 台紙確率マップと外周連結バリア
public struct MountBarrierMap: Sendable {
    public let width: Int
    public let height: Int
    public let probabilities: [Float]
    public let model: MountColorModel
    /// カード外周・中央セパレータから連結している真の台紙バリア領域のみを true にしたマスク
    public let connectedBarrierMask: [Bool]

    /// 指定された正規化 Y 行の中央 X 帯が台紙バリアかどうかを判定
    public func isMountBarrierRow(
        normalizedY: CGFloat,
        normalizedXRange: ClosedRange<CGFloat> = 0.15...0.85,
        threshold: Float = 0.55
    ) -> Bool {
        let row = max(0, min(height - 1, Int(round(normalizedY * CGFloat(height - 1)))))
        let x0 = max(0, min(width - 1, Int(floor(normalizedXRange.lowerBound * CGFloat(width - 1)))))
        let x1 = max(x0, min(width - 1, Int(ceil(normalizedXRange.upperBound * CGFloat(width - 1)))))
        let count = x1 - x0 + 1
        guard count > 0 else { return false }
        var sum: Float = 0
        let base = row * width
        for x in x0...x1 {
            sum += probabilities[base + x]
        }
        return (sum / Float(count)) > threshold
    }

    /// 任意の元画像座標 (x, y) が外周連結台紙バリア上にあるか（最近傍参照）
    public func isConnectedBarrierAt(normX: Double, normY: Double) -> Bool {
        let ix = max(0, min(width - 1, Int(round(normX * Double(width - 1)))))
        let iy = max(0, min(height - 1, Int(round(normY * Double(height - 1)))))
        return connectedBarrierMask[iy * width + ix]
    }
}

/// Stage 2: 連結パラメトリック双子窓パラメータ
public struct TwinWindowParams: Sendable, Codable {
    public let leftX: CGFloat
    public let rightX: CGFloat
    public let width: CGFloat
    public let topY: CGFloat
    public let height: CGFloat
    public let rightDeltaY: CGFloat
    public let cutType: StereoPrintCutType
    public let cornerRadiusRatio: CGFloat
    public let archDropRatio: CGFloat
    public let archExponent: CGFloat
    public let fitScore: Float

    public func normalizedRect(isLeft: Bool) -> CGRect {
        let x = isLeft ? leftX : rightX
        let y = isLeft ? topY : (topY + rightDeltaY)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    public func normalizedInnerRect(isLeft: Bool) -> CGRect {
        let base = normalizedRect(isLeft: isLeft)
        switch cutType {
        case .square:
            return base
        case .rounded:
            let insetY = base.width * cornerRadiusRatio * 0.5
            return CGRect(x: base.minX, y: base.minY + insetY, width: base.width, height: max(0.01, base.height - insetY))
        case .arch:
            let drop = base.height * archDropRatio
            return CGRect(x: base.minX, y: base.minY + drop, width: base.width, height: max(0.01, base.height - drop))
        }
    }
}

/// 3段階カスケード解析の統合出力
public struct MountAnalysisOutput: Sendable {
    public let deskew: CardDeskewResult
    public let barrier: MountBarrierMap
    public let twinWindow: TwinWindowParams
    public var needsUNetFallback: Bool {
        twinWindow.fitScore < 0.55 || barrier.model.confidence < 0.35
    }
}

// MARK: - StereoCardMountAnalyzer

/// 3段階カスケードステレオカード抽出エンジン
/// - Stage 0: 物理カード本体分離 & 水平化 (Scan Margin Stripping & Deskew)
/// - Stage 1: カード固有 CIE Lab 台紙色バリア & 外周連結マスク
/// - Stage 2: 連結パラメトリック双子窓フィッティング
public enum StereoCardMountAnalyzer {

    public static func analyze(cgImage: CGImage, rgb: [UInt8]? = nil, workMaxDim: Int = 1024) -> MountAnalysisOutput? {
        let deskew = stripScanMarginAndDeskew(cgImage: cgImage, sourceRGB: rgb, workMaxDim: workMaxDim)
        guard let work = makeWorkBuffer(from: deskew.deskewedImage, maxDim: workMaxDim) else { return nil }
        let barrier = buildMountBarrier(
            lab: work.lab,
            luma: work.luma,
            width: work.width,
            height: work.height,
            bypassedMountLab: deskew.bypassedMountLab
        )
        let twinWindow = fitTwinWindows(barrier: barrier, gradMagX: work.gradX, gradMagY: work.gradY)
        return MountAnalysisOutput(deskew: deskew, barrier: barrier, twinWindow: twinWindow)
    }

    public static func buildBarrierOnly(cgImage: CGImage, workMaxDim: Int = 512) -> MountBarrierMap? {
        guard let work = makeWorkBuffer(from: cgImage, maxDim: workMaxDim) else { return nil }
        return buildMountBarrier(lab: work.lab, luma: work.luma, width: work.width, height: work.height, bypassedMountLab: nil)
    }

    // MARK: - Stage 0: 物理カード本体分離 & 水平化

    public static func stripScanMarginAndDeskew(
        cgImage: CGImage,
        sourceRGB: [UInt8]? = nil,
        workMaxDim: Int = 1024
    ) -> CardDeskewResult {
        let srcW = cgImage.width, srcH = cgImage.height
        let fallbackRGB = sourceRGB ?? extractRGBBytes(from: cgImage) ?? []
        let fallback = CardDeskewResult(
            cardRectInSource: CGRect(x: 0, y: 0, width: srcW, height: srcH),
            skewAngleRad: 0,
            hasScanMargin: false,
            deskewedSize: CGSize(width: srcW, height: srcH),
            deskewedImage: cgImage,
            deskewedRGB: fallbackRGB,
            width: srcW,
            height: srcH,
            bypassedMountLab: nil
        )
        guard srcW >= 64, srcH >= 32,
              let work = makeWorkBuffer(from: cgImage, maxDim: workMaxDim) else {
            return fallback
        }

        let w = work.width, h = work.height
        let patch = max(8, min(16, min(w, h) / 20))
        let cornerRects = [(0, 0), (w - patch, 0), (0, h - patch), (w - patch, h - patch)]
        var cornerMeans: [SIMD3<Float>] = []
        var cornerSamples: [SIMD3<Float>] = []
        for (ox, oy) in cornerRects {
            var pts: [SIMD3<Float>] = []
            pts.reserveCapacity(patch * patch)
            for y in oy..<(oy + patch) {
                for x in ox..<(ox + patch) {
                    pts.append(work.lab[y * w + x])
                }
            }
            let (med, _) = robustMedianAndMAD(pts)
            cornerMeans.append(med)
            cornerSamples.append(contentsOf: pts)
        }

        var bestBgMean: SIMD3<Float>?
        for i in 0..<4 {
            let ref = cornerMeans[i]
            guard (ref.x > 85.0) || (ref.x < 15.0) else { continue }
            if cornerMeans.filter({ simd_distance($0, ref) < 10.0 }).count >= 3 {
                bestBgMean = ref
                break
            }
        }
        guard let bgMean = bestBgMean else { return fallback }

        let (_, bgMad) = robustMedianAndMAD(cornerSamples)
        let bgTol = max(10.0, 3.5 * simd_length(bgMad))
        var isBg = [UInt8](repeating: 0, count: w * h)
        var queue = [Int]()
        queue.reserveCapacity(w * 2 + h * 2)

        func tryEnqueue(_ x: Int, _ y: Int) {
            let idx = y * w + x
            if isBg[idx] == 0 && simd_distance(work.lab[idx], bgMean) < bgTol {
                isBg[idx] = 1
                queue.append(idx)
            }
        }
        for x in 0..<w { tryEnqueue(x, 0); tryEnqueue(x, h - 1) }
        for y in 0..<h { tryEnqueue(0, y); tryEnqueue(w - 1, y) }

        var head = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            let cx = cur % w, cy = cur / w
            if cx > 0 { tryEnqueue(cx - 1, cy) }
            if cx + 1 < w { tryEnqueue(cx + 1, cy) }
            if cy > 0 { tryEnqueue(cx, cy - 1) }
            if cy + 1 < h { tryEnqueue(cx, cy + 1) }
        }

        let bgRatio = Float(queue.count) / Float(w * h)
        guard bgRatio > 0.015 && bgRatio < 0.75 else { return fallback }

        // 安全策1: 白台紙／黒台紙カード誤除去防止チェック
        // (a) 中央セパレータ帯への浸透率チェック
        let sepX0 = Int(Float(w) * 0.46), sepX1 = Int(Float(w) * 0.54)
        let sepY0 = Int(Float(h) * 0.25), sepY1 = Int(Float(h) * 0.75)
        var sepBgCount = 0, sepTotal = 0
        for y in sepY0..<sepY1 {
            let row = y * w
            for x in sepX0..<sepX1 {
                sepTotal += 1
                if isBg[row + x] == 1 { sepBgCount += 1 }
            }
        }
        let sepPenetration = Float(sepBgCount) / Float(max(1, sepTotal))
        if sepPenetration > 0.02 {
            // 白台紙（または黒台紙）そのものが画像端まで広がっているカードと判定しバイパス
            return CardDeskewResult(
                cardRectInSource: CGRect(x: 0, y: 0, width: srcW, height: srcH),
                skewAngleRad: 0, hasScanMargin: false,
                deskewedSize: CGSize(width: srcW, height: srcH),
                deskewedImage: cgImage, deskewedRGB: fallbackRGB,
                width: srcW, height: srcH,
                bypassedMountLab: bgMean
            )
        }

        // (b) フラッドフィル後に残存領域が左右2つに分断されているかチェック（密着型白台紙カード対策）
        let midX0 = Int(Float(w) * 0.45), midX1 = Int(Float(w) * 0.55)
        var minColFgInMid = h
        for x in midX0...midX1 {
            var colFg = 0
            for y in 0..<h where isBg[y * w + x] == 0 { colFg += 1 }
            if colFg < minColFgInMid { minColFgInMid = colFg }
        }
        if minColFgInMid < Int(Float(h) * 0.15) {
            return CardDeskewResult(
                cardRectInSource: CGRect(x: 0, y: 0, width: srcW, height: srcH),
                skewAngleRad: 0, hasScanMargin: false,
                deskewedSize: CGSize(width: srcW, height: srcH),
                deskewedImage: cgImage, deskewedRGB: fallbackRGB,
                width: srcW, height: srcH,
                bypassedMountLab: bgMean
            )
        }

        // 傾き推定（上下辺中央 60% 区間の RANSAC 直線フィッティング）
        let xStart = Int(Float(w) * 0.20), xEnd = Int(Float(w) * 0.80)
        var topPts: [SIMD2<Double>] = [], botPts: [SIMD2<Double>] = []
        for x in stride(from: xStart, to: xEnd, by: 2) {
            for y in 0..<h where isBg[y * w + x] == 0 {
                topPts.append(SIMD2(Double(x), Double(y)))
                break
            }
            for y in stride(from: h - 1, through: 0, by: -1) where isBg[y * w + x] == 0 {
                botPts.append(SIMD2(Double(x), Double(y)))
                break
            }
        }
        let topAngle = ransacLineAngle(points: topPts)
        let botAngle = ransacLineAngle(points: botPts)
        var skewAngle = 0.0
        if let ta = topAngle, let ba = botAngle {
            skewAngle = abs(ta - ba) < 0.06 ? (ta + ba) * 0.5 : ta
        } else if let ta = topAngle {
            skewAngle = ta
        } else if let ba = botAngle {
            skewAngle = ba
        }
        if abs(skewAngle) > (15.0 * .pi / 180.0) { skewAngle = 0 }
        // 微小傾き（0.15度未満）は無回転として画質劣化を防ぐ
        if abs(skewAngle) < (0.15 * .pi / 180.0) { skewAngle = 0 }

        var minX = w, maxX = 0, minY = h, maxY = 0
        for y in 0..<h {
            var rowFg = 0
            for x in 0..<w where isBg[y * w + x] == 0 { rowFg += 1 }
            if rowFg > w / 5 { minY = min(minY, y); maxY = max(maxY, y) }
        }
        for x in 0..<w {
            var colFg = 0
            for y in 0..<h where isBg[y * w + x] == 0 { colFg += 1 }
            if colFg > h / 5 { minX = min(minX, x); maxX = max(maxX, x) }
        }
        guard maxX > minX + 20 && maxY > minY + 20 else { return fallback }

        // ドロップシャドウ（スキャン背景→影の谷→台紙平坦面）を正確にスキップするヘルパー
        func refineShadowEdge(start: Int, dir: Int, maxScan: Int, isHorizontal: Bool) -> Int {
            let xA = isHorizontal ? Int(Float(w) * 0.30) : Int(Float(h) * 0.25)
            let xB = isHorizontal ? Int(Float(w) * 0.70) : Int(Float(h) * 0.75)
            func lineMeanLab(_ pos: Int) -> (lab: SIMD3<Float>, luma: Float) {
                var sum = SIMD3<Float>.zero
                var cnt = 0
                for t in stride(from: xA, to: xB, by: 2) {
                    let c = isHorizontal ? work.lab[pos * w + t] : work.lab[t * w + pos]
                    sum += c; cnt += 1
                }
                let m = sum / Float(max(1, cnt))
                return (m, m.x)
            }
            let limit = min(maxScan, 7)
            var prev = lineMeanLab(start)
            for d in 1..<limit {
                let pos = start + dir * d
                if isHorizontal && (pos < 0 || pos >= h) { break }
                if !isHorizontal && (pos < 0 || pos >= w) { break }
                let cur = lineMeanLab(pos)
                let distBg = simd_distance(cur.lab, bgMean)
                let stepDiff = abs(cur.luma - prev.luma)
                // スキャン背景から十分離れ、かつ影の急勾配を抜けて平坦面に入った直後で停止（極細リムを突き抜けない）
                if distBg >= 18.0 && stepDiff <= 4.5 {
                    return pos
                }
                prev = cur
            }
            return start + dir * 2
        }

        let refinedMinY = refineShadowEdge(start: minY, dir: 1, maxScan: 14, isHorizontal: true)
        let refinedMaxY = refineShadowEdge(start: maxY, dir: -1, maxScan: 14, isHorizontal: true)
        let refinedMinX = refineShadowEdge(start: minX, dir: 1, maxScan: 14, isHorizontal: false)
        let refinedMaxX = refineShadowEdge(start: maxX, dir: -1, maxScan: 14, isHorizontal: false)
        guard refinedMaxX > refinedMinX + 20 && refinedMaxY > refinedMinY + 20 else { return fallback }

        let rectWork = CGRect(
            x: refinedMinX, y: refinedMinY,
            width: refinedMaxX - refinedMinX, height: refinedMaxY - refinedMinY
        )
        let aspect = rectWork.width / rectWork.height
        // 安全策1(c): 歴史的ステレオカード規格に基づく不自然なアスペクト比ガード
        guard aspect >= 1.35 && aspect <= 2.45 else {
            return CardDeskewResult(
                cardRectInSource: CGRect(x: 0, y: 0, width: srcW, height: srcH),
                skewAngleRad: 0, hasScanMargin: false,
                deskewedSize: CGSize(width: srcW, height: srcH),
                deskewedImage: cgImage, deskewedRGB: fallbackRGB,
                width: srcW, height: srcH,
                bypassedMountLab: bgMean
            )
        }

        let scaleX = CGFloat(srcW) / CGFloat(w), scaleY = CGFloat(srcH) / CGFloat(h)
        let cardRectSrc = CGRect(
            x: rectWork.minX * scaleX, y: rectWork.minY * scaleY,
            width: rectWork.width * scaleX, height: rectWork.height * scaleY
        ).integral

        guard let deskewed = renderDeskewedCrop(cgImage: cgImage, cropRect: cardRectSrc, angleRad: -skewAngle),
              let deskewedRGB = extractRGBBytes(from: deskewed) else {
            return fallback
        }
        return CardDeskewResult(
            cardRectInSource: cardRectSrc,
            skewAngleRad: skewAngle,
            hasScanMargin: true,
            deskewedSize: CGSize(width: deskewed.width, height: deskewed.height),
            deskewedImage: deskewed,
            deskewedRGB: deskewedRGB,
            width: deskewed.width,
            height: deskewed.height,
            bypassedMountLab: nil
        )
    }

    // MARK: - Stage 1: カード固有 CIE Lab 台紙色バリア構築

    private static func buildMountBarrier(
        lab: [SIMD3<Float>],
        luma: [Float],
        width w: Int,
        height h: Int,
        bypassedMountLab: SIMD3<Float>?
    ) -> MountBarrierMap {
        var samples: [SIMD3<Float>] = []
        samples.reserveCapacity(w * h / 8)

        // 安全策2: 極細リム（6〜10px）でも純粋な台紙色を汚染なくサンプル収集するため step = 1 で最外周リム＋適応走査を行う
        func collectAdaptiveEdgeRim(isHorizontal: Bool, fromStart: Bool) {
            if isHorizontal {
                // 上端 / 下端から中央付近 (0.20..0.80) を走査（極細リム保護のため最大 1.5% 深さに限定）
                let x0 = Int(Float(w) * 0.20), x1 = Int(Float(w) * 0.80)
                let maxDepth = max(3, Int(Float(h) * 0.015))
                let refY = fromStart ? 1 : (h - 2)
                guard refY >= 0 && refY < h else { return }
                // 外縁 1px..maxDepth まで step = 1 でサンプリングし、明らかな境界ジャンプ前まで収集
                for x in stride(from: x0, to: x1, by: max(1, (x1 - x0) / 80)) {
                    let seedLab = lab[refY * w + x]
                    var rimPts = 0
                    for d in 1..<maxDepth {
                        let y = fromStart ? d : (h - 1 - d)
                        let c = lab[y * w + x]
                        if d <= 2 || simd_distance(c, seedLab) <= 10.0 {
                            samples.append(c)
                            rimPts += 1
                        } else {
                            break
                        }
                    }
                    if rimPts == 0 { samples.append(seedLab) }
                }
            } else {
                // 左端 / 右端から中央高さ帯 (0.15..0.85) を step = 1 で収集
                let y0 = Int(Float(h) * 0.15), y1 = Int(Float(h) * 0.85)
                let maxDepth = max(3, Int(Float(w) * 0.03))
                let refX = fromStart ? 1 : (w - 2)
                guard refX >= 0 && refX < w else { return }
                for y in stride(from: y0, to: y1, by: max(1, (y1 - y0) / 80)) {
                    let seedLab = lab[y * w + refX]
                    for d in 1..<maxDepth {
                        let x = fromStart ? d : (w - 1 - d)
                        let c = lab[y * w + x]
                        if d <= 2 || simd_distance(c, seedLab) <= 10.0 {
                            samples.append(c)
                        } else {
                            break
                        }
                    }
                }
            }
        }

        collectAdaptiveEdgeRim(isHorizontal: true, fromStart: true)
        collectAdaptiveEdgeRim(isHorizontal: true, fromStart: false)
        collectAdaptiveEdgeRim(isHorizontal: false, fromStart: true)
        collectAdaptiveEdgeRim(isHorizontal: false, fromStart: false)

        // 中央セパレータ候補帯からもサンプリング（step = 1）
        let midX0 = max(0, Int(Float(w) * 0.495)), midX1 = min(w - 1, Int(Float(w) * 0.505))
        let midY0 = Int(Float(h) * 0.12), midY1 = Int(Float(h) * 0.88)
        for y in stride(from: midY0, to: midY1, by: 2) {
            let row = y * w
            for x in midX0...midX1 {
                samples.append(lab[row + x])
            }
        }

        if let bLab = bypassedMountLab {
            // 白台紙カードのバイパス時、最外周の背景 Lab をアンカーとして少し補強
            for _ in 0..<64 { samples.append(bLab) }
        }

        let (med, mad) = robustMedianAndMAD(samples)
        let limit = SIMD3<Float>(max(6.0, 2.5 * mad.x), max(4.0, 2.5 * mad.y), max(4.0, 2.5 * mad.z))
        let inliers = samples.filter {
            abs($0.x - med.x) <= limit.x && abs($0.y - med.y) <= limit.y && abs($0.z - med.z) <= limit.z
        }
        let valid = inliers.count >= 32 ? inliers : samples
        var mean = SIMD3<Float>.zero
        for v in valid { mean += v }
        mean /= Float(max(1, valid.count))

        var c00: Float = 0, c01: Float = 0, c02: Float = 0, c11: Float = 0, c12: Float = 0, c22: Float = 0
        for v in valid {
            let d = v - mean
            c00 += d.x * d.x; c01 += d.x * d.y; c02 += d.x * d.z
            c11 += d.y * d.y; c12 += d.y * d.z; c22 += d.z * d.z
        }
        let denom = Float(max(1, valid.count - 1))
        let cov = simd_float3x3(columns: (
            SIMD3(c00 / denom + 16.0, c01 / denom,       c02 / denom),
            SIMD3(c01 / denom,        c11 / denom + 6.25, c12 / denom),
            SIMD3(c02 / denom,        c12 / denom,       c22 / denom + 6.25)
        ))
        let invCov = abs(cov.determinant) > 1e-6 ? cov.inverse : matrix_identity_float3x3
        let texStd = computeLocalStdDev5x5(luma: luma, width: w, height: h)

        var probs = [Float](repeating: 0, count: w * h)
        let tauD: Float = 2.5, alpha: Float = 2.0, tauTex: Float = 12.0, beta: Float = 0.25
        let maxEuclidDeltaE: Float = min(13.5, max(8.5, 3.0 * simd_length(mad)))
        var borderProbSum: Float = 0, centerProbSum: Float = 0
        var borderCount = 0, centerCount = 0

        for y in 0..<h {
            let row = y * w
            let inCenterY = y > h / 4 && y < (3 * h) / 4
            for x in 0..<w {
                let idx = row + x
                let d = lab[idx] - mean
                let euclid = simd_length(d)
                let dm = sqrt(max(0, simd_dot(d, invCov * d)))
                let euclidGate: Float = 1.0 / (1.0 + exp(0.8 * (euclid - maxEuclidDeltaE)))
                let p = (1.0 / (1.0 + exp(alpha * (dm - tauD)))) * (1.0 / (1.0 + exp(beta * (texStd[idx] - tauTex)))) * euclidGate
                probs[idx] = p
                if x < max(4, w / 40) || x > min(w - 5, (39 * w) / 40) {
                    borderProbSum += p; borderCount += 1
                } else if inCenterY && ((x > w / 6 && x < (2 * w) / 5) || (x > (3 * w) / 5 && x < (5 * w) / 6)) {
                    centerProbSum += p; centerCount += 1
                }
            }
        }

        // 安全策3: 外周（および中央セパレータ上下端）から連結している台紙バリアのみを抽出
        var connectedMask = [Bool](repeating: false, count: w * h)
        var q = [Int]()
        q.reserveCapacity(w * 2 + h * 2)
        let barrierThreshold: Float = 0.55

        func enqueueBarrier(_ x: Int, _ y: Int) {
            let idx = y * w + x
            if !connectedMask[idx] && probs[idx] >= barrierThreshold {
                connectedMask[idx] = true
                q.append(idx)
            }
        }
        for d in 0..<min(4, min(w, h) / 4) {
            for x in 0..<w {
                enqueueBarrier(x, d)
                enqueueBarrier(x, h - 1 - d)
            }
            for y in 0..<h {
                enqueueBarrier(d, y)
                enqueueBarrier(w - 1 - d, y)
            }
        }
        // 中央セパレータ上部・下部をシード補強
        let sepSeedX0 = max(0, Int(Float(w) * 0.46)), sepSeedX1 = min(w - 1, Int(Float(w) * 0.54))
        for x in sepSeedX0...sepSeedX1 {
            enqueueBarrier(x, min(h - 1, max(0, Int(Float(h) * 0.02))))
            enqueueBarrier(x, min(h - 1, max(0, Int(Float(h) * 0.98))))
        }

        var head = 0
        while head < q.count {
            let cur = q[head]; head += 1
            let cx = cur % w, cy = cur / w
            if cx > 0 { enqueueBarrier(cx - 1, cy) }
            if cx + 1 < w { enqueueBarrier(cx + 1, cy) }
            if cy > 0 { enqueueBarrier(cx, cy - 1) }
            if cy + 1 < h { enqueueBarrier(cx, cy + 1) }
        }

        let confidence = max(0, min(1, (borderProbSum / Float(max(1, borderCount))) - (centerProbSum / Float(max(1, centerCount)))))
        let model = MountColorModel(meanLab: mean, invCovLab: invCov, confidence: confidence)
        return MountBarrierMap(
            width: w,
            height: h,
            probabilities: probs,
            model: model,
            connectedBarrierMask: connectedMask
        )
    }

    // MARK: - Stage 2: 連結パラメトリック双子窓フィッティング

    private static func fitTwinWindows(
        barrier: MountBarrierMap,
        gradMagX: [Float],
        gradMagY: [Float]
    ) -> TwinWindowParams {
        let w = barrier.width, h = barrier.height
        // 連結台紙マスクの箇所は確実に写真確率0（台紙確率1.0）として扱う
        var effectivePMount = barrier.probabilities
        for i in 0..<(w * h) where barrier.connectedBarrierMask[i] {
            effectivePMount[i] = max(effectivePMount[i], 0.95)
        }

        let sat = buildIntegralImage(data: effectivePMount, width: w, height: h)
        var projX = [Float](repeating: 0, count: w)
        let y0 = h / 4, y1 = (3 * h) / 4
        for x in 0..<w {
            var s: Float = 0
            for y in y0..<y1 { s += (1.0 - effectivePMount[y * w + x]) }
            projX[x] = s / Float(max(1, y1 - y0))
        }

        let midLo = Int(Float(w) * 0.44), midHi = Int(Float(w) * 0.56)
        var xMid = w / 2, minMidVal: Float = 2.0
        for x in midLo...midHi where projX[x] < minMidVal {
            minMidVal = projX[x]; xMid = x
        }
        let lStart = (0..<xMid).first(where: { projX[$0] > 0.45 }) ?? Int(Float(w) * 0.03)
        let lEnd = (0..<xMid).reversed().first(where: { projX[$0] > 0.45 }) ?? (xMid - 2)
        let rStart = (xMid..<w).first(where: { projX[$0] > 0.45 }) ?? (xMid + 2)
        let rEnd = (xMid..<w).reversed().first(where: { projX[$0] > 0.45 }) ?? Int(Float(w) * 0.97)

        var xL = Double(lStart), xR = Double(rStart)
        var winW = max(Double(w) * 0.34, min(Double(w) * 0.495, Double((lEnd - lStart) + (rEnd - rStart)) * 0.5))

        func estimateVerticalRange(cx: Double, width: Double) -> (Double, Double) {
            let xa = max(0, Int(cx + width * 0.30)), xb = min(w - 1, Int(cx + width * 0.70))
            var projY = [Float](repeating: 0, count: h)
            for y in 0..<h {
                var s: Float = 0
                for x in xa...xb { s += (1.0 - effectivePMount[y * w + x]) }
                projY[y] = s / Float(max(1, xb - xa + 1))
            }
            let top = (0..<h).first(where: { projY[$0] > 0.45 }) ?? Int(Double(h) * 0.02)
            let bot = (0..<h).reversed().first(where: { projY[$0] > 0.45 }) ?? Int(Double(h) * 0.97)
            return (Double(top), Double(max(top + 20, bot)))
        }
        let (topL, botL) = estimateVerticalRange(cx: xL, width: winW)
        let (topR, botR) = estimateVerticalRange(cx: xR, width: winW)
        var topY = topL
        var winH = max(Double(h) * 0.65, min(Double(h) * 0.985, ((botL - topL) + (botR - topR)) * 0.5))
        var dyR = max(-Double(h) * 0.025, min(Double(h) * 0.025, topR - topL))
        let band = 10.0

        func rectEnergy(xl: Double, xr: Double, rw: Double, ty: Double, rh: Double, dr: Double) -> Double {
            guard rw >= Double(w) * 0.34, rw <= Double(w) * 0.495,
                  rh >= Double(h) * 0.65, rh <= Double(h) * 0.985,
                  xl >= 0, xl + rw <= xr + 2.0, xr + rw <= Double(w),
                  ty >= 0, ty + rh <= Double(h),
                  ty + dr >= 0, ty + dr + rh <= Double(h),
                  abs(dr) <= Double(h) * 0.025 else { return 1e9 }

            func sideRegionCost(_ x: Double, _ y: Double) -> Double {
                let inCenter = satMean(sat, w, h, x + rw * 0.15, y, x + rw * 0.85, y + rh)
                let inBody = satMean(sat, w, h, x, y + rh * 0.22, x + rw, y + rh)
                let outTop = 1.0 - satMean(sat, w, h, x + rw * 0.20, max(0, y - band), x + rw * 0.80, y)
                let outBot = 1.0 - satMean(sat, w, h, x, y + rh, x + rw, min(Double(h), y + rh + band))
                let outL = 1.0 - satMean(sat, w, h, max(0, x - band), y + rh * 0.22, x, y + rh)
                let outR = 1.0 - satMean(sat, w, h, x + rw, y + rh * 0.22, min(Double(w), x + rw + band), y + rh)
                return (inCenter + inBody) * 0.5 + (outTop + outBot + outL + outR) * 0.25
            }
            let eRegion = (sideRegionCost(xl, ty) + sideRegionCost(xr, ty + dr)) * 0.5

            func edgeStrength(_ x: Double, _ y: Double) -> Double {
                let topG = sampleHorizontalEdge(gradMagY, w, h, y: y, x0: x + rw * 0.25, x1: x + rw * 0.75)
                let botG = sampleHorizontalEdge(gradMagY, w, h, y: y + rh, x0: x + rw * 0.10, x1: x + rw * 0.90)
                let leftG = sampleVerticalEdge(gradMagX, w, h, x: x, y0: y + rh * 0.22, y1: y + rh * 0.95)
                let rightG = sampleVerticalEdge(gradMagX, w, h, x: x + rw, y0: y + rh * 0.22, y1: y + rh * 0.95)
                return (topG + botG + leftG + rightG) * 0.25
            }
            let eEdge = -0.35 * (edgeStrength(xl, ty) + edgeStrength(xr, ty + dr)) * 0.5
            let centerErr = ((xl + rw + xr) - Double(w)) / Double(w)
            let eSym = 0.25 * pow(dr / Double(h), 2) + 0.15 * pow(centerErr, 2)
            return eRegion + eEdge + eSym
        }

        var bestE = rectEnergy(xl: xL, xr: xR, rw: winW, ty: topY, rh: winH, dr: dyR)
        for step in [8.0, 2.0, 0.5] {
            for _ in 0..<4 {
                var improved = false
                for delta in [-step, step] {
                    let e1 = rectEnergy(xl: xL + delta, xr: xR, rw: winW, ty: topY, rh: winH, dr: dyR)
                    if e1 < bestE { bestE = e1; xL += delta; improved = true }
                    let e2 = rectEnergy(xl: xL, xr: xR + delta, rw: winW, ty: topY, rh: winH, dr: dyR)
                    if e2 < bestE { bestE = e2; xR += delta; improved = true }
                    let e3 = rectEnergy(xl: xL, xr: xR, rw: winW + delta, ty: topY, rh: winH, dr: dyR)
                    if e3 < bestE { bestE = e3; winW += delta; improved = true }
                    let e4 = rectEnergy(xl: xL, xr: xR, rw: winW, ty: topY + delta, rh: winH, dr: dyR)
                    if e4 < bestE { bestE = e4; topY += delta; improved = true }
                    let e5 = rectEnergy(xl: xL, xr: xR, rw: winW, ty: topY, rh: winH + delta, dr: dyR)
                    if e5 < bestE { bestE = e5; winH += delta; improved = true }
                    let e6 = rectEnergy(xl: xL, xr: xR, rw: winW, ty: topY, rh: winH, dr: dyR + delta)
                    if e6 < bestE { bestE = e6; dyR += delta; improved = true }
                }
                if !improved { break }
            }
        }

        let archExp = 2.2
        func upperCutError(cut: StereoPrintCutType, ratio: Double) -> Double {
            let yBandH = max(8, Int(winH * 0.28))
            var errSum = 0.0, cnt = 0
            for (sx, sy) in [(xL, topY), (xR, topY + dyR)] {
                let ix0 = max(0, Int(sx)), ix1 = min(w - 1, Int(sx + winW))
                let iy0 = max(0, Int(sy)), iy1 = min(h - 1, Int(sy) + yBandH)
                guard ix1 > ix0 && iy1 > iy0 else { continue }
                for x in stride(from: ix0, through: ix1, by: 2) {
                    let u = ((Double(x) - sx) / winW) * 2.0 - 1.0
                    let yCurve = sy + upperDropPixels(cut: cut, u: u, width: winW, height: winH, ratio: ratio, exp: archExp)
                    for y in stride(from: iy0, through: iy1, by: 2) {
                        let pM = Double(effectivePMount[y * w + x])
                        errSum += (Double(y) >= yCurve) ? pM : (1.0 - pM)
                        cnt += 1
                    }
                }
            }
            return errSum / Double(max(1, cnt))
        }

        var bestCut: StereoPrintCutType = .square
        var bestCutErr = upperCutError(cut: .square, ratio: 0.0)
        var bestCornerRatio = 0.0, bestArchRatio = 0.0
        for r in stride(from: 0.04, through: 0.16, by: 0.02) {
            let e = upperCutError(cut: .rounded, ratio: r) + 0.015
            if e < bestCutErr { bestCutErr = e; bestCut = .rounded; bestCornerRatio = r; bestArchRatio = 0.0 }
        }
        for ha in stride(from: 0.08, through: 0.26, by: 0.015) {
            let e = upperCutError(cut: .arch, ratio: ha) + 0.020
            if e < bestCutErr { bestCutErr = e; bestCut = .arch; bestArchRatio = ha; bestCornerRatio = 0.0 }
        }

        let fitScore = Float(max(0.0, min(1.0, 1.0 - bestCutErr * 1.5)))
        return TwinWindowParams(
            leftX: CGFloat(xL / Double(w)),
            rightX: CGFloat(xR / Double(w)),
            width: CGFloat(winW / Double(w)),
            topY: CGFloat(topY / Double(h)),
            height: CGFloat(winH / Double(h)),
            rightDeltaY: CGFloat(dyR / Double(h)),
            cutType: bestCut,
            cornerRadiusRatio: CGFloat(bestCornerRatio),
            archDropRatio: CGFloat(bestArchRatio),
            archExponent: CGFloat(archExp),
            fitScore: fitScore
        )
    }

    public static func renderAnalyticCutMask(params: TwinWindowParams, outputSize: CGSize) -> [UInt8] {
        let w = max(1, Int(outputSize.width)), h = max(1, Int(outputSize.height))
        var mask = [UInt8](repeating: 255, count: w * h)
        guard params.cutType != .square else { return mask }
        let ratio = Double(params.cutType == .arch ? params.archDropRatio : params.cornerRadiusRatio)
        let expVal = Double(params.archExponent)
        for x in 0..<w {
            let u = (Double(x) + 0.5) / Double(w) * 2.0 - 1.0
            let yDrop = upperDropPixels(cut: params.cutType, u: u, width: Double(w), height: Double(h), ratio: ratio, exp: expVal)
            let yCutoff = Int(ceil(yDrop)) + 1
            for y in 0..<min(h, max(0, yCutoff)) {
                let cov = max(0.0, min(1.0, (Double(y) + 0.5) - yDrop))
                mask[y * w + x] = UInt8(round(cov * 255.0))
            }
        }
        return mask
    }

    private static func upperDropPixels(cut: StereoPrintCutType, u: Double, width: Double, height: Double, ratio: Double, exp: Double) -> Double {
        let au = abs(u)
        switch cut {
        case .square:
            return 0.0
        case .rounded:
            let r = width * ratio
            let uEdge = max(0.0, 1.0 - (2.0 * r / max(1.0, width)))
            guard au > uEdge, r > 0 else { return 0.0 }
            let dx = (au - uEdge) * (width * 0.5)
            return r - sqrt(max(0.0, r * r - dx * dx))
        case .arch:
            return height * ratio * (1.0 - sqrt(max(0.0, 1.0 - pow(min(1.0, au), exp))))
        }
    }

    // MARK: - Internal Helpers

    private struct WorkBuffer {
        let width: Int, height: Int
        let lab: [SIMD3<Float>], luma: [Float], gradX: [Float], gradY: [Float]
    }

    private static func makeWorkBuffer(from cgImage: CGImage, maxDim: Int) -> WorkBuffer? {
        let srcW = cgImage.width, srcH = cgImage.height
        guard srcW > 0 && srcH > 0 else { return nil }
        let scale = min(1.0, Double(maxDim) / Double(max(srcW, srcH)))
        let w = max(16, Int(round(Double(srcW) * scale))), h = max(16, Int(round(Double(srcH) * scale)))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var lab = [SIMD3<Float>](repeating: .zero, count: w * h)
        var luma = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let c = sRGBToLab(r: Float(rgba[i * 4]) / 255.0, g: Float(rgba[i * 4 + 1]) / 255.0, b: Float(rgba[i * 4 + 2]) / 255.0)
            lab[i] = c; luma[i] = c.x * 2.55
        }
        var gx = [Float](repeating: 0, count: w * h), gy = [Float](repeating: 0, count: w * h)
        for y in 1..<(h - 1) {
            let r0 = (y - 1) * w, r1 = y * w, r2 = (y + 1) * w
            for x in 1..<(w - 1) {
                let dx = (-luma[r0 + x - 1] + luma[r0 + x + 1]) + 2.0 * (-luma[r1 + x - 1] + luma[r1 + x + 1]) + (-luma[r2 + x - 1] + luma[r2 + x + 1])
                let dy = (-luma[r0 + x - 1] - 2.0 * luma[r0 + x] - luma[r0 + x + 1]) + (luma[r2 + x - 1] + 2.0 * luma[r2 + x] + luma[r2 + x + 1])
                gx[r1 + x] = min(1.0, abs(dx) / 255.0)
                gy[r1 + x] = min(1.0, abs(dy) / 255.0)
            }
        }
        return WorkBuffer(width: w, height: h, lab: lab, luma: luma, gradX: gx, gradY: gy)
    }

    private static func extractRGBBytes(from cgImage: CGImage) -> [UInt8]? {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return rgb
    }

    @inline(__always)
    private static func sRGBToLab(r: Float, g: Float, b: Float) -> SIMD3<Float> {
        func linear(_ c: Float) -> Float { c <= 0.04045 ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4) }
        let lr = linear(r), lg = linear(g), lb = linear(b)
        let x = (0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb) / 0.95047
        let y = (0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb) / 1.00000
        let z = (0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrtf(t) : (7.787 * t + 16.0 / 116.0) }
        let fx = f(x), fy = f(y), fz = f(z)
        return SIMD3(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))
    }

    private static func robustMedianAndMAD(_ values: [SIMD3<Float>]) -> (SIMD3<Float>, SIMD3<Float>) {
        guard !values.isEmpty else { return (.zero, SIMD3(1, 1, 1)) }
        func medMad(_ arr: [Float]) -> (Float, Float) {
            let s = arr.sorted()
            let m = s[s.count / 2]
            let devs = s.map { abs($0 - m) }.sorted()
            return (m, max(0.5, devs[devs.count / 2] * 1.4826))
        }
        let (ml, dl) = medMad(values.map(\.x))
        let (ma, da) = medMad(values.map(\.y))
        let (mb, db) = medMad(values.map(\.z))
        return (SIMD3(ml, ma, mb), SIMD3(dl, da, db))
    }

    private static func computeLocalStdDev5x5(luma: [Float], width w: Int, height h: Int) -> [Float] {
        var sq = [Float](repeating: 0, count: w * h)
        vDSP_vsq(luma, 1, &sq, 1, vDSP_Length(w * h))
        let sat1 = buildIntegralImage(data: luma, width: w, height: h)
        let sat2 = buildIntegralImage(data: sq, width: w, height: h)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = Double(max(0, y - 2)), y1 = Double(min(h, y + 3)), row = y * w
            for x in 0..<w {
                let x0 = Double(max(0, x - 2)), x1 = Double(min(w, x + 3))
                let mean = satMean(sat1, w, h, x0, y0, x1, y1)
                let meanSq = satMean(sat2, w, h, x0, y0, x1, y1)
                out[row + x] = Float(sqrt(max(0.0, meanSq - mean * mean)))
            }
        }
        return out
    }

    private static func buildIntegralImage(data: [Float], width w: Int, height h: Int) -> [Double] {
        let stride = w + 1
        var sat = [Double](repeating: 0, count: (h + 1) * stride)
        for y in 0..<h {
            var rowSum = 0.0
            let srcRow = y * w, dstRow = (y + 1) * stride, prevRow = y * stride
            for x in 0..<w {
                rowSum += Double(data[srcRow + x])
                sat[dstRow + x + 1] = sat[prevRow + x + 1] + rowSum
            }
        }
        return sat
    }

    @inline(__always)
    private static func satMean(_ sat: [Double], _ w: Int, _ h: Int, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
        let ix0 = max(0, min(w, Int(round(x0)))), iy0 = max(0, min(h, Int(round(y0))))
        let ix1 = max(ix0, min(w, Int(round(x1)))), iy1 = max(iy0, min(h, Int(round(y1))))
        let area = (ix1 - ix0) * (iy1 - iy0)
        guard area > 0 else { return 0 }
        let stride = w + 1
        return (sat[iy1 * stride + ix1] - sat[iy0 * stride + ix1] - sat[iy1 * stride + ix0] + sat[iy0 * stride + ix0]) / Double(area)
    }

    private static func sampleHorizontalEdge(_ gy: [Float], _ w: Int, _ h: Int, y: Double, x0: Double, x1: Double) -> Double {
        let iy = max(0, min(h - 1, Int(round(y)))), ix0 = max(0, min(w - 1, Int(round(x0)))), ix1 = max(ix0, min(w - 1, Int(round(x1))))
        var s = 0.0, c = 0
        for x in stride(from: ix0, through: ix1, by: 2) { s += Double(gy[iy * w + x]); c += 1 }
        return s / Double(max(1, c))
    }

    private static func sampleVerticalEdge(_ gx: [Float], _ w: Int, _ h: Int, x: Double, y0: Double, y1: Double) -> Double {
        let ix = max(0, min(w - 1, Int(round(x)))), iy0 = max(0, min(h - 1, Int(round(y0)))), iy1 = max(iy0, min(h - 1, Int(round(y1))))
        var s = 0.0, c = 0
        for y in stride(from: iy0, through: iy1, by: 2) { s += Double(gx[y * w + ix]); c += 1 }
        return s / Double(max(1, c))
    }

    private static func ransacLineAngle(points: [SIMD2<Double>]) -> Double? {
        guard points.count >= 12 else { return nil }
        let n = points.count
        var bestInliers = 0, bestAngle = 0.0
        for i in stride(from: 0, to: n / 2, by: max(1, n / 24)) {
            let p1 = points[i], p2 = points[min(n - 1, i + n / 2)]
            let dx = p2.x - p1.x
            guard abs(dx) > 10.0 else { continue }
            let dy = p2.y - p1.y, len = hypot(dx, dy)
            let nx = -dy / len, ny = dx / len
            var inliers = 0
            for p in points where abs((p.x - p1.x) * nx + (p.y - p1.y) * ny) < 2.0 { inliers += 1 }
            if inliers > bestInliers { bestInliers = inliers; bestAngle = atan2(dy, dx) }
        }
        return bestInliers >= n / 2 ? bestAngle : nil
    }

    private static func renderDeskewedCrop(cgImage: CGImage, cropRect: CGRect, angleRad: Double) -> CGImage? {
        let outW = max(1, Int(cropRect.width)), outH = max(1, Int(cropRect.height))
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: outW * 4,
            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(outW) * 0.5, y: CGFloat(outH) * 0.5)
        if abs(angleRad) > 1e-4 { ctx.rotate(by: CGFloat(-angleRad)) }
        ctx.draw(cgImage, in: CGRect(x: -cropRect.midX, y: -(CGFloat(cgImage.height) - cropRect.midY), width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return ctx.makeImage()
    }
}
