import AppKit
import Foundation
import StereoStudioCore

/// ワークベンチからのフル解像度マスク仕上げ・ワープ・データセット書き出しを順次直列実行するバックグラウンドキュー
@MainActor
final class StereoWorkbenchSaveQueue: ObservableObject {
    static let shared = StereoWorkbenchSaveQueue()

    struct SaveJob: Sendable {
        let id: UUID
        let itemURL: URL
        let sourceFileName: String
        let mountContext: StereoCardSegmenter.OriginalCardMountContext
        let maskL: [Bool]
        let softProbL: [Float]
        let maskR: [Bool]
        let softProbR: [Float]
        let maskW: Int
        let maskH: Int
        let points: [InteractivePromptPoint]
        let overrideArchParams: StereoCardSegmenter.ArchShapeParams?
        let overrideBoxes: (left: InteractivePromptBox, right: InteractivePromptBox)?
        let windowShiftX: Double
        let isSwapped: Bool
        let exportTrainingData: Bool
        let trainingDatasetDirectoryPath: String
        let rootFolderURL: URL?
        let baseSettings: FolderItemSettings?
    }

    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var lastCompletedFileName: String? = nil
    @Published private(set) var lastErrorMessage: String? = nil

    private var jobQueue: [SaveJob] = []
    private var isWorkerRunning = false

    private init() {}

    func enqueue(job: SaveJob) {
        jobQueue.append(job)
        pendingCount = jobQueue.count
        processNextIfNeeded()
    }

    private func processNextIfNeeded() {
        guard !isWorkerRunning, !jobQueue.isEmpty else { return }
        isWorkerRunning = true
        isProcessing = true
        let job = jobQueue.removeFirst()
        pendingCount = jobQueue.count

        Task.detached(priority: .utility) {
            let result = await Self.executeJob(job)
            await MainActor.run {
                StereoWorkbenchSaveQueue.shared.handleJobCompletion(result)
            }
        }
    }

    private func handleJobCompletion(_ result: Result<String, Error>) {
        isWorkerRunning = false
        switch result {
        case .success(let name):
            lastCompletedFileName = name
            lastErrorMessage = nil
        case .failure(let err):
            lastErrorMessage = err.localizedDescription
        }
        pendingCount = jobQueue.count
        if jobQueue.isEmpty {
            isProcessing = false
        } else {
            processNextIfNeeded()
        }
    }

    nonisolated private static func executeJob(_ job: SaveJob) async -> Result<String, Error> {
        let ctx = job.mountContext
        let wasEdited = !job.points.isEmpty || job.overrideBoxes != nil || job.overrideArchParams != nil

        // 1. フル解像度マスク仕上げ & クロップ
        guard let finalized = StereoCardSegmenter.shared.finalizeInteractiveMasks(
            mountContext: ctx,
            maskL: job.maskL,
            softProbL: job.softProbL,
            maskR: job.maskR,
            softProbR: job.softProbR,
            maskW: job.maskW,
            maskH: job.maskH,
            mode: .cropInner,
            overrideArchParams: job.overrideArchParams,
            overrideBoxes: job.overrideBoxes
        ) else {
            return .failure(NSError(domain: "StereoWorkbenchSaveQueue", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize masks for \(job.sourceFileName)"]))
        }

        // 2. 3クラス教師データ書き出し (オプション)
        if job.exportTrainingData {
            let rootURL = URL(fileURLWithPath: job.trainingDatasetDirectoryPath, isDirectory: true)
            _ = try? StereoCardDatasetExporter.export(
                cardRGB: ctx.cardRGB,
                width: ctx.cardWidth,
                height: ctx.cardHeight,
                fullAlphaL: finalized.fullAlphaL,
                fullAlphaR: finalized.fullAlphaR,
                sourceFileURL: job.itemURL,
                outputRootURL: rootURL,
                points: job.points,
                wasManuallyEdited: wasEdited
            )
        }

        // 3. ViewStereo_Settings.json への反映
        if let root = job.rootFolderURL,
           let relKey = WorkspaceFolderSettingsStore.relativeKey(for: job.itemURL, in: root) {
            var doc = WorkspaceFolderSettingsStore.load(from: root) ?? FolderSettingsDocument(updatedAt: Date(), items: [:])
            var itemSettings = doc.items[relKey] ?? job.baseSettings ?? FolderItemSettings(
                updatedAt: Date(),
                stereoCardModeRaw: "cropInner",
                useCoreMLCardSegmentation: true,
                frameStyleRaw: "rounded",
                autoAlignOnLoad: true,
                autoColorModeRaw: "Off",
                keepOriginalAspectRatio: true,
                usePersonMotionMask: true,
                useAttentionSaliency: true,
                removeUnilateralNoise: true,
                isSwapped: job.isSwapped,
                windowShiftX: job.windowShiftX,
                cardMountPresetRaw: "autoSampleColor",
                cardSizeSpecRaw: "standard",
                cardPrintCutStyleRaw: "autoFromPreset",
                cardCenterGapStyleRaw: "autoFromPreset",
                cardTextModeRaw: "ocrAuto",
                cardBottomCaption: "",
                cardTopCenterText: "",
                cardLeftMarginText: "",
                cardRightMarginText: "",
                cardUseFilenameAsCaption: false,
                isRestorationEnabled: false,
                restorationPrintToneRaw: "original",
                restorationAutoLevel: 0.0,
                restorationLocalContrast: 0.0,
                restorationDeblurStrength: 0.0,
                restorationTextureProtection: 0.7,
                restorationColorizationModeRaw: "off",
                restorationColorStrength: 0.6,
                restorationPaperWarmth: 0.0,
                virtualDepthBasePercent: 3.0,
                depthGamma: 1.0,
                exportLayoutRaw: "sbs",
                exportImageFormatRaw: "png"
            )

            itemSettings.updatedAt = Date()
            itemSettings.windowShiftX = job.windowShiftX
            itemSettings.isSwapped = job.isSwapped
            if let ovBoxes = job.overrideBoxes {
                itemSettings.maskGuideOverride = FolderMaskGuideOverride(
                    boxL: ovBoxes.left,
                    boxR: ovBoxes.right,
                    topArchRatio: job.overrideArchParams?.topRyRatio ?? 0.0,
                    botRoundRatio: job.overrideArchParams?.botRyRatio ?? 0.0
                )
            }
            doc.items[relKey] = itemSettings
            doc.updatedAt = Date()
            _ = try? WorkspaceFolderSettingsStore.save(doc, to: root)
        }

        return .success(job.sourceFileName)
    }
}
