import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import StereoCore

// MARK: - Phase 2-5: StereoCardSeg v3 3層フォールバックゲート & 回帰検証

enum SegV3GateDecision: String, Codable, Sendable {
    case pass = "Pass"
    case softWarn = "SoftWarn"
    case fallback = "Fallback"
}

struct SegV3Tier1Metrics: Codable, Sendable {
    let passed: Bool
    let reasons: [String]
    let areaLPct: Double
    let areaRPct: Double
    let lrSymmetry: Double
    let fragL: Double
    let fragR: Double
    let xOverlapRatio: Double
    let yDiffRatio: Double
    let solidityL: Double
    let solidityR: Double
    let aspectRealL: Double
    let aspectRealR: Double
    let cxOrderValid: Bool
}

struct SegV3Tier2Metrics: Codable, Sendable {
    let status: SegV3GateDecision
    let reasons: [String]
    let coreConfidence: Double
    let boundaryLow75Ratio: Double
    let boundaryMargin35Ratio: Double
    let boundaryNormEntropy: Double
    let lrConfusionRatio: Double
}

struct SegV3Tier3Metrics: Codable, Sendable {
    let passed: Bool
    let reasons: [String]
    let postIoUL: Double
    let postIoUR: Double
    let overallEdgeSupport: Double
    let worstEdgeSupport: Double
    let worstEdgeName: String
}

struct SegV3GateReport: Codable, Sendable {
    let modelVersion: String
    let decision: SegV3GateDecision
    let usedSAM2Fallback: Bool
    let v3InferenceMs: Double
    let totalElapsedMs: Double
    let tier1: SegV3Tier1Metrics
    let tier2: SegV3Tier2Metrics
    let tier3: SegV3Tier3Metrics?
}

struct SegV3SAMSeedHints: Sendable {
    let posPointL: (x: Int, y: Int)
    let posPointR: (x: Int, y: Int)
    var bgNegPoints: [(x: Int, y: Int)]
    let coreBoxL: StereoCardSegmenter.IntBox?
    let coreBoxR: StereoCardSegmenter.IntBox?
}

struct SegV3RawPrediction: Sendable {
    let width: Int
    let height: Int
    let probBg: [Float]
    let probL: [Float]
    let probR: [Float]
    let predClass: [UInt8]
    let ccMaskL: [Bool]
    let ccMaskR: [Bool]
    let boxL: StereoCardSegmenter.IntBox
    let boxR: StereoCardSegmenter.IntBox
    let splitX: Int
    let areaL: Int
    let areaR: Int
    let totalL: Int
    let totalR: Int
    let cxL: Double
    let cyL: Double
    let cxR: Double
    let cyR: Double
}

enum StereoCardSegV3Gate {

    // MARK: - 0. Softmax(T=1.0) & 最大連結成分抽出

    static func parseRawPrediction(
        probBg: [Float],
        probL: [Float],
        probR: [Float],
        predClass: [UInt8],
        width w: Int,
        height h: Int
    ) -> SegV3RawPrediction {
        let count = w * h
        let maskLAll = predClass.map { $0 == 1 }
        let maskRAll = predClass.map { $0 == 2 }

        let ccL = extractLargestCC(maskLAll, width: w, height: h)
        let ccR = extractLargestCC(maskRAll, width: w, height: h)

        let boxL = boundingBox(of: ccL.mask, width: w, height: h)
            ?? StereoCardSegmenter.IntBox(minX: 0, minY: 0, maxX: max(0, w / 2 - 1), maxY: max(0, h - 1))
        let boxR = boundingBox(of: ccR.mask, width: w, height: h)
            ?? StereoCardSegmenter.IntBox(minX: min(w - 1, w / 2), minY: 0, maxX: max(0, w - 1), maxY: max(0, h - 1))

        let splitX: Int = {
            if ccL.area > 0 && ccR.area > 0 {
                return max(1, min(w - 2, Int(((Double(boxL.maxX) + Double(boxR.minX)) * 0.5).rounded())))
            }
            return w / 2
        }()

        // 必要画素数が揃っている前提で返す
        let _ = count
        return SegV3RawPrediction(
            width: w,
            height: h,
            probBg: probBg,
            probL: probL,
            probR: probR,
            predClass: predClass,
            ccMaskL: ccL.mask,
            ccMaskR: ccR.mask,
            boxL: boxL,
            boxR: boxR,
            splitX: splitX,
            areaL: ccL.area,
            areaR: ccR.area,
            totalL: ccL.total,
            totalR: ccR.total,
            cxL: ccL.cx,
            cyL: ccL.cy,
            cxR: ccR.cx,
            cyR: ccR.cy
        )
    }

    // MARK: - 第 1 層: 構造・幾何ゲート (Hard Fail)

    static func evaluateTier1(
        raw: SegV3RawPrediction,
        origWidth: Int,
        origHeight: Int
    ) -> SegV3Tier1Metrics {
        let w = raw.width
        let h = raw.height
        let totalPx = Double(max(1, w * h))
        let areaLPct = Double(raw.areaL) / totalPx * 100.0
        let areaRPct = Double(raw.areaR) / totalPx * 100.0
        let lrSym = Double(min(raw.areaL, raw.areaR)) / Double(max(1, max(raw.areaL, raw.areaR)))
        let fragL = raw.totalL > 0 ? Double(raw.areaL) / Double(raw.totalL) : 0.0
        let fragR = raw.totalR > 0 ? Double(raw.areaR) / Double(raw.totalR) : 0.0

        let lw = max(1, raw.boxL.maxX - raw.boxL.minX + 1)
        let lh = max(1, raw.boxL.maxY - raw.boxL.minY + 1)
        let rw = max(1, raw.boxR.maxX - raw.boxR.minX + 1)
        let rh = max(1, raw.boxR.maxY - raw.boxR.minY + 1)

        let overlapW = max(0, min(raw.boxL.maxX, raw.boxR.maxX) - max(raw.boxL.minX, raw.boxR.minX) + 1)
        let meanW = 0.5 * Double(lw + rw)
        let xOverlapRatio = Double(overlapW) / max(1.0, meanW)

        let dy0 = abs(raw.boxL.minY - raw.boxR.minY)
        let dy1 = abs(raw.boxL.maxY - raw.boxR.maxY)
        let dcy = abs(raw.cyL - raw.cyR)
        let yDiffRatio = max(Double(max(dy0, dy1)), dcy) / Double(max(1, h))

        let solL = raw.areaL > 0 ? Double(raw.areaL) / max(1.0, convexHullArea(mask: raw.ccMaskL, width: w, height: h)) : 0.0
        let solR = raw.areaR > 0 ? Double(raw.areaR) / max(1.0, convexHullArea(mask: raw.ccMaskR, width: w, height: h)) : 0.0

        // 縦横比は必ず元画像空間に換算して評価（512x256空間では縦長外れ値が隠れるため）
        let realW = Double(max(1, origWidth))
        let realH = Double(max(1, origHeight))
        let arRealL = (Double(lw) / Double(w) * realW) / max(1e-6, Double(lh) / Double(h) * realH)
        let arRealR = (Double(rw) / Double(w) * realW) / max(1e-6, Double(rh) / Double(h) * realH)

        let cxOrderValid = raw.areaL > 0 && raw.areaR > 0 && (raw.cxL < raw.cxR)

        var reasons: [String] = []
        if areaLPct < 8.0 || areaLPct > 49.5 || areaRPct < 8.0 || areaRPct > 49.5 || (areaLPct + areaRPct) > 98.5 {
            reasons.append(String(format: "area_out_of_range(L=%.1f%%,R=%.1f%%)", areaLPct, areaRPct))
        }
        if lrSym < 0.72 {
            reasons.append(String(format: "lr_asym(%.2f<0.72)", lrSym))
        }
        if !cxOrderValid {
            reasons.append("cx_reversed_or_empty")
        }
        if xOverlapRatio > 0.15 {
            reasons.append(String(format: "x_overlap(%.2f>0.15)", xOverlapRatio))
        }
        if yDiffRatio > 0.12 {
            reasons.append(String(format: "y_diff(%.2f>0.12)", yDiffRatio))
        }
        if min(fragL, fragR) < 0.85 {
            reasons.append(String(format: "fragmented(L=%.2f,R=%.2f)", fragL, fragR))
        }
        if min(solL, solR) < 0.80 {
            reasons.append(String(format: "low_solidity(L=%.2f,R=%.2f)", solL, solR))
        }
        if arRealL < 0.45 || arRealL > 1.60 || arRealR < 0.45 || arRealR > 1.60 {
            reasons.append(String(format: "aspect_real(L=%.2f,R=%.2f)", arRealL, arRealR))
        }

        return SegV3Tier1Metrics(
            passed: reasons.isEmpty,
            reasons: reasons,
            areaLPct: areaLPct,
            areaRPct: areaRPct,
            lrSymmetry: lrSym,
            fragL: fragL,
            fragR: fragR,
            xOverlapRatio: xOverlapRatio,
            yDiffRatio: yDiffRatio,
            solidityL: solL,
            solidityR: solR,
            aspectRealL: arRealL,
            aspectRealR: arRealR,
            cxOrderValid: cxOrderValid
        )
    }

    // MARK: - 第 2 層: 確率・確信度ゲート (T=1.0, 実測キャリブレーション済み)

    static func evaluateTier2(raw: SegV3RawPrediction) -> SegV3Tier2Metrics {
        let w = raw.width
        let h = raw.height
        let pred = raw.predClass
        let invLn3 = 1.0 / log(3.0)

        var coreSum = 0.0
        var coreCnt = 0

        var bandCnt = 0
        var low75Cnt = 0
        var margin35Cnt = 0
        var entropySum = 0.0

        var lrConfCnt = 0

        for y in 0..<h {
            let y0 = max(0, y - 2)
            let y1 = min(h - 1, y + 2)
            let yCore0 = max(0, y - 3)
            let yCore1 = min(h - 1, y + 3)

            for x in 0..<w {
                let idx = y * w + x
                let p0 = Double(raw.probBg[idx])
                let p1 = Double(raw.probL[idx])
                let p2 = Double(raw.probR[idx])

                if p1 >= 0.25 && p2 >= 0.25 {
                    lrConfCnt += 1
                }

                // ソートした上位2確率
                let top1: Double
                let top2: Double
                if p0 >= p1 && p0 >= p2 {
                    top1 = p0
                    top2 = max(p1, p2)
                } else if p1 >= p0 && p1 >= p2 {
                    top1 = p1
                    top2 = max(p0, p2)
                } else {
                    top1 = p2
                    top2 = max(p0, p1)
                }

                // 前景コア (3px 収縮 = 7x7 すべて前景クラス)
                if pred[idx] != 0 && x >= 3 && x < w - 3 && y >= 3 && y < h - 3 {
                    var allFg = true
                    outerCore: for cy in yCore0...yCore1 {
                        let row = cy * w
                        for cx in (x - 3)...(x + 3) {
                            if pred[row + cx] == 0 {
                                allFg = false
                                break outerCore
                            }
                        }
                    }
                    if allFg {
                        coreSum += top1
                        coreCnt += 1
                    }
                }

                // 境界 5px バンド (5x5 内に異なるクラスが存在)
                let x0 = max(0, x - 2)
                let x1 = min(w - 1, x + 2)
                let centerC = pred[idx]
                var isEdge = false
                outerEdge: for ey in y0...y1 {
                    let row = ey * w
                    for ex in x0...x1 {
                        if pred[row + ex] != centerC {
                            isEdge = true
                            break outerEdge
                        }
                    }
                }
                if isEdge {
                    bandCnt += 1
                    if top1 < 0.75 { low75Cnt += 1 }
                    if (top1 - top2) < 0.35 { margin35Cnt += 1 }
                    let q0 = max(1e-7, p0), q1 = max(1e-7, p1), q2 = max(1e-7, p2)
                    let hVal = -(q0 * log(q0) + q1 * log(q1) + q2 * log(q2)) * invLn3
                    entropySum += hVal
                }
            }
        }

        let coreConf = coreCnt > 0 ? coreSum / Double(coreCnt) : 0.0
        let bLow75 = bandCnt > 0 ? Double(low75Cnt) / Double(bandCnt) : 1.0
        let bMgn35 = bandCnt > 0 ? Double(margin35Cnt) / Double(bandCnt) : 1.0
        let bEnt = bandCnt > 0 ? entropySum / Double(bandCnt) : 1.0
        let minArea = max(1, min(raw.areaL, raw.areaR))
        let lrConfRatio = Double(lrConfCnt) / Double(minArea)

        var fallbackReasons: [String] = []
        var warnReasons: [String] = []

        if coreConf < 0.89 {
            fallbackReasons.append(String(format: "core_conf(%.3f<0.89)", coreConf))
        }
        if bLow75 > 0.75 {
            fallbackReasons.append(String(format: "b_low75(%.1f%%>75%%)", bLow75 * 100.0))
        } else if bLow75 >= 0.65 {
            warnReasons.append(String(format: "b_low75_warn(%.1f%%)", bLow75 * 100.0))
        }
        if bMgn35 > 0.48 {
            fallbackReasons.append(String(format: "b_mgn35(%.1f%%>48%%)", bMgn35 * 100.0))
        } else if bMgn35 >= 0.40 {
            warnReasons.append(String(format: "b_mgn35_warn(%.1f%%)", bMgn35 * 100.0))
        }
        if bEnt > 0.715 {
            fallbackReasons.append(String(format: "b_ent(%.3f>0.715)", bEnt))
        } else if bEnt >= 0.68 {
            warnReasons.append(String(format: "b_ent_warn(%.3f)", bEnt))
        }
        if lrConfRatio > 0.03 {
            fallbackReasons.append(String(format: "lr_conf(%.1f%%>3%%)", lrConfRatio * 100.0))
        }

        let status: SegV3GateDecision
        let reasons: [String]
        if !fallbackReasons.isEmpty {
            status = .fallback
            reasons = fallbackReasons + warnReasons
        } else if !warnReasons.isEmpty {
            status = .softWarn
            reasons = warnReasons
        } else {
            status = .pass
            reasons = []
        }

        return SegV3Tier2Metrics(
            status: status,
            reasons: reasons,
            coreConfidence: coreConf,
            boundaryLow75Ratio: bLow75,
            boundaryMargin35Ratio: bMgn35,
            boundaryNormEntropy: bEnt,
            lrConfusionRatio: lrConfRatio
        )
    }

    // MARK: - 第 3 層: 後処理整合性ゲート (IoU乖離 + 辺別エッジ/中央値台紙色差支持率)

    static func evaluateTier3(
        raw: SegV3RawPrediction,
        refinedAlphaL: [UInt8],
        refinedAlphaR: [UInt8],
        cardRGB: [UInt8],
        cardW: Int,
        cardH: Int,
        prelimCardRGB: (r: Double, g: Double, b: Double)?,
        tier2: SegV3Tier2Metrics
    ) -> SegV3Tier3Metrics {
        // 1. 補正前後 IoU (512x256 空間で raw.ccMaskL/R と比較)
        let rw = raw.width
        let rh = raw.height
        var interL = 0, unionL = 0
        var interR = 0, unionR = 0

        if cardW > 0, cardH > 0, refinedAlphaL.count >= cardW * cardH, refinedAlphaR.count >= cardW * cardH {
            for y in 0..<rh {
                let sy = min(cardH - 1, max(0, (y * cardH) / rh))
                let sRow = sy * cardW
                let dRow = y * rw
                for x in 0..<rw {
                    let sx = min(cardW - 1, max(0, (x * cardW) / rw))
                    let postL = refinedAlphaL[sRow + sx] >= 128
                    let postR = refinedAlphaR[sRow + sx] >= 128
                    let preL = raw.ccMaskL[dRow + x]
                    let preR = raw.ccMaskR[dRow + x]
                    if postL && preL { interL += 1 }
                    if postL || preL { unionL += 1 }
                    if postR && preR { interR += 1 }
                    if postR || preR { unionR += 1 }
                }
            }
        }
        let postIoUL = unionL > 0 ? Double(interL) / Double(unionL) : 0.0
        let postIoUR = unionR > 0 ? Double(interR) / Double(unionR) : 0.0

        // 2. 辺別エッジ＋中央値台紙色差支持率 (スタンプ・印刷文字耐性)
        let boxL = alphaBoundingBox(refinedAlphaL, width: cardW, height: cardH)
        let boxR = alphaBoundingBox(refinedAlphaR, width: cardW, height: cardH)

        struct EdgeScore {
            let name: String
            let support: Double
        }

        func evalBoxEdges(box: StereoCardSegmenter.IntBox?, sideTag: String) -> [EdgeScore] {
            guard let b = box, b.maxX - b.minX >= 16, b.maxY - b.minY >= 16,
                  cardRGB.count >= cardW * cardH * 3 else {
                return [
                    EdgeScore(name: "\(sideTag)_top", support: 0.0),
                    EdgeScore(name: "\(sideTag)_bottom", support: 0.0),
                    EdgeScore(name: "\(sideTag)_left", support: 0.0),
                    EdgeScore(name: "\(sideTag)_right", support: 0.0),
                ]
            }

            let bw = b.maxX - b.minX + 1
            let bh = b.maxY - b.minY + 1
            let nSamples = 24

            func lumaAt(_ x: Int, _ y: Int) -> Double {
                let cx = min(cardW - 1, max(0, x))
                let cy = min(cardH - 1, max(0, y))
                let i = (cy * cardW + cx) * 3
                return (Double(cardRGB[i]) + Double(cardRGB[i + 1]) + Double(cardRGB[i + 2])) / 3.0
            }

            func rgbAt(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
                let cx = min(cardW - 1, max(0, x))
                let cy = min(cardH - 1, max(0, y))
                let i = (cy * cardW + cx) * 3
                return (Double(cardRGB[i]), Double(cardRGB[i + 1]), Double(cardRGB[i + 2]))
            }

            func trimmedMedianRGB(_ list: [(r: Double, g: Double, b: Double)]) -> (r: Double, g: Double, b: Double)? {
                guard !list.isEmpty else { return nil }
                let rs = list.map(\.r).sorted()
                let gs = list.map(\.g).sorted()
                let bs = list.map(\.b).sorted()
                let k = rs.count
                let lo = min(k - 1, Int(Double(k) * 0.20))
                let hi = max(lo + 1, Int(Double(k) * 0.80))
                let sliceCount = Double(max(1, hi - lo))
                let mr = rs[lo..<hi].reduce(0.0, +) / sliceCount
                let mg = gs[lo..<hi].reduce(0.0, +) / sliceCount
                let mb = bs[lo..<hi].reduce(0.0, +) / sliceCount
                return (mr, mg, mb)
            }

            func measureEdge(name: String, pts: [(x: Int, y: Int)], nx: Int, ny: Int) -> EdgeScore {
                var outSamples: [(r: Double, g: Double, b: Double)] = []
                var inSamples: [(r: Double, g: Double, b: Double)] = []
                var maxGrads: [Double] = []

                for p in pts {
                    // 画像端ぴったりに位置する辺は背景マージンが外側になく、境界支持を測る対象外（または支持あり）
                    let ox = p.x + nx * 5
                    let oy = p.y + ny * 5
                    if ox < 0 || ox >= cardW || oy < 0 || oy >= cardH {
                        continue
                    }

                    // 外側 +4..+7px 平均
                    var orS = 0.0, ogS = 0.0, obS = 0.0, oc = 0
                    for d in 4...7 {
                        let px = p.x + nx * d
                        let py = p.y + ny * d
                        if px >= 0 && px < cardW && py >= 0 && py < cardH {
                            let c = rgbAt(px, py)
                            orS += c.r; ogS += c.g; obS += c.b; oc += 1
                        }
                    }
                    // 内側 -5..-2px 平均
                    var irS = 0.0, igS = 0.0, ibS = 0.0, ic = 0
                    for d in 2...5 {
                        let px = p.x - nx * d
                        let py = p.y - ny * d
                        if px >= 0 && px < cardW && py >= 0 && py < cardH {
                            let c = rgbAt(px, py)
                            irS += c.r; igS += c.g; ibS += c.b; ic += 1
                        }
                    }
                    guard oc > 0, ic > 0 else { continue }
                    outSamples.append((orS / Double(oc), ogS / Double(oc), obS / Double(oc)))
                    inSamples.append((irS / Double(ic), igS / Double(ic), ibS / Double(ic)))

                    // 法線方向 ±3px の最大 Sobel 風勾配（1D中心差分）
                    var bestG = 0.0
                    for k in -2...2 {
                        let gx0 = p.x + nx * (k - 1), gy0 = p.y + ny * (k - 1)
                        let gx1 = p.x + nx * (k + 1), gy1 = p.y + ny * (k + 1)
                        let g = abs(lumaAt(gx1, gy1) - lumaAt(gx0, gy0)) * 0.5
                        if g > bestG { bestG = g }
                    }
                    maxGrads.append(bestG)
                }

                guard !outSamples.isEmpty else {
                    // 画像端ぴったり（マージンゼロ）の辺は破綻扱いしない
                    return EdgeScore(name: name, support: 1.0)
                }

                // 辺全体の中央値台紙色（スタンプ・文字などの局所異常色を除外）
                let edgeMedCard = trimmedMedianRGB(outSamples)
                var supported = 0
                for i in 0..<outSamples.count {
                    let grad = maxGrads[i]
                    let o = outSamples[i]
                    let inn = inSamples[i]
                    let inOutDiff = max(abs(o.r - inn.r), max(abs(o.g - inn.g), abs(o.b - inn.b)))

                    var closeToCard = false
                    if let med = edgeMedCard {
                        let dMed = max(abs(o.r - med.r), max(abs(o.g - med.g), abs(o.b - med.b)))
                        if dMed <= 28.0 { closeToCard = true }
                    }
                    if let pre = prelimCardRGB {
                        let dPre = max(abs(o.r - pre.r), max(abs(o.g - pre.g), abs(o.b - pre.b)))
                        if dPre <= 28.0 { closeToCard = true }
                    }

                    if grad >= 10.0 || (closeToCard && inOutDiff >= 14.0) {
                        supported += 1
                    }
                }
                return EdgeScore(name: name, support: Double(supported) / Double(outSamples.count))
            }

            var topPts: [(Int, Int)] = []
            var botPts: [(Int, Int)] = []
            for k in 0..<nSamples {
                let t = 0.15 + 0.70 * Double(k) / Double(max(1, nSamples - 1))
                let px = b.minX + Int((t * Double(bw - 1)).rounded())
                topPts.append((px, b.minY))
                botPts.append((px, b.maxY))
            }
            var leftPts: [(Int, Int)] = []
            var rightPts: [(Int, Int)] = []
            for k in 0..<nSamples {
                let t = 0.22 + 0.65 * Double(k) / Double(max(1, nSamples - 1))
                let py = b.minY + Int((t * Double(bh - 1)).rounded())
                leftPts.append((b.minX, py))
                rightPts.append((b.maxX, py))
            }

            var edges = [
                measureEdge(name: "\(sideTag)_top", pts: topPts, nx: 0, ny: -1),
                measureEdge(name: "\(sideTag)_bottom", pts: botPts, nx: 0, ny: 1),
                measureEdge(name: "\(sideTag)_left", pts: leftPts, nx: -1, ny: 0),
                measureEdge(name: "\(sideTag)_right", pts: rightPts, nx: 1, ny: 0),
            ]
            if isZeroGapCenter {
                if sideTag == "L" {
                    edges.removeAll { $0.name == "L_right" }
                } else if sideTag == "R" {
                    edges.removeAll { $0.name == "R_left" }
                }
            }
            return edges
        }

        let isZeroGapCenter: Bool = {
            guard let bl = boxL, let br = boxR else { return false }
            return Double(br.minX - bl.maxX) < Double(max(1, cardW)) * 0.015
        }()

        let allEdges = evalBoxEdges(box: boxL, sideTag: "L") + evalBoxEdges(box: boxR, sideTag: "R")
        let overallSupport = allEdges.map(\.support).reduce(0.0, +) / Double(max(1, allEdges.count))
        let worstEdge = allEdges.min(by: { $0.support < $1.support }) ?? EdgeScore(name: "none", support: 0.0)
        let weakEdgeCount = allEdges.filter { $0.support < 0.30 }.count

        var reasons: [String] = []
        let minPostIoU = min(postIoUL, postIoUR)
        if minPostIoU < 0.82 {
            reasons.append(String(format: "post_iou_diverge(L=%.2f,R=%.2f)", postIoUL, postIoUR))
        }
        let inCaution = (tier2.status == .softWarn) || (tier2.boundaryLow75Ratio >= 0.65)
        if inCaution && (overallSupport < 0.60 || weakEdgeCount >= 2 || worstEdge.support < 0.15) {
            reasons.append(String(format: "weak_edge_in_caution(avg=%.2f,weak=%d,worst=%.2f[%@])",
                                  overallSupport, weakEdgeCount, worstEdge.support, worstEdge.name))
        }

        return SegV3Tier3Metrics(
            passed: reasons.isEmpty,
            reasons: reasons,
            postIoUL: postIoUL,
            postIoUR: postIoUR,
            overallEdgeSupport: overallSupport,
            worstEdgeSupport: worstEdge.support,
            worstEdgeName: worstEdge.name
        )
    }

    // MARK: - SAM 2.1 フォールバック用プロンプト種生成（全面写真ネガティブ点欠損ガード付き）

    static func buildSAMSeedHints(from raw: SegV3RawPrediction) -> SegV3SAMSeedHints {
        let w = raw.width
        let h = raw.height

        func centroidForClass(prob: [Float], mask: [Bool], box: StereoCardSegmenter.IntBox, threshold: Float) -> (Int, Int) {
            var sumX = 0, sumY = 0, cnt = 0
            for y in box.minY...box.maxY {
                let row = y * w
                for x in box.minX...box.maxX {
                    let idx = row + x
                    if mask[idx] && prob[idx] > threshold {
                        sumX += x; sumY += y; cnt += 1
                    }
                }
            }
            if cnt >= 16 {
                return (sumX / cnt, sumY / cnt)
            }
            sumX = 0; sumY = 0; cnt = 0
            for y in box.minY...box.maxY {
                let row = y * w
                for x in box.minX...box.maxX {
                    let idx = row + x
                    if mask[idx] && prob[idx] > 0.50 {
                        sumX += x; sumY += y; cnt += 1
                    }
                }
            }
            if cnt > 0 {
                return (sumX / cnt, sumY / cnt)
            }
            return ((box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2)
        }

        let posL = centroidForClass(prob: raw.probL, mask: raw.ccMaskL, box: raw.boxL, threshold: 0.85)
        let posR = centroidForClass(prob: raw.probR, mask: raw.ccMaskR, box: raw.boxR, threshold: 0.85)

        // 1. 高確信度背景点 P(Bg) > 0.88 を四隅 + 中央上下谷間から収集
        let candidateNorms: [(Double, Double)] = [
            (0.02, 0.02), (0.98, 0.02), (0.02, 0.98), (0.98, 0.98),
            (Double(raw.splitX) / Double(max(1, w - 1)), 0.05),
            (Double(raw.splitX) / Double(max(1, w - 1)), 0.95),
        ]
        var negPts: [(Int, Int)] = []
        for (nx, ny) in candidateNorms {
            let rx = max(0, min(w - 1, Int((nx * Double(w - 1)).rounded())))
            let ry = max(0, min(h - 1, Int((ny * Double(h - 1)).rounded())))
            if raw.probBg[ry * w + rx] > 0.88 {
                negPts.append((rx, ry))
            }
        }

        // 2. 全面写真カード等でのネガティブ点欠損ガード:
        //    P(Bg) > 0.88 が 2 点未満なら外周 8% 帯 & 中央谷間から P(Bg) > 0.50 の上位点を補完
        if negPts.count < 2 {
            var perimeterBg: [(x: Int, y: Int, prob: Float)] = []
            let marginX = max(4, Int(Double(w) * 0.08))
            let marginY = max(4, Int(Double(h) * 0.08))
            for y in stride(from: 1, to: h - 1, by: 2) {
                for x in stride(from: 1, to: w - 1, by: 2) {
                    let isPerim = (x < marginX || x >= w - marginX || y < marginY || y >= h - marginY || abs(x - raw.splitX) <= 4)
                    if isPerim {
                        let p = raw.probBg[y * w + x]
                        if p > 0.50 {
                            perimeterBg.append((x, y, p))
                        }
                    }
                }
            }
            perimeterBg.sort { $0.prob > $1.prob }
            for cand in perimeterBg {
                let tooClose = negPts.contains { abs($0.0 - cand.x) < 16 && abs($0.1 - cand.y) < 16 }
                if !tooClose {
                    negPts.append((cand.x, cand.y))
                    if negPts.count >= 4 { break }
                }
            }
        }

        func highConfCoreBox(prob: [Float], mask: [Bool], fullBox: StereoCardSegmenter.IntBox, fullArea: Int) -> StereoCardSegmenter.IntBox? {
            guard fullArea > 0 else { return nil }
            var minX = w, maxX = -1, minY = h, maxY = -1, cnt = 0
            for y in fullBox.minY...fullBox.maxY {
                let row = y * w
                for x in fullBox.minX...fullBox.maxX {
                    let idx = row + x
                    if mask[idx] && prob[idx] >= 0.78 {
                        cnt += 1
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                }
            }
            guard maxX > minX + 8, maxY > minY + 8, Double(cnt) / Double(fullArea) >= 0.55 else {
                return nil
            }
            return StereoCardSegmenter.IntBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        }

        let coreBoxL = highConfCoreBox(prob: raw.probL, mask: raw.ccMaskL, fullBox: raw.boxL, fullArea: raw.areaL)
        let coreBoxR = highConfCoreBox(prob: raw.probR, mask: raw.ccMaskR, fullBox: raw.boxR, fullArea: raw.areaR)

        // 下辺膨張が大きい場合の安全補助背景負点（coreBox 下側かつ probBg >= 0.35 のみ）
        for (cb, fb) in [(coreBoxL, raw.boxL), (coreBoxR, raw.boxR)] {
            if let cb, fb.maxY - cb.maxY >= 4 {
                let ny = min(h - 1, cb.maxY + 6)
                let nx = (cb.minX + cb.maxX) / 2
                if raw.probBg[ny * w + nx] >= 0.35 {
                    let tooClose = negPts.contains { abs($0.0 - nx) < 12 && abs($0.1 - ny) < 12 }
                    if !tooClose {
                        negPts.append((nx, ny))
                    }
                }
            }
        }

        return SegV3SAMSeedHints(
            posPointL: posL,
            posPointR: posR,
            bgNegPoints: negPts,
            coreBoxL: coreBoxL,
            coreBoxR: coreBoxR
        )
    }

    // MARK: - Geometry & Connected Component Helpers

    private static func extractLargestCC(_ mask: [Bool], width w: Int, height h: Int) -> (area: Int, total: Int, cx: Double, cy: Double, mask: [Bool]) {
        let count = w * h
        guard count > 0, mask.count >= count else {
            return (0, 0, 0, 0, [Bool](repeating: false, count: max(0, count)))
        }
        var visited = [Bool](repeating: false, count: count)
        var bestPts: [Int] = []
        var total = 0
        var queue = [Int]()
        queue.reserveCapacity(count / 4)

        for start in 0..<count {
            if !mask[start] { continue }
            total += 1
            if visited[start] { continue }
            visited[start] = true
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var head = 0
            while head < queue.count {
                let idx = queue[head]
                head += 1
                let y = idx / w
                let x = idx % w
                if y > 0 {
                    let n = idx - w
                    if mask[n] && !visited[n] { visited[n] = true; queue.append(n) }
                }
                if y + 1 < h {
                    let n = idx + w
                    if mask[n] && !visited[n] { visited[n] = true; queue.append(n) }
                }
                if x > 0 {
                    let n = idx - 1
                    if mask[n] && !visited[n] { visited[n] = true; queue.append(n) }
                }
                if x + 1 < w {
                    let n = idx + 1
                    if mask[n] && !visited[n] { visited[n] = true; queue.append(n) }
                }
            }
            if queue.count > bestPts.count {
                bestPts = queue
            }
        }

        var outMask = [Bool](repeating: false, count: count)
        if bestPts.isEmpty {
            return (0, total, 0, 0, outMask)
        }
        var sx = 0, sy = 0
        for idx in bestPts {
            outMask[idx] = true
            sx += idx % w
            sy += idx / w
        }
        return (bestPts.count, total, Double(sx) / Double(bestPts.count), Double(sy) / Double(bestPts.count), outMask)
    }

    private static func boundingBox(of mask: [Bool], width w: Int, height h: Int) -> StereoCardSegmenter.IntBox? {
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where mask[row + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return StereoCardSegmenter.IntBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private static func alphaBoundingBox(_ alpha: [UInt8], width w: Int, height h: Int) -> StereoCardSegmenter.IntBox? {
        guard w > 0, h > 0, alpha.count >= w * h else { return nil }
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where alpha[row + x] >= 128 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return StereoCardSegmenter.IntBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private static func convexHullArea(mask: [Bool], width w: Int, height h: Int) -> Double {
        var pts: [(x: Int, y: Int)] = []
        pts.reserveCapacity(h * 2)
        for y in 0..<h {
            let row = y * w
            var minX = w, maxX = -1
            for x in 0..<w where mask[row + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
            if maxX >= minX {
                pts.append((minX, y))
                if maxX != minX { pts.append((maxX, y)) }
            }
        }
        guard pts.count >= 3 else { return Double(pts.count) }
        pts.sort { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }

        func cross(_ o: (x: Int, y: Int), _ a: (x: Int, y: Int), _ b: (x: Int, y: Int)) -> Int {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [(x: Int, y: Int)] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [(x: Int, y: Int)] = []
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        let hull = lower + upper
        guard hull.count >= 3 else { return 0 }
        var area2 = 0
        for i in 0..<hull.count {
            let p1 = hull[i]
            let p2 = hull[(i + 1) % hull.count]
            area2 += p1.x * p2.y - p2.x * p1.y
        }
        return Double(abs(area2)) * 0.5
    }
}

// MARK: - Phase 2-5 CLI 回帰検証ベンチマーク (--eval-v3-gates)

enum StereoCardSegV3Benchmark {

    private struct SplitManifest: Decodable {
        let val_stems: [String]
    }

    struct RegressionRow: Codable {
        let stem: String
        let group: String
        let decision: String
        let usedSAM2Fallback: Bool
        let elapsedMs: Double
        let v3Ms: Double
        let postMIoUPct: Double?
        let postBgIoUPct: Double?
        let postLIoUPct: Double?
        let postRIoUPct: Double?
        let postBoundaryMIoUPct: Double?
        let tier1Passed: Bool
        let tier1Reasons: String
        let tier2Status: String
        let coreConf: Double
        let boundaryLow75Pct: Double
        let boundaryMargin35Pct: Double
        let boundaryEntropy: Double
        let lrConfusionPct: Double
        let tier3Passed: Bool?
        let postIoUL: Double?
        let postIoUR: Double?
        let edgeSupportAvg: Double?
        let edgeSupportWorst: Double?
        let worstEdgeName: String?
        let tier3Reasons: String
    }

    static func runFromCLI(arguments: [String]) -> Int32 {
        let rootDir = "/Users/okano/マイドライブ/DEV/ViewStereo"
        let manifestURL = URL(fileURLWithPath: "\(rootDir)/tools/split_manifest.json")
        guard let mData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(SplitManifest.self, from: mData) else {
            fputs("[Phase2-5] ERROR: Cannot load split_manifest.json at \(manifestURL.path)\n", stderr)
            return 1
        }

        var targets: [(stem: String, group: String, imgURL: URL, maskURL: URL?)] = []
        for stem in manifest.val_stems {
            targets.append((
                stem: stem,
                group: "val",
                imgURL: URL(fileURLWithPath: "\(rootDir)/dataset_3class/images/\(stem).png"),
                maskURL: URL(fileURLWithPath: "\(rootDir)/dataset_3class/masks/\(stem).png")
            ))
        }
        for outlierStem in ["13375-9310", "default"] {
            targets.append((
                stem: outlierStem,
                group: "outlier",
                imgURL: URL(fileURLWithPath: "\(rootDir)/dataset_3class/_excluded_outliers/images/\(outlierStem).png"),
                maskURL: nil
            ))
        }

        print("[Phase2-5] Running real app regression on \(targets.count) images (Val=\(manifest.val_stems.count), Outliers=2)...")
        fflush(stdout)

        var rows: [RegressionRow] = []
        for (idx, item) in targets.enumerated() {
            autoreleasepool {
                guard let (rgb, w, h) = ViewStereoViewModel.loadNormalizedRGB(url: item.imgURL) else {
                    fputs("[Phase2-5] WARN: Failed to decode \(item.imgURL.path)\n", stderr)
                    return
                }
                let t0 = CFAbsoluteTimeGetCurrent()
                let crop = StereoCardSegmenter.shared.extractPhotoPair(from: rgb, width: w, height: h, mode: .keepArchBlack)
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                let report = StereoCardSegmenter.shared.latestGateReport

                var postMIoU: Double? = nil
                var postBg: Double? = nil
                var postL: Double? = nil
                var postR: Double? = nil
                var postBIoU: Double? = nil

                if crop != nil,
                   let maskURL = item.maskURL,
                   let (gtLabels, gtW, gtH) = loadGrayscaleClassMask(url: maskURL),
                   let mountCtx = StereoCardSegmenter.shared.currentMountContext,
                   let fullAlphas = StereoCardSegmenter.shared.currentFullCardAlphas {
                    let scores = evaluateOutputVsGT(
                        alphaL: fullAlphas.left,
                        alphaR: fullAlphas.right,
                        outW: mountCtx.cardWidth,
                        outH: mountCtx.cardHeight,
                        gtLabels: gtLabels,
                        gtW: gtW,
                        gtH: gtH,
                        evalW: 512,
                        evalH: 256
                    )
                    postMIoU = scores.miou * 100.0
                    postBg = scores.bgIoU * 100.0
                    postL = scores.lIoU * 100.0
                    postR = scores.rIoU * 100.0
                    postBIoU = scores.boundaryIoU * 100.0
                }

                let row = RegressionRow(
                    stem: item.stem,
                    group: item.group,
                    decision: report?.decision.rawValue ?? (crop == nil ? "NilExtract" : "V2OrHeuristic"),
                    usedSAM2Fallback: report?.usedSAM2Fallback ?? false,
                    elapsedMs: (elapsedMs * 100).rounded() / 100,
                    v3Ms: report.map { ($0.v3InferenceMs * 100).rounded() / 100 } ?? 0.0,
                    postMIoUPct: postMIoU.map { ($0 * 100).rounded() / 100 },
                    postBgIoUPct: postBg.map { ($0 * 100).rounded() / 100 },
                    postLIoUPct: postL.map { ($0 * 100).rounded() / 100 },
                    postRIoUPct: postR.map { ($0 * 100).rounded() / 100 },
                    postBoundaryMIoUPct: postBIoU.map { ($0 * 100).rounded() / 100 },
                    tier1Passed: report?.tier1.passed ?? false,
                    tier1Reasons: report?.tier1.reasons.joined(separator: "; ") ?? "",
                    tier2Status: report?.tier2.status.rawValue ?? "",
                    coreConf: report.map { ($0.tier2.coreConfidence * 1000).rounded() / 1000 } ?? 0.0,
                    boundaryLow75Pct: report.map { ($0.tier2.boundaryLow75Ratio * 1000).rounded() / 10.0 } ?? 0.0,
                    boundaryMargin35Pct: report.map { ($0.tier2.boundaryMargin35Ratio * 1000).rounded() / 10.0 } ?? 0.0,
                    boundaryEntropy: report.map { ($0.tier2.boundaryNormEntropy * 1000).rounded() / 1000 } ?? 0.0,
                    lrConfusionPct: report.map { ($0.tier2.lrConfusionRatio * 1000).rounded() / 10.0 } ?? 0.0,
                    tier3Passed: report?.tier3?.passed,
                    postIoUL: report?.tier3.map { ($0.postIoUL * 1000).rounded() / 1000 },
                    postIoUR: report?.tier3.map { ($0.postIoUR * 1000).rounded() / 1000 },
                    edgeSupportAvg: report?.tier3.map { ($0.overallEdgeSupport * 1000).rounded() / 1000 },
                    edgeSupportWorst: report?.tier3.map { ($0.worstEdgeSupport * 1000).rounded() / 1000 },
                    worstEdgeName: report?.tier3?.worstEdgeName,
                    tier3Reasons: report?.tier3?.reasons.joined(separator: "; ") ?? ""
                )
                rows.append(row)
                let mStr = row.postMIoUPct.map { String(format: "%.2f%%", $0) } ?? "  -  "
                let bStr = row.postBoundaryMIoUPct.map { String(format: "%.2f%%", $0) } ?? "  -  "
                let grpPad = item.group.padding(toLength: 7, withPad: " ", startingAt: 0)
                let stemPad = String(item.stem.prefix(30)).padding(toLength: 30, withPad: " ", startingAt: 0)
                let decPad = row.decision.padding(toLength: 8, withPad: " ", startingAt: 0)
                let t2Pad = row.tier2Status.padding(toLength: 8, withPad: " ", startingAt: 0)
                print(String(format: "[%02d/%02d] %@ %@ | %@ sam2=%d | v3=%5.1fms tot=%6.1fms | post_mIoU=%@ bIoU=%@ | T1=%d T2=%@ core=%.3f b75=%.1f%% ent=%.3f",
                             idx + 1, targets.count, grpPad, stemPad,
                             decPad, row.usedSAM2Fallback ? 1 : 0, row.v3Ms, row.elapsedMs,
                             mStr, bStr, row.tier1Passed ? 1 : 0, t2Pad,
                             row.coreConf, row.boundaryLow75Pct, row.boundaryEntropy))
                fflush(stdout)
            }
        }

        // Write JSON & CSV
        let jsonURL = URL(fileURLWithPath: "\(rootDir)/tools/v3_regression_report.json")
        let csvURL = URL(fileURLWithPath: "\(rootDir)/tools/v3_regression_report.csv")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let jData = try? enc.encode(rows) {
            try? jData.write(to: jsonURL, options: [.atomic])
        }
        var csvLines = ["stem,group,decision,usedSAM2Fallback,elapsedMs,v3Ms,postMIoUPct,postBgIoUPct,postLIoUPct,postRIoUPct,postBoundaryMIoUPct,tier1Passed,tier1Reasons,tier2Status,coreConf,boundaryLow75Pct,boundaryMargin35Pct,boundaryEntropy,lrConfusionPct,tier3Passed,postIoUL,postIoUR,edgeSupportAvg,edgeSupportWorst,worstEdgeName,tier3Reasons"]
        for r in rows {
            func q(_ s: String) -> String {
                if s.contains(",") || s.contains("\"") {
                    return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return s
            }
            func fmt(_ v: Double?) -> String { v.map { String($0) } ?? "" }
            var cols: [String] = []
            cols.reserveCapacity(26)
            cols.append(q(r.stem))
            cols.append(r.group)
            cols.append(r.decision)
            cols.append(r.usedSAM2Fallback ? "1" : "0")
            cols.append(String(r.elapsedMs))
            cols.append(String(r.v3Ms))
            cols.append(fmt(r.postMIoUPct))
            cols.append(fmt(r.postBgIoUPct))
            cols.append(fmt(r.postLIoUPct))
            cols.append(fmt(r.postRIoUPct))
            cols.append(fmt(r.postBoundaryMIoUPct))
            cols.append(r.tier1Passed ? "1" : "0")
            cols.append(q(r.tier1Reasons))
            cols.append(r.tier2Status)
            cols.append(String(r.coreConf))
            cols.append(String(r.boundaryLow75Pct))
            cols.append(String(r.boundaryMargin35Pct))
            cols.append(String(r.boundaryEntropy))
            cols.append(String(r.lrConfusionPct))
            cols.append(r.tier3Passed.map { $0 ? "1" : "0" } ?? "")
            cols.append(fmt(r.postIoUL))
            cols.append(fmt(r.postIoUR))
            cols.append(fmt(r.edgeSupportAvg))
            cols.append(fmt(r.edgeSupportWorst))
            cols.append(q(r.worstEdgeName ?? ""))
            cols.append(q(r.tier3Reasons))
            csvLines.append(cols.joined(separator: ","))
        }
        try? (csvLines.joined(separator: "\n") + "\n").write(to: csvURL, atomically: true, encoding: .utf8)

        let valRows = rows.filter { $0.group == "val" }
        let passCnt = valRows.filter { $0.decision == "Pass" }.count
        let warnCnt = valRows.filter { $0.decision == "SoftWarn" }.count
        let fbCnt = valRows.filter { $0.decision == "Fallback" }.count
        let avgTotalMs = valRows.map(\.elapsedMs).reduce(0, +) / Double(max(1, valRows.count))
        let avgV3Ms = valRows.map(\.v3Ms).reduce(0, +) / Double(max(1, valRows.count))
        let valMious = valRows.compactMap(\.postMIoUPct)
        let avgMIoU = valMious.reduce(0, +) / Double(max(1, valMious.count))
        let valBios = valRows.compactMap(\.postBoundaryMIoUPct)
        let avgBIoU = valBios.reduce(0, +) / Double(max(1, valBios.count))

        print("=== Phase 2-5 Regression Summary ===")
        print(String(format: "Val (%d): Pass=%d, SoftWarn=%d, Fallback=%d (SAM2 rate=%.1f%%)",
                     valRows.count, passCnt, warnCnt, fbCnt,
                     Double(fbCnt) / Double(max(1, valRows.count)) * 100.0))
        print(String(format: "Latency: avg_v3=%.2f ms, avg_total=%.1f ms | Post-refinement Val mIoU=%.2f%%, Boundary mIoU=%.2f%%",
                     avgV3Ms, avgTotalMs, avgMIoU, avgBIoU))
        print("Report written: \(csvURL.path) & \(jsonURL.path)")
        fflush(stdout)
        return 0
    }

    private static func loadGrayscaleClassMask(url: URL) -> ([UInt8], Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0, cg.bitsPerComponent == 8, cg.bitsPerPixel == 8,
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return nil
        }
        let bpr = cg.bytesPerRow
        let len = CFDataGetLength(data)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let srcOff = y * bpr
            guard srcOff + w <= len else { break }
            let dstOff = y * w
            for x in 0..<w {
                let v = ptr[srcOff + x]
                out[dstOff + x] = v <= 2 ? v : 0
            }
        }
        return (out, w, h)
    }

    private static func evaluateOutputVsGT(
        alphaL: [UInt8], alphaR: [UInt8], outW: Int, outH: Int,
        gtLabels: [UInt8], gtW: Int, gtH: Int,
        evalW: Int, evalH: Int
    ) -> (miou: Double, bgIoU: Double, lIoU: Double, rIoU: Double, boundaryIoU: Double) {
        let n = evalW * evalH
        var pred = [UInt8](repeating: 0, count: n)
        var gt = [UInt8](repeating: 0, count: n)

        for y in 0..<evalH {
            let oy = min(outH - 1, max(0, (y * outH) / evalH))
            let gy = min(gtH - 1, max(0, (y * gtH) / evalH))
            let oRow = oy * outW
            let gRow = gy * gtW
            let dRow = y * evalW
            for x in 0..<evalW {
                let ox = min(outW - 1, max(0, (x * outW) / evalW))
                let gx = min(gtW - 1, max(0, (x * gtW) / evalW))
                let aL = alphaL[oRow + ox]
                let aR = alphaR[oRow + ox]
                if aL >= 128 && aL >= aR {
                    pred[dRow + x] = 1
                } else if aR >= 128 {
                    pred[dRow + x] = 2
                } else {
                    pred[dRow + x] = 0
                }
                gt[dRow + x] = gtLabels[gRow + gx]
            }
        }

        var cIoU = [Double](repeating: 1.0, count: 3)
        for c in 0..<3 {
            let uc = UInt8(c)
            var inter = 0, union = 0
            for i in 0..<n {
                let p = pred[i] == uc
                let t = gt[i] == uc
                if p && t { inter += 1 }
                if p || t { union += 1 }
            }
            cIoU[c] = union > 0 ? Double(inter) / Double(union) : 1.0
        }

        // 5px Boundary mIoU
        var bInter = [0, 0, 0]
        var bUnion = [0, 0, 0]
        for y in 0..<evalH {
            let y0 = max(0, y - 2), y1 = min(evalH - 1, y + 2)
            for x in 0..<evalW {
                let idx = y * evalW + x
                let c0 = gt[idx]
                var isEdge = false
                let x0 = max(0, x - 2), x1 = min(evalW - 1, x + 2)
                outer: for ey in y0...y1 {
                    let r = ey * evalW
                    for ex in x0...x1 where gt[r + ex] != c0 {
                        isEdge = true
                        break outer
                    }
                }
                if !isEdge { continue }
                let pc = Int(pred[idx])
                let tc = Int(c0)
                if pc == tc {
                    bInter[tc] += 1
                    bUnion[tc] += 1
                } else {
                    bUnion[pc] += 1
                    bUnion[tc] += 1
                }
            }
        }
        var bIoUs: [Double] = []
        for c in 0..<3 where bUnion[c] > 0 {
            bIoUs.append(Double(bInter[c]) / Double(bUnion[c]))
        }
        let boundaryIoU = bIoUs.isEmpty ? 1.0 : bIoUs.reduce(0, +) / Double(bIoUs.count)
        let miou = (cIoU[0] + cIoU[1] + cIoU[2]) / 3.0
        return (miou, cIoU[0], cIoU[1], cIoU[2], boundaryIoU)
    }
}
