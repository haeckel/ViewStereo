import CryptoKit
import Foundation
import StereoCore

// MARK: - Step 2 Phase 2-3: 3クラス教師データ一括ドラフト書き出し & 検品サマリー生成

enum StereoCardBatchDatasetBuilder {

    struct ReviewRow {
        let filename: String
        let stem: String
        let status: String
        let isPriority: Bool
        let needsReview: Bool
        let maskWarn: Bool
        let lrPct: Double
        let interPct: Double
        let fullLRPct: Double
        let areaLPct: Double
        let areaRPct: Double
        let cardW: Int
        let cardH: Int
        let sha256Prefix: String
        let note: String
    }

    private struct ExistingMetadata: Decodable {
        let cardWidth: Int?
        let cardHeight: Int?
        let wasManuallyEdited: Bool?
        let leftPixelCount: Int?
        let rightPixelCount: Int?
        let lrAreaRatio: Double?
    }

    static let defaultInputDir = "/Users/okano/マイドライブ/DEV/ViewStereo/学習用データ"
    static let defaultPriorityDir = "/Users/okano/マイドライブ/DEV/ViewStereo/再学習用データ"
    static let defaultOutputDir = StereoCardDatasetExporter.defaultDatasetDirectoryURL.path
    private static let supportedExts: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "webp", "bmp"]

    static func runFromCLI(arguments: [String]) -> Int32 {
        var inputPath = defaultInputDir
        var priorityPath = defaultPriorityDir
        var outputPath = defaultOutputDir

        var idx = 0
        while idx < arguments.count {
            let arg = arguments[idx]
            if arg == "--input", idx + 1 < arguments.count {
                inputPath = arguments[idx + 1]
                idx += 2
            } else if arg == "--priority", idx + 1 < arguments.count {
                priorityPath = arguments[idx + 1]
                idx += 2
            } else if arg == "--output", idx + 1 < arguments.count {
                outputPath = arguments[idx + 1]
                idx += 2
            } else {
                idx += 1
            }
        }

        let inputURL = URL(fileURLWithPath: inputPath, isDirectory: true)
        let priorityURL = URL(fileURLWithPath: priorityPath, isDirectory: true)
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)

        let fm = FileManager.default
        guard fm.fileExists(atPath: inputURL.path) else {
            fputs("[Phase2-3] ERROR: Input directory not found: \(inputURL.path)\n", stderr)
            return 1
        }

        do {
            try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
        } catch {
            fputs("[Phase2-3] ERROR: Cannot create output directory \(outputURL.path): \(error)\n", stderr)
            return 1
        }

        let priorityNames = collectImageFilenames(in: priorityURL)
        let inputFiles = collectImageURLs(in: inputURL)
        print("[Phase2-3] Input: \(inputFiles.count) images | Priority set: \(priorityNames.count) names | Output: \(outputURL.path)")
        fflush(stdout)

        var seenFileSHA256: [String: String] = [:]
        var seenImageSig: [UInt64: String] = [:]
        var rows: [ReviewRow] = []
        rows.reserveCapacity(inputFiles.count)

        var exportedCount = 0
        var skippedExistingCount = 0
        var skippedDupCount = 0
        var failedCount = 0

        for (i, fileURL) in inputFiles.enumerated() {
            autoreleasepool {
                let filename = fileURL.lastPathComponent
                let stem = sanitizeFileStem(fileURL.deletingPathExtension().lastPathComponent)
                let isPriority = priorityNames.contains(filename)

                // 1. バイト列 SHA-256 重複チェック
                guard let rawData = try? Data(contentsOf: fileURL) else {
                    failedCount += 1
                    rows.append(ReviewRow(
                        filename: filename, stem: stem, status: "read_failed",
                        isPriority: isPriority, needsReview: true, maskWarn: true,
                        lrPct: 0, interPct: 0, fullLRPct: 0, areaLPct: 0, areaRPct: 0,
                        cardW: 0, cardH: 0, sha256Prefix: "", note: "Failed to read file bytes"
                    ))
                    return
                }
                let digest = SHA256.hash(data: rawData)
                let shaHex = digest.map { String(format: "%02x", $0) }.joined()
                let shaPrefix = String(shaHex.prefix(12))

                if let firstOwner = seenFileSHA256[shaHex] {
                    skippedDupCount += 1
                    rows.append(ReviewRow(
                        filename: filename, stem: stem, status: "skipped_duplicate_sha256",
                        isPriority: isPriority, needsReview: false, maskWarn: false,
                        lrPct: 0, interPct: 0, fullLRPct: 0, areaLPct: 0, areaRPct: 0,
                        cardW: 0, cardH: 0, sha256Prefix: shaPrefix,
                        note: "Duplicate bytes of \(firstOwner)"
                    ))
                    return
                }
                seenFileSHA256[shaHex] = filename

                // 2. 画像デコード & 画素シグネチャ重複チェック
                guard let (rgb, w, h) = ViewStereoViewModel.loadNormalizedRGB(url: fileURL), w >= 64, h >= 32 else {
                    failedCount += 1
                    rows.append(ReviewRow(
                        filename: filename, stem: stem, status: "decode_failed",
                        isPriority: isPriority, needsReview: true, maskWarn: true,
                        lrPct: 0, interPct: 0, fullLRPct: 0, areaLPct: 0, areaRPct: 0,
                        cardW: 0, cardH: 0, sha256Prefix: shaPrefix, note: "Failed to decode RGB"
                    ))
                    return
                }

                let imgSig = StereoCardSegmenter.computeCardSignature(rgb: rgb, width: w, height: h)
                if let firstOwner = seenImageSig[imgSig] {
                    skippedDupCount += 1
                    rows.append(ReviewRow(
                        filename: filename, stem: stem, status: "skipped_duplicate_pixel",
                        isPriority: isPriority, needsReview: false, maskWarn: false,
                        lrPct: 0, interPct: 0, fullLRPct: 0, areaLPct: 0, areaRPct: 0,
                        cardW: w, cardH: h, sha256Prefix: shaPrefix,
                        note: "Duplicate pixels of \(firstOwner)"
                    ))
                    return
                }
                seenImageSig[imgSig] = filename

                // 3. 既存ファイル（手動保存済み等）の上書き防止スキップ
                let existingMaskURL = outputURL.appendingPathComponent("masks/\(stem).png")
                if fm.fileExists(atPath: existingMaskURL.path) {
                    skippedExistingCount += 1
                    let existingMetaURL = outputURL.appendingPathComponent("metadata/\(stem).json")
                    var fullLR = 0.0
                    var areaLPct = 0.0
                    var areaRPct = 0.0
                    var cardW = w
                    var cardH = h
                    var note = "Skipped (already exists in dataset_3class)"
                    if let mData = try? Data(contentsOf: existingMetaURL),
                       let meta = try? JSONDecoder().decode(ExistingMetadata.self, from: mData) {
                        cardW = meta.cardWidth ?? w
                        cardH = meta.cardHeight ?? h
                        let totalPx = max(1, cardW * cardH)
                        areaLPct = Double(meta.leftPixelCount ?? 0) / Double(totalPx) * 100.0
                        areaRPct = Double(meta.rightPixelCount ?? 0) / Double(totalPx) * 100.0
                        fullLR = (meta.lrAreaRatio ?? 0.0) * 100.0
                        if meta.wasManuallyEdited == true {
                            note = "Skipped (existing manual edit preserved)"
                        }
                    }
                    rows.append(ReviewRow(
                        filename: filename, stem: stem, status: "skipped_existing",
                        isPriority: isPriority, needsReview: false, maskWarn: false,
                        lrPct: fullLR, interPct: fullLR, fullLRPct: fullLR,
                        areaLPct: areaLPct, areaRPct: areaRPct,
                        cardW: cardW, cardH: cardH, sha256Prefix: shaPrefix, note: note
                    ))
                    return
                }

                // 4. Step 1 自動抽出実行（Core ML + SAM 2.1 -> フォールバックでヒューリスティック）
                var usedHeuristic = false
                var cropRes = StereoCardSegmenter.shared.extractPhotoPair(from: rgb, width: w, height: h, mode: .keepArchBlack)
                if cropRes == nil {
                    usedHeuristic = true
                    cropRes = StereoCardSegmenter.shared.extractPhotoPairHeuristic(from: rgb, width: w, height: h, mode: .keepArchBlack)
                }

                guard cropRes != nil,
                      let mountCtx = StereoCardSegmenter.shared.currentMountContext,
                      let fullAlphas = StereoCardSegmenter.shared.currentFullCardAlphas else {
                    failedCount += 1
                    rows.append(ReviewRow(
                        filename: filename, stem: stem, status: "extract_failed",
                        isPriority: isPriority, needsReview: true, maskWarn: true,
                        lrPct: 0, interPct: 0, fullLRPct: 0, areaLPct: 0, areaRPct: 0,
                        cardW: w, cardH: h, sha256Prefix: shaPrefix,
                        note: "Card extraction or mount context failed"
                    ))
                    return
                }

                // 5. Step 1 指標（unmaskedAlphaL/R の交差率・左右比 ＋ 元カード空間の面積比）を算出
                let unmaskedMetrics = computeAlphaPairMetrics(
                    alphaL: mountCtx.unmaskedAlphaL,
                    alphaR: mountCtx.unmaskedAlphaR,
                    count: mountCtx.unmaskedWidth * mountCtx.unmaskedHeight
                )
                let maskWarn = (unmaskedMetrics.lrPct < 85.0 || unmaskedMetrics.interPct < 80.0)

                let fullTotalPx = max(1, mountCtx.cardWidth * mountCtx.cardHeight)
                let fullCntL = fullAlphas.left.reduce(0) { $0 + ($1 >= 128 ? 1 : 0) }
                let fullCntR = fullAlphas.right.reduce(0) { $0 + ($1 >= 128 ? 1 : 0) }
                let areaLPct = Double(fullCntL) / Double(fullTotalPx) * 100.0
                let areaRPct = Double(fullCntR) / Double(fullTotalPx) * 100.0
                let fullLRPct = Double(min(fullCntL, fullCntR)) / Double(max(1, max(fullCntL, fullCntR))) * 100.0

                var notes: [String] = []
                if usedHeuristic { notes.append("heuristic_fallback") }
                if maskWarn { notes.append("mask_warn") }
                if fullLRPct < 88.0 { notes.append(String(format: "low_full_lr(%.1f%%)", fullLRPct)) }
                if areaLPct < 12.0 || areaLPct > 48.0 { notes.append(String(format: "areaL_anomaly(%.1f%%)", areaLPct)) }
                if areaRPct < 12.0 || areaRPct > 48.0 { notes.append(String(format: "areaR_anomaly(%.1f%%)", areaRPct)) }

                let needsReview = usedHeuristic || maskWarn || fullLRPct < 88.0
                    || areaLPct < 12.0 || areaRPct < 12.0 || areaLPct > 48.0 || areaRPct > 48.0

                // 6. 3クラス教師データ (images/, masks/, previews/, metadata/) へ書き出し
                do {
                    _ = try StereoCardDatasetExporter.export(
                        cardRGB: mountCtx.cardRGB,
                        width: mountCtx.cardWidth,
                        height: mountCtx.cardHeight,
                        fullAlphaL: fullAlphas.left,
                        fullAlphaR: fullAlphas.right,
                        sourceFileURL: fileURL,
                        outputRootURL: outputURL,
                        points: [],
                        wasManuallyEdited: false
                    )
                    exportedCount += 1
                    rows.append(ReviewRow(
                        filename: filename,
                        stem: stem,
                        status: "exported",
                        isPriority: isPriority,
                        needsReview: needsReview,
                        maskWarn: maskWarn,
                        lrPct: unmaskedMetrics.lrPct,
                        interPct: unmaskedMetrics.interPct,
                        fullLRPct: fullLRPct,
                        areaLPct: areaLPct,
                        areaRPct: areaRPct,
                        cardW: mountCtx.cardWidth,
                        cardH: mountCtx.cardHeight,
                        sha256Prefix: shaPrefix,
                        note: notes.isEmpty ? "ok" : notes.joined(separator: "; ")
                    ))
                } catch {
                    failedCount += 1
                    rows.append(ReviewRow(
                        filename: filename,
                        stem: stem,
                        status: "export_failed",
                        isPriority: isPriority,
                        needsReview: true,
                        maskWarn: true,
                        lrPct: unmaskedMetrics.lrPct,
                        interPct: unmaskedMetrics.interPct,
                        fullLRPct: fullLRPct,
                        areaLPct: areaLPct,
                        areaRPct: areaRPct,
                        cardW: mountCtx.cardWidth,
                        cardH: mountCtx.cardHeight,
                        sha256Prefix: shaPrefix,
                        note: "Export error: \(error.localizedDescription)"
                    ))
                }
            }

            if (i + 1) % 20 == 0 || (i + 1) == inputFiles.count {
                print(String(format: "[Phase2-3] Progress %d/%d | exported=%d skipped_existing=%d skipped_dup=%d failed=%d",
                             i + 1, inputFiles.count, exportedCount, skippedExistingCount, skippedDupCount, failedCount))
                fflush(stdout)
            }
        }

        // 7. review_summary.csv のソート＆書き出し
        let sortedRows = rows.sorted { a, b in
            if a.needsReview != b.needsReview { return a.needsReview && !b.needsReview }
            if a.isPriority != b.isPriority { return a.isPriority && !b.isPriority }
            if abs(a.lrPct - b.lrPct) > 0.05 { return a.lrPct < b.lrPct }
            return a.filename < b.filename
        }

        let csvURL = outputURL.appendingPathComponent("review_summary.csv")
        var csvLines: [String] = [
            "filename,stem,status,is_priority,needs_review,mask_warn,lr_pct,inter_pct,full_lr_pct,area_l_pct,area_r_pct,card_w,card_h,sha256_prefix,note"
        ]
        for r in sortedRows {
            let line = [
                csvEscape(r.filename),
                csvEscape(r.stem),
                csvEscape(r.status),
                r.isPriority ? "true" : "false",
                r.needsReview ? "true" : "false",
                r.maskWarn ? "true" : "false",
                String(format: "%.2f", r.lrPct),
                String(format: "%.2f", r.interPct),
                String(format: "%.2f", r.fullLRPct),
                String(format: "%.2f", r.areaLPct),
                String(format: "%.2f", r.areaRPct),
                String(r.cardW),
                String(r.cardH),
                csvEscape(r.sha256Prefix),
                csvEscape(r.note)
            ].joined(separator: ",")
            csvLines.append(line)
        }

        do {
            try (csvLines.joined(separator: "\n") + "\n").write(to: csvURL, atomically: true, encoding: .utf8)
        } catch {
            fputs("[Phase2-3] ERROR: Failed to write review_summary.csv: \(error)\n", stderr)
            return 1
        }

        let needsReviewCount = sortedRows.filter { $0.needsReview }.count
        let priorityCount = sortedRows.filter { $0.isPriority }.count
        print("[Phase2-3] DONE total=\(inputFiles.count) exported=\(exportedCount) skipped_existing=\(skippedExistingCount) skipped_dup=\(skippedDupCount) failed=\(failedCount) priority=\(priorityCount) needs_review=\(needsReviewCount)")
        print("[Phase2-3] CSV written: \(csvURL.path)")
        fflush(stdout)
        return failedCount == 0 ? 0 : 2
    }

    private static func collectImageFilenames(in dirURL: URL) -> Set<String> {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var names = Set<String>()
        for url in items {
            let ext = url.pathExtension.lowercased()
            if supportedExts.contains(ext) {
                names.insert(url.lastPathComponent)
            }
        }
        return names
    }

    private static func collectImageURLs(in dirURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return items.filter { url in
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            return isFile && supportedExts.contains(url.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func computeAlphaPairMetrics(alphaL: [UInt8], alphaR: [UInt8], count: Int) -> (lrPct: Double, interPct: Double) {
        guard count > 0, alphaL.count >= count, alphaR.count >= count else {
            return (0.0, 0.0)
        }
        var areaL = 0
        var areaR = 0
        var areaInter = 0
        for i in 0..<count {
            let aL = alphaL[i]
            let aR = alphaR[i]
            if aL >= 128 { areaL += 1 }
            if aR >= 128 { areaR += 1 }
            if aL >= 128 && aR >= 128 { areaInter += 1 }
        }
        let maxArea = max(1, max(areaL, areaR))
        let minArea = min(areaL, areaR)
        return (
            lrPct: Double(minArea) / Double(maxArea) * 100.0,
            interPct: Double(areaInter) / Double(maxArea) * 100.0
        )
    }

    private static func sanitizeFileStem(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "stereocard" }
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let parts = trimmed.components(separatedBy: invalid).filter { !$0.isEmpty }
        return parts.isEmpty ? "stereocard" : parts.joined(separator: "_")
    }

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
