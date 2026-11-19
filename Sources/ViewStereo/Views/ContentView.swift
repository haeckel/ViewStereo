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

            if vm.isShowingInspector {
                Divider()

                // 右サイドバー（Anti-Jitter 4層固定幅インスペクター）
                inspectorPanel
                    .frame(width: inspectorWidth, alignment: .topLeading)
                    .layoutPriority(2)
                    .clipped()
                    .background(Color(red: 0.11, green: 0.11, blue: 0.13))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 1024, minHeight: 680)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        vm.isShowingInspector.toggle()
                    }
                } label: {
                    Label("Sidebar", systemImage: "sidebar.right")
                }
                .customTooltip(String(localized: "Toggle Sidebar") + " (⌥⌘0)")
            }

            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    // Zone 1: ファイル・入力
                    ControlGroup {
                        Button {
                            vm.openImagesPanel()
                        } label: {
                            Label("Toolbar Open", systemImage: "photo.on.rectangle.angled")
                        }
                        .customTooltip(String(localized: "Open Stereoview Card, L/R or SBS...") + " (⌘O)")

                        Button {
                            vm.openBatchFolderPanel()
                        } label: {
                            Label("Toolbar Folder", systemImage: "folder.badge.gearshape")
                        }
                        .customTooltip(String(localized: "Batch Process Folder...") + " (⇧⌘B)")
                        .disabled(vm.isBatchRunning || vm.isProcessing)
                    } label: {
                        Text("Toolbar Open")
                    }
                    .controlGroupStyle(.automatic)
                    .labelStyle(.titleAndIcon)

                    toolbarDivider

                    // Zone 2: 解析・整準
                    ControlGroup {
                        Button {
                            vm.runAutoAlignment()
                        } label: {
                            Label("Toolbar Align", systemImage: "wand.and.stars")
                        }
                        .customTooltip(String(localized: "Auto Align & Window") + " (⇧⌘A)")
                        .disabled(!vm.hasLoadedImages || vm.isProcessing)
                    } label: {
                        Text("Toolbar Align")
                    }
                    .controlGroupStyle(.automatic)
                    .labelStyle(.titleAndIcon)

                    toolbarDivider

                    // Zone 3: 5タブ インスペクタ連動（色分けアイコン＋ショートラベル）
                    HStack(spacing: 4) {
                        toolbarTabButton(
                            titleKey: "Toolbar Window",
                            systemImage: "rectangle.inset.filled.and.person.filled",
                            color: .brightAmber,
                            isExpanded: vm.isWindowSectionExpanded,
                            tooltip: String(localized: "Toggle Stereo Window Panel") + " (⌥⌘1)"
                        ) {
                            toggleInspectorTab(\.isWindowSectionExpanded)
                        }

                        toolbarTabButton(
                            titleKey: "Toolbar Mount",
                            systemImage: "photo.artframe",
                            color: .brightBlue,
                            isExpanded: vm.isCardMountSectionExpanded,
                            tooltip: String(localized: "Toggle Stereoview Card Mount Panel") + " (⌥⌘2)"
                        ) {
                            toggleInspectorTab(\.isCardMountSectionExpanded)
                        }

                        toolbarTabButton(
                            titleKey: "Toolbar Restore",
                            systemImage: "sparkles",
                            color: .brightPink,
                            isExpanded: vm.isRestorationSectionExpanded,
                            tooltip: String(localized: "Toggle Vintage Restoration Panel") + " (⌥⌘3)"
                        ) {
                            toggleInspectorTab(\.isRestorationSectionExpanded)
                        }

                        toolbarTabButton(
                            titleKey: "Toolbar Colorize",
                            systemImage: "paintpalette.fill",
                            color: Color(red: 0.20, green: 0.85, blue: 0.98),
                            isExpanded: vm.isColorizationSectionExpanded,
                            tooltip: String(localized: "Toggle Colorization Panel") + " (⌥⌘4)"
                        ) {
                            toggleInspectorTab(\.isColorizationSectionExpanded)
                        }

                        toolbarTabButton(
                            titleKey: "Toolbar Recipe",
                            systemImage: "slider.horizontal.3",
                            color: .brightPurple,
                            isExpanded: vm.isRecipeSectionExpanded,
                            tooltip: String(localized: "Toggle Basic Recipe Panel") + " (⌥⌘5)"
                        ) {
                            toggleInspectorTab(\.isRecipeSectionExpanded)
                        }

                        toolbarTabButton(
                            titleKey: "Toolbar Batch",
                            systemImage: "square.stack.3d.up",
                            color: .brightTeal,
                            isExpanded: vm.isBatchSectionExpanded,
                            tooltip: String(localized: "Toggle Batch Processing Panel") + " (⌥⌘6)"
                        ) {
                            toggleInspectorTab(\.isBatchSectionExpanded)
                        }
                    }

                    toolbarDivider

                    // Zone 4: 出力（緑強調）
                    Button {
                        vm.exportImage()
                    } label: {
                        Label("Toolbar Export", systemImage: "square.and.arrow.up.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.palestineGreen)
                    .customTooltip(String(localized: "Export Image...") + " (⌘E)")
                    .disabled(!vm.hasLoadedImages || vm.isProcessing || vm.isBatchRunning)
                }
            }
        }
        .labelStyle(.titleAndIcon)
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
                        Text("Core ML (StereoCardSeg + SAM 2.1 Tiny) + LAPACK dposv_ & Metal Lanczos-3")
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
                    colorizationSection
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

    // MARK: - Inspector Header (Branding Header)

    private var inspectorHeader: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.35), radius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.currentDisplayTitle)
                    .appSystemFont(size: vm.hasLoadedImages ? 18 : 24, weight: .black, design: .rounded)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, Color(red: 0.4, green: 0.7, blue: 1.0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                if vm.hasLoadedImages {
                    Text(vm.currentSourceName)
                        .appSystemFont(size: 13, design: .monospaced)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)
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
            HStack(spacing: 6) {
                sectionHeader(title: "RESTORATION STATUS", color: .brightBlue)
                Circle()
                    .fill(statusBadgeColor)
                    .frame(width: 6, height: 6)
                Text(LocalizedStringKey(statusBadgeText))
                    .appSystemFont(size: 10, weight: .medium)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
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
        InspectorAccordionSection(
            title: "STEREO WINDOW",
            accentColor: .brightAmber,
            shortcutHint: "⌥⌘1",
            summary: vm.isAligned ? String(format: String(localized: "Auto: %.1f px"), vm.autoOptimalShiftX) : nil,
            borderColor: Color.brightAmber.opacity(vm.isAligned ? 0.35 : 0.14),
            isExpanded: $vm.isWindowSectionExpanded
        ) {
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
        }
        .opacity(vm.isAligned ? 1.0 : 0.65)
    }

    // MARK: - Section 3.5: Stereoview Card Mount (Collapsible)

    private var stereoviewCardMountSection: some View {
        let isCardActive = (vm.displayMode == .stereoviewCard || vm.exportLayout == .stereoviewCard)
        return InspectorAccordionSection(
            title: "STEREOVIEW CARD MOUNT",
            accentColor: .brightBlue,
            shortcutHint: "⌥⌘2",
            summary: !vm.isCardMountSectionExpanded ? String(localized: String.LocalizationValue(vm.cardMountPreset.rawValue)) : nil,
            borderColor: isCardActive ? Color.brightBlue.opacity(0.42) : Color.white.opacity(0.14),
            isExpanded: $vm.isCardMountSectionExpanded
        ) {
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
                                .foregroundColor(.brightBlue)
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
                                    .foregroundColor(.brightBlue)
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
                                .tint(.brightBlue)

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
        }
    }

    // MARK: - Section 3.8: Vintage Photo Restoration (Collapsible)

    private var vintageRestorationSummaryText: String {
        if !vm.isRestorationEnabled {
            return String(localized: "Off")
        }
        if vm.isShowingBeforeRestoration {
            return String(localized: "Before (Original)")
        }
        let hasToneOrDetail = !vm.makeVintageRestorationOptions(ignorePreviewToggle: true).isIdentity
            || !vm.makeDetailRestorationOptions(ignorePreviewToggle: true).isIdentity
        if !hasToneOrDetail {
            return vm.removeUnilateralNoise ? String(localized: "Remove Unilateral Noise") : String(localized: "Off")
        }
        return String(localized: String.LocalizationValue(vm.restorationPrintTone.rawValue))
    }

    private var vintageRestorationSection: some View {
        InspectorAccordionSection(
            title: "VINTAGE PHOTO RESTORATION",
            accentColor: .brightPink,
            shortcutHint: "⌥⌘3",
            summary: !vm.isRestorationSectionExpanded ? vintageRestorationSummaryText : nil,
            borderColor: (vm.hasActiveVintageRestoration || vm.effectiveRemoveUnilateralNoise) ? Color.brightPink.opacity(0.42) : Color.white.opacity(0.14),
            isExpanded: $vm.isRestorationSectionExpanded
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable Vintage & Noise Restoration", isOn: $vm.isRestorationEnabled)
                    .appSystemFont(size: 11.5, weight: .semibold)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.brightPink)
                    .disabled(vm.isProcessing)

                Divider().opacity(0.3)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Button {
                            vm.applyVintage19thCenturyPreset()
                        } label: {
                            Label("1860s Albumen", systemImage: "wand.and.stars")
                                .appSystemFont(size: 10.5, weight: .semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.brightPink)
                        .disabled(vm.isProcessing)
                        .customTooltip("1860年代 鶏卵紙プリセットを適用")

                        Button {
                            vm.apply1890sHandTintedPreset()
                        } label: {
                            Label("1890s Hand-Tint", systemImage: "paintbrush.pointed")
                                .appSystemFont(size: 10.5, weight: .semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.brightAmber)
                        .disabled(vm.isProcessing)
                        .customTooltip("1890年代 明治手彩色風プリセットを適用")

                        Button {
                            vm.resetVintageRestoration()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled((!vm.hasActiveVintageRestoration && !vm.isRestorationEnabled) || vm.isProcessing)
                        .customTooltip("退色・階調復元設定をリセット")
                    }

                    Toggle("Remove Unilateral Noise & Dust", isOn: $vm.removeUnilateralNoise)
                        .appSystemFont(size: 11.5)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.brightPink)
                        .disabled(vm.isProcessing)

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
                        .disabled(vm.isProcessing)
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
                            .disabled(vm.isProcessing)
                            NumericInput(
                                value: $vm.restorationAutoLevel,
                                range: 0.0...100.0,
                                format: "%.0f"
                            )
                            .disabled(vm.isProcessing)
                        }
                        Slider(value: $vm.restorationAutoLevel, in: 0.0...100.0)
                            .tint(.brightPink)
                            .disabled(vm.isProcessing)
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
                            .disabled(vm.isProcessing)
                            NumericInput(
                                value: $vm.restorationLocalContrast,
                                range: 0.0...100.0,
                                format: "%.0f"
                            )
                            .disabled(vm.isProcessing)
                        }
                        Slider(value: $vm.restorationLocalContrast, in: 0.0...100.0)
                            .tint(.brightPink)
                            .disabled(vm.isProcessing)
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
                            .disabled(vm.isProcessing)
                            NumericInput(
                                value: $vm.restorationDeblurStrength,
                                range: 0.0...100.0,
                                format: "%.0f"
                            )
                            .disabled(vm.isProcessing)
                        }
                        Slider(value: $vm.restorationDeblurStrength, in: 0.0...100.0)
                            .tint(.brightPink)
                            .disabled(vm.isProcessing)
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
                            .disabled(vm.restorationDeblurStrength <= 0.05 || vm.isProcessing)
                            NumericInput(
                                value: $vm.restorationTextureProtection,
                                range: 0.0...100.0,
                                format: "%.0f"
                            )
                            .disabled(vm.restorationDeblurStrength <= 0.05 || vm.isProcessing)
                        }
                        Slider(value: $vm.restorationTextureProtection, in: 0.0...100.0)
                            .tint(.brightPink)
                            .disabled(vm.restorationDeblurStrength <= 0.05 || vm.isProcessing)
                    }
                    .opacity(vm.restorationDeblurStrength > 0.05 ? 1.0 : 0.45)

                    HStack(spacing: 8) {
                        Button {
                            vm.applyVintageRestoration()
                        } label: {
                            Label("Apply Restoration", systemImage: "wand.and.stars")
                                .appSystemFont(size: 11.5, weight: .semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.brightPink)
                        .disabled(!vm.hasLoadedImages || vm.isProcessing)
                    }

                    Toggle("Show Original (Before Restore)", isOn: $vm.isShowingBeforeRestoration)
                        .appSystemFont(size: 11.5)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.brightPink)
                        .disabled(!vm.hasLoadedImages || !vm.hasActiveVintageRestoration)
                }
            }
        }
    }

    // MARK: - Section 3.9: Hand-Tinted & AI Colorization (Collapsible)

    private var colorizationSection: some View {
        let accent = Color(red: 0.20, green: 0.85, blue: 0.98)
        return InspectorAccordionSection(
            title: "COLORIZATION & HAND-TINT",
            accentColor: accent,
            shortcutHint: "⌥⌘4",
            summary: !vm.isColorizationSectionExpanded
                ? String(localized: String.LocalizationValue(vm.restorationColorizationMode.rawValue))
                : nil,
            borderColor: vm.hasActiveColorization ? accent.opacity(0.42) : Color.white.opacity(0.14),
            isExpanded: $vm.isColorizationSectionExpanded
        ) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hand-Tinted & AI Colorization")
                        .appSystemFont(size: 11, weight: .semibold)
                        .foregroundColor(.secondary)
                    Picker("Colorization Mode", selection: $vm.restorationColorizationMode) {
                        ForEach(StereoColorizationMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .disabled(vm.isProcessing)
                    if vm.restorationColorizationMode == .handTinted1890s || vm.restorationColorizationMode == .naturalAI {
                        Text(vm.isCoreMLColorizerAvailable ? LocalizedStringKey("Core ML: StereoColorizer Active") : LocalizedStringKey("Hand-Tint Fallback (Add StereoColorizer.mlmodelc for AI Color)"))
                            .appSystemFont(size: 9.5)
                            .foregroundColor(.secondary)
                    }
                }

                // 3点セット: Color Intensity (%)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Color Intensity (%)")
                            .appSystemFont(size: 11.5, weight: .semibold)
                        Spacer()
                        ResetButton(isModified: abs(vm.restorationColorStrength - 20.0) > 0.5) {
                            vm.restorationColorStrength = 20.0
                        }
                        .disabled(vm.isProcessing)
                        NumericInput(
                            value: $vm.restorationColorStrength,
                            range: 0.0...100.0,
                            format: "%.0f"
                        )
                        .disabled(vm.isProcessing)
                    }
                    Slider(value: $vm.restorationColorStrength, in: 0.0...100.0)
                        .tint(accent)
                        .disabled(vm.isProcessing)
                }

                // 3点セット: Tint Warmth (%)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Tint Warmth (%)")
                            .appSystemFont(size: 11.5, weight: .semibold)
                        Spacer()
                        ResetButton(isModified: abs(vm.restorationPaperWarmth - 30.0) > 0.5) {
                            vm.restorationPaperWarmth = 30.0
                        }
                        .disabled(vm.isProcessing)
                        NumericInput(
                            value: $vm.restorationPaperWarmth,
                            range: 0.0...100.0,
                            format: "%.0f"
                        )
                        .disabled(vm.isProcessing)
                    }
                    Slider(value: $vm.restorationPaperWarmth, in: 0.0...100.0)
                        .tint(accent)
                        .disabled(vm.isProcessing)
                }

                HStack(spacing: 8) {
                    Button {
                        vm.applyColorization()
                    } label: {
                        Label(
                            vm.restorationColorizationMode == .off && vm.hasActiveColorization ? LocalizedStringKey("Clear Colorization") : LocalizedStringKey("Apply Colorization"),
                            systemImage: "paintpalette.fill"
                        )
                        .appSystemFont(size: 11.5, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(!vm.hasLoadedImages || vm.isProcessing)

                    Button {
                        vm.resetColorization()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11))
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.bordered)
                    .disabled((!vm.hasActiveColorization && vm.restorationColorizationMode == .off) || vm.isProcessing)
                    .customTooltip("カラー化設定をリセット")
                }

                Toggle("Show Original (Before Restore)", isOn: $vm.isShowingBeforeRestoration)
                    .appSystemFont(size: 11.5)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(accent)
                    .disabled(!vm.hasLoadedImages || !vm.hasActiveVintageRestoration)
            }
        }
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
        InspectorAccordionSection(
            title: "BASIC RECIPE",
            accentColor: .brightPurple,
            shortcutHint: "⌥⌘5",
            summary: !vm.isRecipeSectionExpanded ? recipeSummaryText : nil,
            borderColor: Color.white.opacity(0.14),
            isExpanded: $vm.isRecipeSectionExpanded
        ) {
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
        }
    }

    // MARK: - Section 4: Batch Processing (Collapsible)

    private var batchProcessingDisclosure: some View {
        InspectorAccordionSection(
            title: "BATCH PROCESSING",
            accentColor: .brightTeal,
            shortcutHint: "⌥⌘6",
            summary: vm.isBatchRunning ? "\(vm.batchCompletedCount)/\(vm.batchTotalCount)" : nil,
            borderColor: vm.isBatchRunning ? Color.brightTeal.opacity(0.45) : Color.white.opacity(0.14),
            isExpanded: $vm.isBatchSectionExpanded
        ) {
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
        }
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

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.35))
            .frame(width: 1, height: 22)
    }

    private func toolbarTabButton(
        titleKey: String,
        systemImage: String,
        color: Color,
        isExpanded: Bool,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(titleKey), systemImage: systemImage)
        }
        .foregroundStyle(color)
        .background(
            (isExpanded && vm.isShowingInspector) ? color.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .customTooltip(tooltip)
    }

    private func toggleInspectorTab(_ keyPath: ReferenceWritableKeyPath<ViewStereoViewModel, Bool>) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if !vm.isShowingInspector {
                vm.isShowingInspector = true
                vm[keyPath: keyPath] = true
            } else {
                vm[keyPath: keyPath].toggle()
            }
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

private struct InspectorAccordionSection<Content: View>: View {
    let title: String
    let accentColor: Color
    let shortcutHint: String
    let summary: String?
    let borderColor: Color
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(accentColor)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 12)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(accentColor)
                        .frame(width: 4, height: 16)

                    Text(LocalizedStringKey(title))
                        .appSystemFont(size: 12.5, weight: .bold)
                        .foregroundColor(.white)
                        .tracking(0.3)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    if let summary, !summary.isEmpty {
                        Text(summary)
                            .appSystemFont(size: 10.5, weight: .medium)
                            .foregroundColor(.white.opacity(0.68))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Text(shortcutHint)
                        .appSystemFont(size: 9.5, weight: .semibold, design: .monospaced)
                        .foregroundColor(.white.opacity(0.55))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    accentColor.opacity(
                        isExpanded ? (isHovered ? 0.20 : 0.14) : (isHovered ? 0.11 : 0.05)
                    )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
            }

            if isExpanded {
                Divider()
                    .background(accentColor.opacity(0.28))

                content()
                    .padding(12)
            }
        }
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: 1)
        )
    }
}
