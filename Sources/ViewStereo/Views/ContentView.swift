import StereoCore
import StereoStudioCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var vm: ViewStereoViewModel
    @ObservedObject var settings = ViewStereoSettings.shared
    @ObservedObject private var updateManager = StudioUpdateManager.shared
    @State private var isDropTargeted = false
    @State private var isShowingUpdateSheet = false

    private var inspectorWidth: CGFloat {
        settings.useLargeTextMode ? 450 : 400
    }

    var body: some View {
        HStack(spacing: 0) {
            // メインプレビュー領域（Drop 対応）
            mainCanvasView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .background(Color(red: 0.06, green: 0.06, blue: 0.07))
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers: providers)
                }

            Divider()

            // 右サイドバー（Anti-Jitter 4層固定幅インスペクター）
            inspectorPanel
                .frame(width: inspectorWidth, alignment: .topLeading)
                .layoutPriority(2)
                .clipped()
                .background(Color(red: 0.11, green: 0.11, blue: 0.13))
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 1024, minHeight: 680)
        .sheet(isPresented: $isShowingUpdateSheet) {
            StudioUpdateNotificationSheet(manager: updateManager)
        }
        .onAppear {
            if updateManager.updateAvailable {
                isShowingUpdateSheet = true
            }
            updateManager.checkForUpdates()
        }
        .onChange(of: updateManager.updateAvailable) { _, newValue in
            if newValue {
                isShowingUpdateSheet = true
            }
        }
        .alert(String(localized: "Update Check Error"), isPresented: Binding(
            get: { updateManager.errorMessage != nil },
            set: { if !$0 { updateManager.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error = updateManager.errorMessage {
                Text(error)
            }
        }
        .alert(String(localized: "ViewStereo is Up to Date"), isPresented: Binding(
            get: { updateManager.isUpToDateAlert },
            set: { updateManager.isUpToDateAlert = $0 }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Version \(updateManager.currentVersion)")
        }
    }

    // MARK: - Main Canvas & Landing View

    @ViewBuilder
    private var mainCanvasView: some View {
        ZStack {
            VStack(spacing: 0) {
                // 上部ツールストリップ（常時表示：立体視方式切替 + 左右スワップ + ステータス）
                topToolbarStrip

                // 画像キャンバス または ランディング案内
                ZStack(alignment: .topTrailing) {
                    if let img = vm.displayImage {
                        GeometryReader { _ in
                            Image(nsImage: img)
                                .interpolation(.high)
                                .antialiased(true)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(12)
                        }

                        // スワップ時のフローティングインジケータ（キャンバス右上）
                        if vm.isSwapped && vm.displayMode != .twoD {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.left.and.right.square.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text(LocalizedStringKey("Swapped (R⇄L)"))
                                    .appSystemFont(size: 11, weight: .bold)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color.brightAmber.opacity(0.92))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 2)
                            .padding(20)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    } else {
                        landingView
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: vm.isSwapped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.brightBlue, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.darkBlue.opacity(0.15))
                    .padding(16)
            }

            if vm.isProcessing {
                ZStack {
                    Color.black.opacity(0.45)
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.1)
                        Text(vm.statusMessage.isEmpty ? "Processing..." : vm.statusMessage)
                            .appSystemFont(size: 12, weight: .semibold, design: .monospaced)
                            .foregroundColor(.white)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }

            if vm.isBatchRunning || vm.batchCompletionSummary != nil {
                VStack {
                    Spacer()
                    batchCanvasOverlay
                        .padding(.horizontal, 24)
                        .padding(.bottom, 22)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if vm.isRestoringPreview && !vm.isProcessing {
                VStack {
                    Spacer()
                    restorationProgressOverlay
                        .padding(.horizontal, 24)
                        .padding(.bottom, 22)
                }
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.isBatchRunning)
        .animation(.easeInOut(duration: 0.2), value: vm.batchCompletionSummary != nil)
        .animation(.easeInOut(duration: 0.18), value: vm.isRestoringPreview)
    }

    private var topToolbarStrip: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(StereoDisplayMode.allCases) { mode in
                        displayModeButton(for: mode)
                    }

                    Divider()
                        .frame(height: 16)
                        .padding(.horizontal, 4)

                    topSwapButton

                    topBeforeAfterButton
                }
            }

            if !vm.statusMessage.isEmpty {
                Text(vm.statusMessage)
                    .appSystemFont(size: 11, weight: .medium, design: .monospaced)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.35))
    }

    private var topSwapButton: some View {
        Button {
            vm.swapLeftRight()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: vm.isSwapped ? "arrow.left.and.right.square.fill" : "arrow.left.and.right.square")
                    .font(.system(size: 11, weight: .semibold))
                Text(vm.isSwapped ? LocalizedStringKey("Swapped (R⇄L)") : LocalizedStringKey("Swap L/R"))
                    .appSystemFont(size: 11, weight: .semibold)
            }
            .foregroundColor(vm.isSwapped ? .white : .primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(vm.isSwapped ? Color.brightAmber.opacity(0.85) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(vm.isSwapped ? Color.brightAmber : Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: vm.isSwapped ? Color.brightAmber.opacity(0.4) : .clear, radius: 4, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(vm.displayMode == .twoD)
        .opacity((vm.displayMode == .twoD) ? 0.45 : 1.0)
        .customTooltip("左右眼を入れ替え (X)")
    }

    private var topBeforeAfterButton: some View {
        let canCompare = vm.hasLoadedImages && vm.hasActiveVintageRestoration
        let isBefore = vm.isShowingBeforeRestoration && canCompare
        return Button {
            vm.isShowingBeforeRestoration.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isBefore ? "eye.slash" : "circle.lefthalf.filled")
                    .font(.system(size: 11, weight: .semibold))
                Text(isBefore ? LocalizedStringKey("Before (Original)") : LocalizedStringKey("Compare Before"))
                    .appSystemFont(size: 11, weight: .semibold)
            }
            .foregroundColor(isBefore ? .white : .primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isBefore ? Color.brightPink.opacity(0.85) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isBefore ? Color.brightPink : Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canCompare)
        .opacity(canCompare ? 1.0 : 0.40)
        .customTooltip("退色・階調復元の適用前/適用後を比較")
    }

    @ViewBuilder
    private var restorationProgressOverlay: some View {
        let pct = min(100, max(0, Int((vm.restorationProgress * 100.0).rounded())))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(vm.restorationProgressMessage.isEmpty ? String(localized: "Restoring preview...") : vm.restorationProgressMessage)
                    .appSystemFont(size: 12, weight: .semibold)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                Text("\(pct)%")
                    .appSystemFont(size: 12, weight: .bold, design: .monospaced)
                    .foregroundColor(.brightPink)
            }

            ProgressView(value: min(1.0, max(0.0, vm.restorationProgress)))
                .tint(.brightPink)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 440)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.brightPink.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 6)
    }

    @ViewBuilder
    private var batchCanvasOverlay: some View {
        if vm.isBatchRunning {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Batch Processing...")
                        .appSystemFont(size: 12.5, weight: .semibold)
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(vm.batchCompletedCount) / \(vm.batchTotalCount)")
                        .appSystemFont(size: 12, weight: .bold, design: .monospaced)
                        .foregroundColor(.brightTeal)
                    Button {
                        vm.cancelBatchProcessing()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .customTooltip("バッチ処理を中止")
                }

                ProgressView(value: vm.batchProgress)
                    .tint(.brightTeal)

                if !vm.batchCurrentFile.isEmpty {
                    Text(vm.batchCurrentFile)
                        .appSystemFont(size: 11, design: .monospaced)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 460)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.brightTeal.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 6)
        } else if let summary = vm.batchCompletionSummary {
            let isCleanSuccess = !summary.wasCancelled && summary.failed == 0
            let accentColor: Color = isCleanSuccess ? .brightTeal : .brightAmber

            HStack(spacing: 12) {
                Image(systemName: isCleanSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(
                        summary.wasCancelled ? "Batch Cancelled" : (summary.failed > 0 ? "Batch Finished with Errors" : "Batch Complete")
                    ))
                    .appSystemFont(size: 12.5, weight: .semibold)
                    .foregroundColor(.white)

                    Text(batchSummaryDetailText(summary))
                        .appSystemFont(size: 11, design: .monospaced)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button {
                    vm.openBatchOutputFolderInFinder()
                } label: {
                    Label("Open Output", systemImage: "folder")
                        .appSystemFont(size: 11.5, weight: .semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(isCleanSuccess ? .palestineGreen : .darkAmber)

                Button {
                    vm.dismissBatchCompletionNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 520)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(accentColor.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 6)
        }
    }

    private func batchSummaryDetailText(_ summary: BatchCompletionSummary) -> String {
        let dirName = summary.outputDirectory.lastPathComponent
        if summary.wasCancelled {
            return String(format: String(localized: "%d / %d completed → %@/"), summary.succeeded, summary.total, dirName)
        } else if summary.failed > 0 {
            return String(format: String(localized: "%d succeeded, %d failed → %@/"), summary.succeeded, summary.failed, dirName)
        } else {
            return String(format: String(localized: "%d succeeded → %@/"), summary.succeeded, dirName)
        }
    }

    private var appIconImage: NSImage? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "WelcomeIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        #endif
        if let img = NSImage(named: "WelcomeIcon") {
            return img
        }
        if let img = NSImage(named: "AppIcon") {
            return img
        }
        return NSApp.applicationIconImage
    }

    private var landingView: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.brightAmber.opacity(0.20), Color.clear],
                            center: .center,
                            startRadius: 20,
                            endRadius: 84
                        )
                    )
                    .frame(width: 150, height: 150)

                if let icon = appIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 104, height: 104)
                        .shadow(color: Color.black.opacity(0.50), radius: 18, x: 0, y: 8)
                } else {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(
                            LinearGradient(
                                colors: [.darkAmber, .brightAmber],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 84, height: 84)
                        .shadow(color: Color.brightAmber.opacity(0.45), radius: 14)
                        .overlay(
                            Text(verbatim: "V")
                                .font(.system(size: 42, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        )
                }
            }

            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    Text(verbatim: "View")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(verbatim: "Stereo")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.brightAmber)
                }
                Text("19th Century Stereoview Restoration & Intelligent Stereo Window Studio")
                    .appSystemFont(size: 12, weight: .medium)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    vm.openImagesPanel()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.brightAmber)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("1. Open Stereoview Card, L/R Pair, or Folder")
                                .appSystemFont(size: 13, weight: .semibold)
                                .foregroundColor(.white)
                            Text("Drop vintage stereo cards or modern stereo photos for auto-segmentation & alignment")
                                .appSystemFont(size: 11)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .frame(width: 390)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.brightBlue)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("2. AI Card Segmentation & 7-DoF Alignment")
                            .appSystemFont(size: 13, weight: .semibold)
                            .foregroundColor(.white)
                        Text("Core ML (StereoCardSeg + MobileSAM) + LAPACK dposv_ & Metal Lanczos-3")
                            .appSystemFont(size: 11)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .frame(width: 390)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 12) {
                    Image(systemName: "visionpro")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.palestineGreen)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("3. Intelligent Stereo Window & Spatial Photo")
                            .appSystemFont(size: 13, weight: .semibold)
                            .foregroundColor(.white)
                        Text("Optimized zero-parallax window with Vision Pro Spatial Photo & VR export")
                            .appSystemFont(size: 11)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .frame(width: 390)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(32)
    }

    // MARK: - Anti-Jitter 1-Pane Utility Inspector

    @State private var isWindowExpanded: Bool = false
    @State private var isRecipeExpanded: Bool = false

    private var inspectorPanel: some View {
        let sidePadding: CGFloat = 16
        let contentWidth = inspectorWidth - (sidePadding * 2)

        return VStack(alignment: .leading, spacing: 0) {
            // 上端固定ヘッダー：ソース表示 ＋ クイック操作
            inspectorHeader
                .padding(.horizontal, sidePadding)
                .padding(.vertical, 12)
                .frame(width: inspectorWidth, alignment: .leading)
                .background(Color.black.opacity(0.22))

            Divider().opacity(0.35)

            // 中央スクロール領域（ステータス / ウィンドウ微調整 / カード台紙設定 / 基本設定折りたたみ / バッチ折りたたみ）
            ScrollView([.vertical], showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    statusSummarySection
                    stereoWindowSection
                    stereoviewCardMountSection
                    vintageRestorationSection
                    basicRecipeDisclosure
                    batchProcessingDisclosure
                }
                .frame(width: contentWidth, alignment: .topLeading)
                .padding(.horizontal, sidePadding)
                .padding(.vertical, 14)
                .background(ScrollViewAntiJitterConfigurator())
            }
            .scrollIndicators(.never)
            .frame(width: inspectorWidth, alignment: .topLeading)

            Divider().opacity(0.35)

            // 下端固定フッター：常時アクセス可能な書き出しエリア
            exportFooter
                .padding(.horizontal, sidePadding)
                .padding(.vertical, 12)
                .frame(width: inspectorWidth, alignment: .leading)
                .background(Color.black.opacity(0.28))
        }
        .frame(width: inspectorWidth, alignment: .topLeading)
        .clipped()
    }

    // MARK: - Inspector Header

    private var inspectorHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if vm.hasLoadedImages {
                    Text(vm.currentSourceName)
                        .appSystemFont(size: 12, weight: .semibold)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("ViewStereo Utility")
                        .appSystemFont(size: 12, weight: .semibold)
                        .foregroundColor(.white)
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusBadgeColor)
                        .frame(width: 6, height: 6)
                    Text(LocalizedStringKey(statusBadgeText))
                        .appSystemFont(size: 10.5, weight: .medium)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                vm.openImagesPanel()
            } label: {
                Label("Open", systemImage: "folder")
                    .appSystemFont(size: 11.5, weight: .semibold)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .customTooltip("画像を開く (⌘O)")
        }
    }

    private var statusBadgeColor: Color {
        if vm.isBatchRunning || vm.isProcessing { return .brightBlue }
        if !vm.hasLoadedImages { return .secondary }
        if !vm.isAligned { return .brightAmber }
        if vm.hasWindowViolationRisk || vm.maxDisparityPercent > 8.0 { return .brightAmber }
        return .brightTeal
    }

    private var statusBadgeText: String {
        if vm.isBatchRunning { return "Batch Running" }
        if vm.isProcessing { return "Processing..." }
        if !vm.hasLoadedImages { return "Ready to Drop" }
        if !vm.isAligned { return "Unaligned" }
        if vm.hasWindowViolationRisk || vm.maxDisparityPercent > 8.0 { return "Check Window" }
        return "Auto-Restored"
    }

    // MARK: - Section 1: Restoration Status

    private var statusSummarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader(title: "RESTORATION STATUS", color: .brightBlue)
                Spacer()
                HStack(spacing: 6) {
                    Button {
                        vm.runAutoAlignment()
                    } label: {
                        Label("Re-Align", systemImage: "sparkles")
                            .appSystemFont(size: 10.5, weight: .semibold)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.brightBlue)
                    .disabled(!vm.hasLoadedImages || vm.isProcessing)
                    .customTooltip("基本設定で再調整 (⇧⌘A)")

                    Button {
                        vm.resetAlignment()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10.5))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!vm.isAligned || vm.isProcessing)
                    .customTooltip("位置合わせをリセット")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                telemetryRow(
                    label: "Output Size",
                    value: vm.isAligned ? "\(vm.croppedWidth) × \(vm.croppedHeight)" : (vm.imageWidth > 0 ? "\(vm.imageWidth) × \(vm.imageHeight)" : "—")
                )
                telemetryRow(
                    label: "Vertical RMSE",
                    value: vm.isAligned ? String(format: "%.3f px", vm.verticalRMSE) : "—",
                    highlight: vm.isAligned ? (vm.verticalRMSE < 0.1 ? .brightTeal : .brightAmber) : .secondary
                )
                telemetryRow(
                    label: "Disparity Range",
                    value: vm.isAligned ? String(format: "%.2f %%", vm.maxDisparityPercent) : "—",
                    highlight: vm.isAligned ? (vm.maxDisparityPercent > 8.0 ? .palestineRed : (vm.maxDisparityPercent > 4.0 ? .brightAmber : .brightTeal)) : .secondary
                )
                telemetryRow(
                    label: "Window",
                    value: vm.isAligned ? String(localized: vm.hasWindowViolationRisk ? "Detected (Edge)" : "Clear") : "—",
                    highlight: vm.isAligned ? (vm.hasWindowViolationRisk ? .brightAmber : .brightTeal) : .secondary
                )
            }
            .padding(10)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Section 3: Stereo Window Fine-Tuning (Collapsible)

    private var stereoWindowSection: some View {
        DisclosureGroup(isExpanded: $isWindowExpanded) {
            // 3点セット: スライダー + ResetButton + NumericInput
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Horizontal Shift (px)")
                        .appSystemFont(size: 12, weight: .semibold)
                    Spacer()
                    ResetButton(isModified: abs(vm.windowShiftX - vm.autoOptimalShiftX) > 0.05) {
                        vm.windowShiftX = vm.autoOptimalShiftX
                        vm.applyManualWindowShift()
                    }
                    .disabled(!vm.isAligned || vm.isProcessing)
                    NumericInput(
                        value: $vm.windowShiftX,
                        range: -300.0...300.0,
                        format: "%.1f"
                    ) {
                        vm.applyManualWindowShift()
                    }
                    .id("\(vm.currentSourceName)-\(vm.isAligned)")
                    .disabled(!vm.isAligned || vm.isProcessing)
                }

                Slider(value: $vm.windowShiftX, in: -200.0...200.0, onEditingChanged: { editing in
                    if !editing {
                        vm.applyManualWindowShift()
                    }
                })
                .tint(.brightAmber)
                .disabled(!vm.isAligned || vm.isProcessing)
                .onChange(of: vm.windowShiftX) { _, _ in
                    vm.updateRealtimeDragPreview()
                }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                sectionHeader(title: "STEREO WINDOW", color: .brightAmber)
                Spacer()
                if vm.isAligned {
                    Text(String(format: String(localized: "Auto: %.1f px"), vm.autoOptimalShiftX))
                        .appSystemFont(size: 10.5, weight: .medium, design: .monospaced)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.brightAmber.opacity(vm.isAligned ? 0.28 : 0.10), lineWidth: 1)
        )
        .opacity(vm.isAligned ? 1.0 : 0.55)
    }

    // MARK: - Section 3.5: Stereoview Card Mount (Collapsible)

    private var stereoviewCardMountSection: some View {
        let isCardActive = (vm.displayMode == .stereoviewCard || vm.exportLayout == .stereoviewCard)
        return DisclosureGroup(isExpanded: $vm.isCardMountSectionExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Mount Style")
                            .appSystemFont(size: 11, weight: .semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        if vm.hasOriginalCardMount {
                            Text("Source Card Detected")
                                .appSystemFont(size: 10, weight: .semibold)
                                .foregroundColor(.brightAmber)
                        }
                    }
                    Picker("Mount Style", selection: $vm.cardMountPreset) {
                        ForEach(StereoCardMountPreset.allCases) { preset in
                            Text(LocalizedStringKey(preset.rawValue)).tag(preset)
                        }
                    }
                    .labelsHidden()
                }

                if vm.cardMountPreset != .originalRemount || !vm.hasOriginalCardMount {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Card Size (7-inch Standard)")
                            .appSystemFont(size: 11, weight: .semibold)
                            .foregroundColor(.secondary)
                        Picker("Card Size", selection: $vm.cardSizeSpec) {
                            ForEach(StereoCardSizeSpec.allCases) { spec in
                                Text(LocalizedStringKey(spec.rawValue)).tag(spec)
                            }
                        }
                        .labelsHidden()
                    }

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Print Cut")
                                .appSystemFont(size: 11, weight: .semibold)
                                .foregroundColor(.secondary)
                            Picker("Print Cut", selection: $vm.cardPrintCutStyle) {
                                ForEach(StereoCardPrintCutStyle.allCases) { cut in
                                    Text(LocalizedStringKey(cut.rawValue)).tag(cut)
                                }
                            }
                            .labelsHidden()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Center Division")
                                .appSystemFont(size: 11, weight: .semibold)
                                .foregroundColor(.secondary)
                            Picker("Center Division", selection: $vm.cardCenterGapStyle) {
                                ForEach(StereoCardCenterGapStyle.allCases) { gap in
                                    Text(LocalizedStringKey(gap.rawValue)).tag(gap)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }

                Divider().opacity(0.3)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Mount Typography & Text")
                            .appSystemFont(size: 11, weight: .semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        if vm.isRunningCardOCR {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("OCR Reading...")
                                    .appSystemFont(size: 10, weight: .medium)
                                    .foregroundColor(.brightAmber)
                            }
                        }
                    }

                    Picker("Text Mode", selection: $vm.cardTextMode) {
                        ForEach(StereoCardTextMode.allCases) { tm in
                            Text(LocalizedStringKey(tm.rawValue)).tag(tm)
                        }
                    }
                    .labelsHidden()

                    if vm.cardTextMode == .ocrAuto || vm.cardTextMode == .manualTypeset {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                TextField(LocalizedStringKey("Top No."), text: $vm.cardTopCenterText)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .frame(width: 68)
                                TextField(LocalizedStringKey("Bottom Title / Caption"), text: $vm.cardBottomCaption)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                            }

                            Toggle("Use Filename When Title Is Empty", isOn: $vm.cardUseFilenameAsCaption)
                                .appSystemFont(size: 11)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .tint(.brightAmber)

                            HStack(spacing: 6) {
                                TextField(LocalizedStringKey("Left Margin (Upward)"), text: $vm.cardLeftMarginText)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                TextField(LocalizedStringKey("Right Margin (Downward)"), text: $vm.cardRightMarginText)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                sectionHeader(title: "STEREOVIEW CARD MOUNT", color: .brightAmber)
                Spacer()
                if !vm.isCardMountSectionExpanded {
                    Text(LocalizedStringKey(vm.cardMountPreset.rawValue))
                        .appSystemFont(size: 10.5)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCardActive ? Color.brightAmber.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Section 3.8: Vintage Photo Restoration (Collapsible)

    private var vintageRestorationSummaryText: String {
        if !vm.hasActiveVintageRestoration {
            return String(localized: "Off")
        }
        if vm.isShowingBeforeRestoration {
            return String(localized: "Before (Original)")
        }
        return String(localized: String.LocalizationValue(vm.restorationPrintTone.rawValue))
    }

    private var vintageRestorationSection: some View {
        DisclosureGroup(isExpanded: $vm.isRestorationSectionExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button {
                        vm.applyVintage19thCenturyPreset()
                    } label: {
                        Label("1860s Albumen Preset", systemImage: "wand.and.stars")
                            .appSystemFont(size: 11, weight: .semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.brightPink)
                    .disabled(!vm.hasLoadedImages || vm.isProcessing)

                    Button {
                        vm.resetVintageRestoration()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!vm.hasActiveVintageRestoration || vm.isProcessing)
                    .customTooltip("退色・階調復元設定をリセット")
                }

                Toggle("Remove Unilateral Noise & Dust", isOn: $vm.removeUnilateralNoise)
                    .appSystemFont(size: 11.5)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.brightPink)
                    .disabled(!vm.hasLoadedImages || vm.isProcessing)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Print Tone")
                        .appSystemFont(size: 11, weight: .semibold)
                        .foregroundColor(.secondary)
                    Picker("Print Tone", selection: $vm.restorationPrintTone) {
                        ForEach(VintagePrintTone.allCases) { tone in
                            Text(LocalizedStringKey(tone.rawValue)).tag(tone)
                        }
                    }
                    .labelsHidden()
                    .disabled(!vm.hasLoadedImages)
                }

                // 3点セット: Auto-Level (Black & White Point)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Auto-Level (B/W Point %)")
                            .appSystemFont(size: 11.5, weight: .semibold)
                        Spacer()
                        ResetButton(isModified: vm.restorationAutoLevel > 0.05) {
                            vm.restorationAutoLevel = 0.0
                        }
                        .disabled(!vm.hasLoadedImages)
                        NumericInput(
                            value: $vm.restorationAutoLevel,
                            range: 0.0...100.0,
                            format: "%.0f"
                        )
                        .disabled(!vm.hasLoadedImages)
                    }
                    Slider(value: $vm.restorationAutoLevel, in: 0.0...100.0)
                        .tint(.brightPink)
                        .disabled(!vm.hasLoadedImages)
                }

                // 3点セット: Local Contrast (CLAHE)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Local Contrast (CLAHE %)")
                            .appSystemFont(size: 11.5, weight: .semibold)
                        Spacer()
                        ResetButton(isModified: vm.restorationLocalContrast > 0.05) {
                            vm.restorationLocalContrast = 0.0
                        }
                        .disabled(!vm.hasLoadedImages)
                        NumericInput(
                            value: $vm.restorationLocalContrast,
                            range: 0.0...100.0,
                            format: "%.0f"
                        )
                        .disabled(!vm.hasLoadedImages)
                    }
                    Slider(value: $vm.restorationLocalContrast, in: 0.0...100.0)
                        .tint(.brightPink)
                        .disabled(!vm.hasLoadedImages)
                }

                Divider().opacity(0.3)

                // 3点セット: Optical Deblur (NAFNet / Edge-Aware)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Optical Deblur (%)")
                            .appSystemFont(size: 11.5, weight: .semibold)
                        Spacer()
                        ResetButton(isModified: vm.restorationDeblurStrength > 0.05) {
                            vm.restorationDeblurStrength = 0.0
                        }
                        .disabled(!vm.hasLoadedImages)
                        NumericInput(
                            value: $vm.restorationDeblurStrength,
                            range: 0.0...100.0,
                            format: "%.0f"
                        )
                        .disabled(!vm.hasLoadedImages)
                    }
                    Slider(value: $vm.restorationDeblurStrength, in: 0.0...100.0)
                        .tint(.brightPink)
                        .disabled(!vm.hasLoadedImages)
                    Text(vm.isCoreMLDeblurAvailable ? LocalizedStringKey("Core ML: NAFNet-GoPro Active") : LocalizedStringKey("Edge-Aware Fallback (Add NAFNetDeblur.mlmodelc for AI Deblur)"))
                        .appSystemFont(size: 9.5)
                        .foregroundColor(.secondary)
                }

                // 3点セット: Foliage / Texture Protection
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Foliage / Texture Protection (%)")
                            .appSystemFont(size: 11.5, weight: .semibold)
                        Spacer()
                        ResetButton(isModified: abs(vm.restorationTextureProtection - 60.0) > 0.5) {
                            vm.restorationTextureProtection = 60.0
                        }
                        .disabled(!vm.hasLoadedImages || vm.restorationDeblurStrength <= 0.05)
                        NumericInput(
                            value: $vm.restorationTextureProtection,
                            range: 0.0...100.0,
                            format: "%.0f"
                        )
                        .disabled(!vm.hasLoadedImages || vm.restorationDeblurStrength <= 0.05)
                    }
                    Slider(value: $vm.restorationTextureProtection, in: 0.0...100.0)
                        .tint(.brightPink)
                        .disabled(!vm.hasLoadedImages || vm.restorationDeblurStrength <= 0.05)
                }
                .opacity(vm.restorationDeblurStrength > 0.05 ? 1.0 : 0.45)

                Toggle("Show Original (Before Restore)", isOn: $vm.isShowingBeforeRestoration)
                    .appSystemFont(size: 11.5)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.brightPink)
                    .disabled(!vm.hasLoadedImages || !vm.hasActiveVintageRestoration)
            }
            .padding(.top, 10)
        } label: {
            HStack {
                sectionHeader(title: "VINTAGE PHOTO RESTORATION", color: .brightPink)
                Spacer()
                if !vm.isRestorationSectionExpanded {
                    Text(vintageRestorationSummaryText)
                        .appSystemFont(size: 10.5)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(vm.hasActiveVintageRestoration ? Color.brightPink.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Section 4: Basic Recipe (Collapsible Default Settings)

    private var recipeSummaryText: String {
        let card: String
        switch vm.stereoCardMode {
        case .off: card = String(localized: "Off")
        case .cropInner: card = String(localized: "Crop Inner")
        case .keepArchBlack: card = String(localized: "Keep Arch (Black)")
        }
        let ml = vm.useCoreMLCardSegmentation && vm.stereoCardMode != .off ? "AI" : "Std"
        let color: String
        switch vm.autoColorMode {
        case .off: color = String(localized: "Off")
        case .left: color = String(localized: "Left Ref")
        case .right: color = String(localized: "Right Ref")
        }
        return "\(card) · \(ml) · \(color)"
    }

    private var basicRecipeDisclosure: some View {
        DisclosureGroup(isExpanded: $isRecipeExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                // Card Detection
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(title: "STEREO CARD DETECTION", color: .brightPurple)

                    Picker("Card Mode", selection: $vm.stereoCardMode) {
                        ForEach(StereoCardMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Toggle("Core ML Card Segmentation (AI)", isOn: $vm.useCoreMLCardSegmentation)
                        .appSystemFont(size: 12)
                        .toggleStyle(.switch)
                        .tint(.brightPurple)
                        .disabled(vm.stereoCardMode == .off)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Segmentation Refiner")
                            .appSystemFont(size: 11, weight: .semibold)
                            .foregroundColor(.secondary)
                        Picker("Refiner", selection: $vm.coreMLRefinerModel) {
                            ForEach(CoreMLRefinerModel.allCases) { model in
                                Text(model.rawValue).tag(model)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .disabled(!vm.useCoreMLCardSegmentation || vm.stereoCardMode == .off)
                    .opacity(vm.useCoreMLCardSegmentation && vm.stereoCardMode != .off ? 1.0 : 0.45)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Card Frame")
                            .appSystemFont(size: 11, weight: .semibold)
                            .foregroundColor(.secondary)
                        Picker("Card Frame", selection: $vm.frameStyle) {
                            ForEach(StereoFrameStyle.allCases) { style in
                                Text(LocalizedStringKey(style.rawValue)).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .disabled(vm.stereoCardMode == .keepArchBlack)
                    .opacity(vm.stereoCardMode == .keepArchBlack ? 0.45 : 1.0)
                }

                Divider().opacity(0.3)

                // Alignment & Window AI
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(title: "AUTO ALIGNMENT & AI", color: .brightBlue)

                    Toggle("Auto Align on Load", isOn: $vm.autoAlignOnLoad)
                        .appSystemFont(size: 12)
                        .toggleStyle(.switch)
                        .tint(.brightBlue)

                    Toggle("Vision Person Motion Mask (Cha-Cha)", isOn: $vm.usePersonMotionMask)
                        .appSystemFont(size: 12)
                        .toggleStyle(.switch)
                        .tint(.brightBlue)

                    Toggle("Keep Original Aspect Ratio (MAAIR)", isOn: $vm.keepOriginalAspectRatio)
                        .appSystemFont(size: 12)
                        .toggleStyle(.switch)
                        .tint(.brightBlue)

                    Toggle("Vision Saliency Subject Priority", isOn: $vm.useAttentionSaliency)
                        .appSystemFont(size: 12)
                        .toggleStyle(.switch)
                        .tint(.brightAmber)
                        .onChange(of: vm.useAttentionSaliency) { _, _ in
                            vm.recalculateOptimalWindow()
                        }
                }

                Divider().opacity(0.3)

                // Color & Restoration
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(title: "STEREO COLOR & RESTORE", color: .brightPink)

                    Picker("Auto Color Match", selection: $vm.autoColorMode) {
                        ForEach(StereoAutoColorMode.allCases) { mode in
                            Text(LocalizedStringKey(mode == .off ? "Off" : (mode == .left ? "Left Ref" : "Right Ref"))).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    HStack(spacing: 8) {
                        Button("Match Left") {
                            vm.applyAutoColor(leftReference: true)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .disabled(!vm.hasLoadedImages || vm.isProcessing)

                        Button("Match Right") {
                            vm.applyAutoColor(leftReference: false)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .disabled(!vm.hasLoadedImages || vm.isProcessing)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                sectionHeader(title: "BASIC RECIPE", color: .brightPurple)
                Spacer()
                if !isRecipeExpanded {
                    Text(recipeSummaryText)
                        .appSystemFont(size: 10.5)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Section 4: Batch Processing (Collapsible)

    private var batchProcessingDisclosure: some View {
        DisclosureGroup(isExpanded: $vm.isBatchSectionExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input Pairing")
                        .appSystemFont(size: 11, weight: .semibold)
                        .foregroundColor(.secondary)
                    Picker("Pairing", selection: $vm.batchPairingMode) {
                        ForEach(StereoBatchPairingMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .disabled(vm.isBatchRunning)
                }

                Toggle("Save Adjustment Report (.txt)", isOn: $vm.batchSaveReport)
                    .appSystemFont(size: 12)
                    .toggleStyle(.switch)
                    .tint(.brightTeal)
                    .disabled(vm.isBatchRunning)

                HStack(spacing: 8) {
                    if let outFolder = vm.batchOutputFolder {
                        Text(outFolder.lastPathComponent)
                            .appSystemFont(size: 10.5, design: .monospaced)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Output: <Input>/ViewStereo_Output")
                            .appSystemFont(size: 10.5, design: .monospaced)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Output...") {
                        vm.chooseBatchOutputFolderPanel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.isBatchRunning)
                }

                if vm.isBatchRunning {
                    Button {
                        vm.cancelBatchProcessing()
                    } label: {
                        Label("Cancel Batch", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.palestineRed)
                } else {
                    Button {
                        vm.openBatchFolderPanel()
                    } label: {
                        Label("Select Folder & Run Batch", systemImage: "folder.badge.gearshape")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.palestineGreen)
                    .disabled(vm.isProcessing)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: vm.batchProgress)
                        .tint(.brightTeal)
                    HStack {
                        if vm.isBatchRunning {
                            Text(vm.batchCurrentFile)
                                .appSystemFont(size: 10.5, design: .monospaced)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("Ready (or drop a folder onto canvas)")
                                .appSystemFont(size: 10.5, design: .monospaced)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text("\(vm.batchCompletedCount)/\(vm.batchTotalCount)")
                            .appSystemFont(size: 10.5, weight: .semibold, design: .monospaced)
                            .foregroundColor(.brightTeal)
                    }
                }
                .opacity(vm.isBatchRunning || vm.batchTotalCount > 0 ? 1.0 : 0.45)
            }
            .padding(.top, 10)
        } label: {
            HStack {
                sectionHeader(title: "BATCH PROCESSING", color: .brightTeal)
                Spacer()
                if vm.isBatchRunning {
                    Text("\(vm.batchCompletedCount)/\(vm.batchTotalCount)")
                        .appSystemFont(size: 10.5, weight: .semibold, design: .monospaced)
                        .foregroundColor(.brightTeal)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Fixed Footer: Export

    private var exportFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Stereo Layout")
                    .appSystemFont(size: 11.5, weight: .semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Picker("Stereo Layout", selection: $vm.exportLayout) {
                    ForEach(StereoExportLayout.allCases) { layout in
                        Text(LocalizedStringKey(layout.rawValue)).tag(layout)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 230)
                .disabled(vm.isBatchRunning)
            }

            HStack(spacing: 8) {
                Text("Image Format")
                    .appSystemFont(size: 11.5, weight: .semibold)
                    .foregroundColor(.secondary)
                Spacer()
                if vm.exportLayout.supportsCustomImageFormat {
                    Picker("Image Format", selection: $vm.exportImageFormat) {
                        ForEach(StereoExportImageFormat.allCases) { fmt in
                            Text(fmt.rawValue).tag(fmt)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(vm.isBatchRunning)
                } else {
                    Text(vm.exportLayout.fixedFormatLabel)
                        .appSystemFont(size: 11, weight: .semibold, design: .monospaced)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(height: 24)

            HStack(spacing: 8) {
                Button {
                    vm.exportImage()
                } label: {
                    Label("Export Image", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(.palestineGreen)
                .disabled(!vm.hasLoadedImages || vm.isProcessing || vm.isBatchRunning)

                Button {
                    vm.exportAdjustmentReport()
                } label: {
                    Image(systemName: "doc.text")
                        .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .disabled(!vm.isAligned || vm.isBatchRunning)
                .customTooltip("調整レポート (.txt) を保存")
            }
        }
    }

    // MARK: - Helpers

    private func displayModeButton(for mode: StereoDisplayMode) -> some View {
        let isSelected = vm.displayMode == mode
        return Button {
            vm.displayMode = mode
        } label: {
            HStack(spacing: 4) {
                if mode.iconName == "eyeglasses" {
                    AnaglyphGlassesView(isSelected: isSelected)
                        .scaleEffect(0.72)
                        .frame(width: 26, height: 14)
                } else if mode.iconName == "polarized.glasses" {
                    PolarizedGlassesView(isSelected: isSelected)
                        .scaleEffect(0.72)
                        .frame(width: 26, height: 14)
                } else {
                    Image(systemName: mode.iconName)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(LocalizedStringKey(mode.label))
                    .appSystemFont(size: 11, weight: .semibold)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.darkAmber : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.brightAmber : Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3, height: 13)
            Text(LocalizedStringKey(title))
                .appSystemFont(size: 11, weight: .bold)
                .foregroundColor(color)
                .tracking(0.6)
        }
    }

    private func telemetryRow(label: String, value: String, highlight: Color = .primary) -> some View {
        HStack {
            Text(LocalizedStringKey(label))
                .appSystemFont(size: 11.5)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .appSystemFont(size: 11.5, weight: .semibold, design: .monospaced)
                .foregroundColor(highlight)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            vm.handleDroppedURLs(urls)
        }
        return true
    }
}
