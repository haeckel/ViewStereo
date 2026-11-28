import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Step 2 Phase 2-2: 3クラス教師データ (0=背景/台紙, 1=左写真, 2=右写真) PNG 書き出し

struct StereoCardDatasetExportResult: Sendable {
    let imageURL: URL
    let maskURL: URL
    let previewURL: URL
    let metadataURL: URL
    let backgroundPixels: Int
    let leftPixels: Int
    let rightPixels: Int
}

enum StereoCardDatasetExporterError: LocalizedError {
    case invalidDimensions
    case cgImageCreationFailed
    case pngWriteFailed(URL)

    var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return "Invalid card image or mask dimensions for dataset export."
        case .cgImageCreationFailed:
            return "Failed to construct lossless CGImage for dataset export."
        case .pngWriteFailed(let url):
            return "Failed to write PNG file at \(url.path)."
        }
    }
}

enum StereoCardDatasetExporter {

    private struct ExportMetadata: Codable {
        let sourceFileName: String
        let cardWidth: Int
        let cardHeight: Int
        let exportedAtISO8601: String
        let wasManuallyEdited: Bool
        let classMapping: [String: Int]
        let backgroundPixelCount: Int
        let leftPixelCount: Int
        let rightPixelCount: Int
        let lrAreaRatio: Double
        let prompts: [InteractivePromptPoint]
    }

    static let defaultDatasetDirectoryURL = URL(fileURLWithPath: "/Users/okano/マイドライブ/DEV/ViewStereo/dataset_3class", isDirectory: true)

    static func export(
        cardRGB: [UInt8],
        width: Int,
        height: Int,
        fullAlphaL: [UInt8],
        fullAlphaR: [UInt8],
        sourceFileURL: URL?,
        outputRootURL: URL,
        points: [InteractivePromptPoint],
        wasManuallyEdited: Bool
    ) throws -> StereoCardDatasetExportResult {
        let pixelCount = width * height
        guard width >= 16, height >= 16,
              cardRGB.count >= pixelCount * 3,
              fullAlphaL.count >= pixelCount,
              fullAlphaR.count >= pixelCount else {
            throw StereoCardDatasetExporterError.invalidDimensions
        }

        let fm = FileManager.default
        let imagesDir = outputRootURL.appendingPathComponent("images", isDirectory: true)
        let masksDir = outputRootURL.appendingPathComponent("masks", isDirectory: true)
        let previewsDir = outputRootURL.appendingPathComponent("previews", isDirectory: true)
        let metadataDir = outputRootURL.appendingPathComponent("metadata", isDirectory: true)

        for dir in [outputRootURL, imagesDir, masksDir, previewsDir, metadataDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let rawStem = sourceFileURL?.deletingPathExtension().lastPathComponent ?? ""
        let stem = sanitizeFileStem(rawStem)

        let imageURL = imagesDir.appendingPathComponent("\(stem).png")
        let maskURL = masksDir.appendingPathComponent("\(stem).png")
        let previewURL = previewsDir.appendingPathComponent("\(stem)_vis.png")
        let metadataURL = metadataDir.appendingPathComponent("\(stem).json")

        // 1. 3クラスラベル配列 (0=背景/台紙, 1=左写真, 2=右写真) を厳密な排他的単一バイト値として生成
        var classLabels = [UInt8](repeating: 0, count: pixelCount)
        var bgCount = 0
        var leftCount = 0
        var rightCount = 0

        for i in 0..<pixelCount {
            let aL = fullAlphaL[i]
            let aR = fullAlphaR[i]
            if aL >= 128 && aR >= 128 {
                if aL >= aR {
                    classLabels[i] = 1
                    leftCount += 1
                } else {
                    classLabels[i] = 2
                    rightCount += 1
                }
            } else if aL >= 128 {
                classLabels[i] = 1
                leftCount += 1
            } else if aR >= 128 {
                classLabels[i] = 2
                rightCount += 1
            } else {
                classLabels[i] = 0
                bgCount += 1
            }
        }

        // 2. 元カード RGB PNG 書き出し
        guard let cardCG = makeRGBCGImage(rgb: cardRGB, width: width, height: height) else {
            throw StereoCardDatasetExporterError.cgImageCreationFailed
        }
        try writeLosslessPNG(cardCG, to: imageURL)

        // 3. 3クラスラベル 8-bit 1ch グレースケール PNG 書き出し (値 0 / 1 / 2 厳密保持)
        guard let maskCG = makeGrayscaleLabelCGImage(labels: classLabels, width: width, height: height) else {
            throw StereoCardDatasetExporterError.cgImageCreationFailed
        }
        try writeLosslessPNG(maskCG, to: maskURL)

        // 4. 目視確認用カラー可視化 PNG 書き出し
        var visRGB = cardRGB
        for i in 0..<pixelCount {
            let lbl = classLabels[i]
            let off = i * 3
            let r = Double(visRGB[off])
            let g = Double(visRGB[off + 1])
            let b = Double(visRGB[off + 2])
            if lbl == 1 {
                // 左写真: シアン半透明オーバーレイ
                visRGB[off]     = UInt8(min(255, max(0, Int((r * 0.62 + 30.0 * 0.38).rounded()))))
                visRGB[off + 1] = UInt8(min(255, max(0, Int((g * 0.62 + 210.0 * 0.38).rounded()))))
                visRGB[off + 2] = UInt8(min(255, max(0, Int((b * 0.62 + 255.0 * 0.38).rounded()))))
            } else if lbl == 2 {
                // 右写真: エメラルド半透明オーバーレイ
                visRGB[off]     = UInt8(min(255, max(0, Int((r * 0.62 + 50.0 * 0.38).rounded()))))
                visRGB[off + 1] = UInt8(min(255, max(0, Int((g * 0.62 + 235.0 * 0.38).rounded()))))
                visRGB[off + 2] = UInt8(min(255, max(0, Int((b * 0.62 + 130.0 * 0.38).rounded()))))
            } else {
                // 台紙背景: 少し暗くして境界を見やすくする
                visRGB[off]     = UInt8(Int((r * 0.55).rounded()))
                visRGB[off + 1] = UInt8(Int((g * 0.55).rounded()))
                visRGB[off + 2] = UInt8(Int((b * 0.55).rounded()))
            }
        }
        if let visCG = makeRGBCGImage(rgb: visRGB, width: width, height: height) {
            try? writeLosslessPNG(visCG, to: previewURL)
        }

        // 5. メタデータ JSON 書き出し
        let maxLR = max(1, max(leftCount, rightCount))
        let minLR = min(leftCount, rightCount)
        let lrRatio = Double(minLR) / Double(maxLR)
        let meta = ExportMetadata(
            sourceFileName: sourceFileURL?.lastPathComponent ?? "\(stem).png",
            cardWidth: width,
            cardHeight: height,
            exportedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            wasManuallyEdited: wasManuallyEdited,
            classMapping: ["background": 0, "left_photo": 1, "right_photo": 2],
            backgroundPixelCount: bgCount,
            leftPixelCount: leftCount,
            rightPixelCount: rightCount,
            lrAreaRatio: lrRatio,
            prompts: points
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(meta)
        try jsonData.write(to: metadataURL, options: .atomic)

        return StereoCardDatasetExportResult(
            imageURL: imageURL,
            maskURL: maskURL,
            previewURL: previewURL,
            metadataURL: metadataURL,
            backgroundPixels: bgCount,
            leftPixels: leftCount,
            rightPixels: rightCount
        )
    }

    private static func sanitizeFileStem(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd_HHmmss"
            return "stereocard_\(fmt.string(from: Date()))"
        }
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let parts = trimmed.components(separatedBy: invalid).filter { !$0.isEmpty }
        return parts.isEmpty ? "stereocard" : parts.joined(separator: "_")
    }

    private static func makeRGBCGImage(rgb: [UInt8], width: Int, height: Int) -> CGImage? {
        let count = width * height
        var rgba = [UInt8](repeating: 255, count: count * 4)
        rgb.withUnsafeBufferPointer { sPtr in
            rgba.withUnsafeMutableBufferPointer { dPtr in
                guard let s = sPtr.baseAddress, let d = dPtr.baseAddress else { return }
                for i in 0..<count {
                    let si = i * 3, di = i * 4
                    d[di] = s[si]
                    d[di + 1] = s[si + 1]
                    d[di + 2] = s[si + 2]
                }
            }
        }
        guard let cfData = CFDataCreate(kCFAllocatorDefault, rgba, rgba.count),
              let provider = CGDataProvider(data: cfData),
              let cs = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func makeGrayscaleLabelCGImage(labels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let cfData = CFDataCreate(kCFAllocatorDefault, labels, labels.count),
              let provider = CGDataProvider(data: cfData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func writeLosslessPNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw StereoCardDatasetExporterError.pngWriteFailed(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) {
            throw StereoCardDatasetExporterError.pngWriteFailed(url)
        }
    }
}
