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
    @State private var isHoveringWelcomeIcon = false
    @State private var isShowingBatchSettingsPopover = false

    private var inspectorWidth: CGFloat {
        settings.useLargeTextMode ? 450 : 400
    }

    private var effectiveBrowserWidth: CGFloat {
        let base = settings.useLargeTextMode ? max(vm.fileBrowserWidth, 290) : vm.fileBrowserWidth
        return min(360, max(220, base))
    }

    var body: some View {
        VStack(spacing: 0) {
            topWorkspaceModeBar
            Divider().opacity(0.35)

            HStack(spacing: 0) {
                if vm.isShowingFileBrowser {
                WorkspaceFileBrowserView(vm: vm, store: vm.browserStore, width: effectiveBrowserWidth)
                    .frame(width: effectiveBrowserWidth, alignment: .topLeading)
                    .layoutPriority(2)
                    .clipped()
                    .background(Color(red: 0.09, green: 0.09, blue: 0.11))
                    .zIndex(2)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                // ドラッグリサイズ可能な境界線
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 4)
                    .contentShape(Rectangle())
                    .zIndex(2)
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let next = vm.fileBrowserWidth + value.translation.width
                                vm.fileBrowserWidth = min(360, max(220, next))
                            }
                    )
            }

            // メインプレビュー領域（Drop 対応）
            mainCanvasView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .layoutPriority(1)
                .background(Color(red: 0.06, green: 0.06, blue: 0.07))
                .zIndex(0)
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers: providers)
                }

            if vm.isShowingInspector {
                Divider()
                    .zIndex(2)

                // 右サイドバー（Anti-Jitter 4層固定幅インスペクター）
                inspectorPanel
                    .frame(width: inspectorWidth, alignment: .topLeading)
                    .layoutPriority(2)
                    .clipped()
                    .background(Color(red: 0.11, green: 0.11, blue: 0.13))
                    .zIndex(2)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 1180, minHeight: 680)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        vm.isShowingFileBrowser.toggle()
                    }
                } label: {
                    Label("File Browser", systemImage: "sidebar.left")
                }
                .customTooltip(String(localized: "Toggle File Browser") + " (⌥⌘L)")
            }

            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    // Zone 1: フォルダ・セッション
                    ControlGroup {
                        Button {
                            vm.openWorkspaceFolderPanel()
                        } label: {
                            Label("Toolbar Open Folder", systemImage: "folder.badge.plus")
                        }
                        .customTooltip(String(localized: "Open Workspace Folder...") + " (⇧⌘O)")
                        .disabled(vm.isBatchRunning)

                        Button {
                            vm.resetToInitialState()
                        } label: {
                            Label("Toolbar New", systemImage: "plus.square.dashed")
                        }
                        .customTooltip(String(localized: "New Session") + " (⌘N)")
                        .disabled((!vm.hasLoadedImages && vm.batchCompletionSummary == nil) || vm.isProcessing || vm.isBatchRunning)
                    } label: {
                        Text("Toolbar Open Folder")
                    }
                    .controlGroupStyle(.automatic)
                    .labelStyle(.titleAndIcon)

                    toolbarDivider

                    // Zone 2: 解析・整準（または 2D→3D 再推論）
                    ControlGroup {
                        if vm.isVideoLoaded {
                            Button {
                                vm.refreshVideoEngineAndReprocess()
                            } label: {
                                Label("Toolbar Re-Depth", systemImage: "cube.transparent")
                            }
                            .customTooltip(String(localized: "Re-run Video Frame"))
                            .disabled(vm.isProcessing || vm.isExportingVideo)
                        } else if vm.workspaceMode == .convert2DTo3D {
                            Button {
                                if let url = vm.leftURL {
                                    vm.loadSingleSBSImage(url: url, resetRestoration: false, interpretationOverride: .force2D)
                                }
                            } label: {
                                Label("Toolbar Re-Depth", systemImage: "cube.transparent")
                            }
                            .customTooltip(String(localized: "Re-run AI 2D → 3D Conversion"))
                            .disabled(!vm.hasLoadedImages || vm.isProcessing)
                        } else {
                            Button {
                                vm.runAutoAlignment()
                            } label: {
                                Label("Toolbar Align", systemImage: "wand.and.stars")
                            }
                            .customTooltip(String(localized: "Auto Align & Window") + " (⇧⌘A)")
                            .disabled(!vm.hasLoadedImages || vm.isProcessing)
                        }
                    } label: {
                        Text("Toolbar Align")
                    }
                    .controlGroupStyle(.automatic)
                    .labelStyle(.titleAndIcon)

                    toolbarDivider

                    // Zone 3: インスペクタ連動（5タブと1対1同期）
                    HStack(spacing: 4) {
                        let is2D3DMode = vm.workspaceMode == .convert2DTo3D || vm.isVideoLoaded
                        toolbarTabButton(
                            titleKey: is2D3DMode ? "Toolbar 2D3D" : "Toolbar Recipe",
                            systemImage: is2D3DMode ? "cube.transparent.fill" : "slider.horizontal.3",
                            color: .brightPurple,
                            isExpanded: vm.selectedInspectorTab == 0,
                            tooltip: String(localized: is2D3DMode ? "Toggle 2D → 3D Conversion Panel" : "Toggle Basic Recipe Panel") + " (⌥⌘1)"
                        ) {
                            selectInspectorTab(0)
                        }

                        toolbarTabButton(
                            titleKey: "Toolbar Mount",
                            systemImage: "photo.artframe",
                            color: .brightBlue,
                            isExpanded: vm.selectedInspectorTab == 1,
                            tooltip: String(localized: "Toggle Stereoview Card Mount Panel") + " (⌥⌘2)"
                        ) {
                            selectInspectorTab(1)
                        }

                        toolbarTabButton(
                            titleKey: "Toolbar Restore",
                            systemImage: "sparkles",
                            color: .brightPink,
                            isExpanded: vm.selectedInspectorTab == 2,
                            tooltip: String(localized: "Toggle Vintage Restoration Panel") + " (⌥⌘3)"
                        ) {
                            selectInspectorTab(2)
                        }

                        toolbarTabButton(
                            titleKey: "Toolbar Colorize",
                            systemImage: "paintpalette.fill",
                            color: Color(red: 0.20, green: 0.85, blue: 0.98),
                            isExpanded: vm.selectedInspectorTab == 3,
                            tooltip: String(localized: "Toggle Colorization Panel") + " (⌥⌘4)"
                        ) {
                            selectInspectorTab(3)
                        }

                        toolbarTabButton(
                            titleKey: "tab_export_short",
                            systemImage: "square.and.arrow.up.fill",
                            color: .brightTeal,
                            isExpanded: vm.selectedInspectorTab == 4,
                            tooltip: String(localized: "Toggle Export Panel") + " (⌥⌘5)"
                        ) {
                            selectInspectorTab(4)
                        }
                    }

                    toolbarDivider

                    // Zone 4: 出力
                    Button {
                        vm.exportImage()
                    } label: {
                        Label("Toolbar Export", systemImage: "square.and.arrow.up.fill")
                    }
                    .foregroundStyle(Color.brightTeal)
                    .customTooltip(String(localized: "Export Image...") + " (⌘E)")
                    .disabled(!vm.hasLoadedImages || vm.isProcessing || vm.isBatchRunning)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        vm.isShowingInspector.toggle()
                    }
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .customTooltip(String(localized: "Toggle Sidebar") + " (⌥⌘0)")
            }
        }
        .labelStyle(.titleAndIcon)
        .sheet(isPresented: $isShowingUpdateSheet, onDismiss: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                vm.presentStartupFolderPromptIfNeeded(in: NSApp.keyWindow ?? NSApp.mainWindow)
            }
        }) {
            StudioUpdateNotificationSheet(manager: updateManager)
        }
        .onAppear {
            if updateManager.updateAvailable {
                isShowingUpdateSheet = true
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !isShowingUpdateSheet {
                        vm.presentStartupFolderPromptIfNeeded(in: NSApp.keyWindow ?? NSApp.mainWindow)
                    }
                }
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

    // MARK: - Top Workspace Mode Bar (上位処理モード切替)

    private var topWorkspaceModeBar: some View {
        let isStereoRestore = vm.workspaceMode == .stereoRestore
        let accentColor: Color = isStereoRestore ? .brightAmber : .brightBlue
        let isLocked = vm.isBatchRunning || vm.isProcessing

        // バー全体の背景グラデーション（暖色アンバー系 vs 寒色ディープインディゴ〜シアン系）
        let barGradientColors: [Color] = isStereoRestore
            ? [
                Color(red: 0.36, green: 0.18, blue: 0.02),
                Color(red: 0.22, green: 0.11, blue: 0.02),
                Color(red: 0.29, green: 0.15, blue: 0.02)
            ]
            : [
                Color(red: 0.09, green: 0.14, blue: 0.38),
                Color(red: 0.05, green: 0.16, blue: 0.30),
                Color(red: 0.08, green: 0.12, blue: 0.34)
            ]

        return ZStack(alignment: .bottom) {
            HStack(spacing: 16) {
                // 左: 動的モードステータスバッジ（周辺視野でも現在の運用モードが即座に判別可能）
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 7, height: 7)
                            .shadow(color: accentColor.opacity(0.9), radius: 4)

                        Image(systemName: isStereoRestore ? "rectangle.split.2x1.fill" : "cube.transparent.fill")
                            .appSystemFont(size: 11, weight: .bold)
                            .foregroundStyle(accentColor)

                        Text(LocalizedStringKey(isStereoRestore ? "Stereo Restore Mode" : "AI 2D→3D Mode"))
                            .appSystemFont(size: 11.5, weight: .bold)
                            .foregroundStyle(.white)
                            .tracking(0.3)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(accentColor.opacity(0.22))
                            .overlay(
                                Capsule()
                                    .stroke(accentColor.opacity(0.75), lineWidth: 1)
                            )
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 中央: アイコン＆高コントラストグラデーション付きモード切替カプセル
                HStack(spacing: 4) {
                    ForEach(ViewStereoWorkspaceMode.allCases) { mode in
                        let isSelected = vm.workspaceMode == mode
                        let isStereo = mode == .stereoRestore
                        let iconName = isStereo ? "rectangle.split.2x1.fill" : "cube.transparent.fill"
                        // スタイルガイド 2.6節準拠: 白飛びしない深層グラデーション＋純白太字
                        let gradientColors: [Color] = isStereo
                            ? [Color(red: 0.82, green: 0.46, blue: 0.04), Color(red: 0.60, green: 0.28, blue: 0.01)]
                            : [Color(red: 0.28, green: 0.22, blue: 0.82), Color(red: 0.02, green: 0.50, blue: 0.78)]
                        let strokeColor: Color = isStereo ? .brightAmber : .brightBlue

                        Button {
                            guard vm.workspaceMode != mode else { return }
                            withAnimation(.easeInOut(duration: 0.22)) {
                                vm.workspaceMode = mode
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: iconName)
                                    .appSystemFont(size: 12, weight: .semibold)
                                Text(LocalizedStringKey(mode.rawValue))
                                    .appSystemFont(size: 12.5, weight: isSelected ? .bold : .medium)
                            }
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.68))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background {
                                if isSelected {
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: gradientColors,
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .overlay(
                                            Capsule()
                                                .stroke(strokeColor.opacity(0.85), lineWidth: 1)
                                        )
                                        .shadow(color: strokeColor.opacity(0.45), radius: 6, y: 1)
                                } else {
                                    Capsule()
                                        .fill(Color.clear)
                                }
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.55))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                )
                .fixedSize()
                .disabled(isLocked)
                .opacity(isLocked ? 0.55 : 1.0)
                .customTooltip(String(localized: "Switch between Stereo Restoration and dedicated 2D → 3D Conversion"))

                // 右: 現在モードの簡潔な説明（左カラムと対称の maxWidth: .infinity で中央揃えを維持）
                Text(LocalizedStringKey(isStereoRestore ? "mode_desc_stereo_restore" : "mode_desc_2d_to_3d"))
                    .appSystemFont(size: 11, weight: .medium)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                LinearGradient(
                    colors: barGradientColors,
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .animation(.easeInOut(duration: 0.22), value: vm.workspaceMode)

            // 下辺の全面モード連動発光アクセントライン
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [accentColor.opacity(0.9), accentColor.opacity(0.65), accentColor.opacity(0.9)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 2.5)
                .shadow(color: accentColor.opacity(0.55), radius: 4, y: 1)
                .animation(.easeInOut(duration: 0.22), value: vm.workspaceMode)
        }
    }

    // MARK: - Main Canvas & Landing View

    @ViewBuilder
    private var mainCanvasView: some View {
        ZStack {
            VStack(spacing: 0) {
                // 上部ツールストリップ（常時表示：立体視方式切替 + 左右スワップ + ステータス）
                topToolbarStrip

                // 画像キャンバス または ランディング案内（バッチ実行中もライブプレビューを表示）
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

                if vm.isVideoLoaded {
                    videoTimelineBar
                }
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

    private var videoTimelineBar: some View {
        let totalSec = max(0.01, vm.videoMetadata?.durationSeconds ?? 0.01)
        return HStack(spacing: 10) {
            Button {
                vm.toggleVideoPlayback()
            } label: {
                Image(systemName: vm.isVideoPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderedProminent)
            .tint(.brightBlue)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(vm.isExportingVideo)

            HStack(spacing: 2) {
                Button {
                    vm.stepVideoFrame(deltaFrames: -1)
                } label: {
                    Image(systemName: "backward.frame.fill")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.isExportingVideo)

                Button {
                    vm.stepVideoFrame(deltaFrames: 1)
                } label: {
                    Image(systemName: "forward.frame.fill")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.isExportingVideo)
            }

            Text(Self.formatVideoTime(vm.videoCurrentTimeSeconds))
                .appSystemFont(size: 10.5, weight: .semibold, design: .monospaced)
                .foregroundColor(.white)
                .frame(width: 48, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { vm.videoCurrentTimeSeconds },
                    set: { newVal in
                        vm.videoCurrentTimeSeconds = newVal
                    }
                ),
                in: 0.0...totalSec,
                onEditingChanged: { editing in
                    if !editing {
                        vm.seekVideoAndRender(to: vm.videoCurrentTimeSeconds, resetSession: true, isPlaybackFrame: false, progressiveWarmup: true)
                    } else if vm.isVideoPlaying {
                        vm.toggleVideoPlayback()
                    }
                }
            )
            .tint(.brightBlue)
            .disabled(vm.isExportingVideo)

            Text(Self.formatVideoTime(totalSec))
                .appSystemFont(size: 10.5, design: .monospaced)
                .foregroundColor(.secondary)
                .frame(width: 48, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.45))
        .overlay(Divider().opacity(0.3), alignment: .top)
    }

    private static func formatVideoTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let frac = max(0, Int((seconds - Double(s)) * 10.0))
        let mins = s / 60
        let secs = s % 60
        return String(format: "%02d:%02d.%d", mins, secs, frac)
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
        .customTooltip(String(localized: "Swap Left / Right") + " (X)")
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
        .customTooltip(String(localized: "Compare Before / After Restoration"))
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
            let activeTint: Color = vm.isBatchVerifyOnly ? .brightAmber : .brightTeal
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(LocalizedStringKey(vm.isBatchVerifyOnly ? "Verifying Stereo..." : "Batch Processing..."))
                        .appSystemFont(size: 12.5, weight: .semibold)
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(vm.batchCompletedCount) / \(vm.batchTotalCount)")
                        .appSystemFont(size: 12, weight: .bold, design: .monospaced)
                        .foregroundColor(activeTint)
                    Button {
                        vm.cancelBatchProcessing()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .customTooltip(String(localized: "Cancel Processing"))
                }

                ProgressView(value: vm.batchProgress)
                    .tint(activeTint)

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
                    .stroke(activeTint.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 6)
        } else if let summary = vm.batchCompletionSummary {
            let hasIssues = summary.failed > 0 || summary.warningCount > 0
            let isCleanSuccess = !summary.wasCancelled && !hasIssues
            let accentColor: Color = isCleanSuccess ? .brightTeal : .brightAmber

            HStack(spacing: 12) {
                Image(systemName: isCleanSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(
                        summary.isVerifyOnly
                            ? (summary.wasCancelled ? "Verification Cancelled" : (hasIssues ? "Verification Finished with Warnings" : "Verification Complete"))
                            : (summary.wasCancelled ? "Batch Cancelled" : (summary.failed > 0 ? "Batch Finished with Errors" : "Batch Complete"))
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

                if summary.isVerifyOnly {
                    if summary.warningCount > 0 || summary.failed > 0 {
                        Button {
                            vm.browserStore.showWarningsOnly = true
                            vm.isShowingFileBrowser = true
                            vm.dismissBatchCompletionNotice()
                        } label: {
                            Label("Filter Warnings", systemImage: "exclamationmark.triangle")
                                .appSystemFont(size: 11.5, weight: .semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.darkAmber)
                    }
                } else {
                    Button {
                        vm.openBatchOutputFolderInFinder()
                    } label: {
                        Label("Open Output", systemImage: "folder")
                            .appSystemFont(size: 11.5, weight: .semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(isCleanSuccess ? .palestineGreen : .darkAmber)
                }

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
            .frame(maxWidth: 540)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(accentColor.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 6)
        }
    }

    private func batchSummaryDetailText(_ summary: BatchCompletionSummary) -> String {
        if summary.isVerifyOnly {
            let okCount = max(0, summary.succeeded - summary.warningCount)
            if summary.wasCancelled {
                return String(format: String(localized: "%d / %d checked (%d warnings, %d failed)"), summary.succeeded, summary.total, summary.warningCount, summary.failed)
            }
            return String(format: String(localized: "%d OK, %d warnings, %d failed"), okCount, summary.warningCount, summary.failed)
        }
        let dirName = summary.outputDirectory.lastPathComponent
        if summary.wasCancelled {
            return String(format: String(localized: "%d / %d completed → %@/"), summary.succeeded, summary.total, dirName)
        } else if summary.failed > 0 {
            return String(format: String(localized: "%d succeeded, %d failed → %@/"), summary.succeeded, summary.failed, dirName)
        } else {
            return String(format: String(localized: "%d succeeded → %@/"), summary.succeeded, dirName)
        }
    }

    private var heroBackgroundImage: Image {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "HeroBackground", withExtension: "jpg"),
           let nsImg = NSImage(contentsOf: url) {
            return Image(nsImage: nsImg)
        }
        if let url = Bundle.module.url(forResource: "hero_card", withExtension: "jpg"),
           let nsImg = NSImage(contentsOf: url) {
            return Image(nsImage: nsImg)
        }
        #endif
        if NSImage(named: "HeroBackground") != nil {
            return Image("HeroBackground")
        }
        return Image("HeroBackground")
    }

    private var welcomeIconImage: NSImage? {
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

    // MARK: - Batch Queue Canvas View

    private var batchQueueCanvasView: some View {
        VStack(spacing: 0) {
            // 上部ヘッダー（フォルダ情報・アクションボタン）
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "folder.fill.badge.gearshape")
                        .font(.system(size: 26))
                        .foregroundColor(.brightTeal)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(vm.batchInputFolder?.lastPathComponent ?? "Batch Folder")
                                .appSystemFont(size: 15, weight: .bold)
                                .foregroundColor(.white)

                            Text(String(format: NSLocalizedString("%lld items", comment: ""), Int64(vm.batchQueueItems.count)))
                                .appSystemFont(size: 11, weight: .semibold)
                                .foregroundColor(.brightTeal)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.brightTeal.opacity(0.16), in: Capsule())
                        }

                        if let path = vm.batchInputFolder?.path {
                            Text(path)
                                .appSystemFont(size: 10.5, design: .monospaced)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 16)

                    if vm.isBatchRunning {
                        Button {
                            vm.cancelBatchProcessing()
                        } label: {
                            Label("Cancel Batch", systemImage: "xmark.circle")
                                .appSystemFont(size: 12, weight: .bold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.palestineRed)
                    } else {
                        HStack(spacing: 10) {
                            Button {
                                vm.dismissBatchQueue()
                            } label: {
                                Text(LocalizedStringKey("Close Queue"))
                                    .appSystemFont(size: 12)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)

                            Button {
                                vm.startBatchProcessing()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "play.fill")
                                    Text(String(format: NSLocalizedString("Execute Batch (%lld files)", comment: ""), Int64(vm.batchQueueItems.count)))
                                }
                            }
                            .buttonStyle(InspectorActionButtonStyle(accentColor: .brightTeal, isPending: false, fullWidth: false))
                            .disabled(vm.batchQueueItems.isEmpty)
                        }
                    }
                }

                Divider().opacity(0.25)

                // 設定サマリーストリップ
                HStack(spacing: 8) {
                    Text(LocalizedStringKey("Current Recipe:"))
                        .appSystemFont(size: 11, weight: .semibold)
                        .foregroundColor(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            recipeBadge(icon: "photo.artframe", label: String(localized: String.LocalizationValue(vm.cardMountPreset.rawValue)), color: .brightBlue)
                            recipeBadge(icon: "square.and.arrow.up", label: "\(String(localized: String.LocalizationValue(vm.exportLayout.rawValue))) (\(vm.exportImageFormat.rawValue.uppercased()))", color: .brightTeal)
                            recipeBadge(
                                icon: "wand.and.stars",
                                label: vm.isRestorationEnabled ? String(localized: String.LocalizationValue(vm.restorationPrintTone.rawValue)) : String(localized: "Off"),
                                color: .brightPink
                            )
                            recipeBadge(
                                icon: "paintpalette.fill",
                                label: String(localized: String.LocalizationValue(vm.restorationColorizationMode.rawValue)),
                                color: Color(red: 0.20, green: 0.85, blue: 0.98)
                            )
                            recipeBadge(icon: "gearshape.2.fill", label: String(localized: String.LocalizationValue(vm.stereoCardMode.rawValue)), color: .brightPurple)
                        }
                    }

                    Spacer(minLength: 8)

                    Text(LocalizedStringKey("Adjust settings in inspector, then click Execute Batch."))
                        .appSystemFont(size: 10.5)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.04))
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(Color.white.opacity(0.10)),
                alignment: .bottom
            )

            // バッチ実行中のプログレスバー
            if vm.isBatchRunning {
                VStack(spacing: 6) {
                    ProgressView(value: vm.batchProgress)
                        .tint(.brightTeal)
                    HStack {
                        Text("\(vm.batchCompletedCount) / \(vm.batchTotalCount) completed")
                            .appSystemFont(size: 11, design: .monospaced)
                            .foregroundColor(.secondary)
                        if vm.batchFailedCount > 0 {
                            Text("(\(vm.batchFailedCount) failed)")
                                .appSystemFont(size: 11, design: .monospaced)
                                .foregroundColor(.brightAmber)
                        }
                        Spacer()
                        if !vm.batchCurrentFile.isEmpty {
                            Text(vm.batchCurrentFile)
                                .appSystemFont(size: 11, design: .monospaced)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.brightTeal.opacity(0.08))
            }

            // ファイルリスト
            if vm.batchQueueItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(LocalizedStringKey("No stereo images found in this folder."))
                        .appSystemFont(size: 13, weight: .medium)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(vm.batchQueueItems.enumerated()), id: \.element.id) { idx, item in
                            HStack(spacing: 10) {
                                Text("\(idx + 1)")
                                    .appSystemFont(size: 11, design: .monospaced)
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .frame(width: 28, alignment: .trailing)

                                Image(systemName: item.rightURL == nil ? "rectangle.split.2x1.fill" : "square.split.2x1.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.brightTeal.opacity(0.85))
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayLabel)
                                        .appSystemFont(size: 12, weight: .medium)
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    if let right = item.rightURL {
                                        Text("L: \(item.leftURL.lastPathComponent)  |  R: \(right.lastPathComponent)")
                                            .appSystemFont(size: 10, design: .monospaced)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                Text(item.rightURL == nil ? "SBS" : "L/R Pair")
                                    .appSystemFont(size: 10, weight: .semibold, design: .monospaced)
                                    .foregroundColor(.white.opacity(0.7))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                idx % 2 == 0 ? Color.white.opacity(0.02) : Color.clear
                            )
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.10))
    }

    private func recipeBadge(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
            Text(label)
                .appSystemFont(size: 10, weight: .medium)
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(color.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var chevronSpacer: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .black))
            .foregroundColor(.secondary.opacity(0.3))
            .padding(.top, 22)
            .padding(.horizontal, 8)
    }

    private var landingView: some View {
        VStack(spacing: 38) {
            // Background visual (Ambient Aura & Welcome Icon)
            ZStack {
                ZStack {
                    // Outer ambient glow (アンバー ＆ ブルーの光彩)
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.brightAmber.opacity(0.35), Color.brightBlue.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 380, height: 380)
                        .blur(radius: 70)

                    // Inner core glow
                    Circle()
                        .fill(Color.brightAmber.opacity(0.20))
                        .frame(width: 250, height: 250)
                        .blur(radius: 35)
                }
                .padding(100)
                .drawingGroup()
                .padding(-100)
                .allowsHitTesting(false)

                // Welcome Icon
                Button {
                    vm.openImagesPanel()
                } label: {
                    if let icon = welcomeIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 270, height: 270)
                            .clipShape(RoundedRectangle(cornerRadius: 62))
                            .shadow(color: .black.opacity(0.40), radius: 28, x: 0, y: 16)
                            .scaleEffect(isHoveringWelcomeIcon ? 1.02 : 1.0)
                            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHoveringWelcomeIcon)
                    } else {
                        RoundedRectangle(cornerRadius: 62)
                            .fill(LinearGradient(colors: [.darkAmber, .brightAmber], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 270, height: 270)
                            .shadow(color: Color.brightAmber.opacity(0.45), radius: 28)
                            .overlay(
                                Text(verbatim: "V")
                                    .font(.system(size: 96, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                            )
                            .scaleEffect(isHoveringWelcomeIcon ? 1.02 : 1.0)
                            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHoveringWelcomeIcon)
                    }
                }
                .buttonStyle(.plain)
                .onHover { isHoveringWelcomeIcon = $0 }
                .customTooltip(
                    (vm.workspaceMode == .convert2DTo3D
                        ? String(localized: "Open 2D Photos...")
                        : String(localized: "Open Stereo Photo...")) + " (⌘O)",
                    offsetY: 150
                )
            }
            .padding(.top, 16)

            VStack(spacing: 34) {
                // サブタイトル
                Text(LocalizedStringKey("AI 19th-Century Stereoview Restoration & Spatial Rendering"))
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, .white.opacity(0.65)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)

                // クイックスタートガイドカード (Glass Recovery Card)
                HStack(alignment: .top, spacing: 0) {
                    GuideItemButton(
                        icon: "folder.badge.plus",
                        title: "Open Workspace Folder",
                        desc: "Stereo Restore / 2D to 3D",
                        color: .brightBlue
                    ) {
                        vm.openWorkspaceFolderPanel()
                    }

                    chevronSpacer

                    GuideItemButton(
                        icon: "sparkles",
                        title: "AI Spatial Alignment",
                        desc: "7-DoF Rectification & Tone",
                        color: .brightPink
                    ) {
                        selectInspectorTab(0)
                    }

                    chevronSpacer

                    GuideItemButton(
                        icon: "paintpalette.fill",
                        title: "Hand-Tint & Mount",
                        desc: "Archival Mount & Tinting",
                        color: Color(red: 0.20, green: 0.85, blue: 0.98)
                    ) {
                        selectInspectorTab(1)
                    }

                    chevronSpacer

                    GuideItemButton(
                        icon: "square.and.arrow.up.fill",
                        title: "Spatial Photo Export",
                        desc: "Spatial Photo & 3D Card",
                        color: .brightTeal
                    ) {
                        selectInspectorTab(4)
                    }
                }
                .padding(.vertical, 28)
                .padding(.horizontal, 24)
                .background(
                    ZStack {
                        // Glass background
                        RoundedRectangle(cornerRadius: 24)
                            .fill(.ultraThinMaterial)
                            .opacity(0.85)

                        // Subtle Metallic Border
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.45),
                                        Color.brightBlue.opacity(0.25),
                                        .white.opacity(0.10),
                                        Color.brightBlue.opacity(0.35)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    }
                )
                .shadow(color: .black.opacity(0.30), radius: 30, x: 0, y: 20)
            }
            .padding(.horizontal, 40)

            // 下部ステータス / サポート形式
            VStack(spacing: 6) {
                Text(verbatim: "Supports SBS, L/R Pairs, Apple Spatial (HEIC), MPO, Stereoview Cards")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.8))

                HStack(spacing: 8) {
                    Circle().fill(Color.palestineGreen).frame(width: 6, height: 6)
                    Text(verbatim: "READY FOR STEREO RESTORATION")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                        .kerning(1.0)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(
            GeometryReader { geo in
                ZStack {
                    heroBackgroundImage
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()

                    // Darkening overlay for contrast
                    Color.black.opacity(0.42)
                }
                .allowsHitTesting(false)
            }
            .ignoresSafeArea()
        )
        .clipped()
    }

    // MARK: - Guide Item Button Component (SplatStereo Inheritance)

    private struct GuideItemButton: View {
        let icon: String
        let title: String
        let desc: String
        let color: Color
        let action: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(color.opacity(isHovered ? 0.22 : 0.12))
                            .frame(width: 52, height: 52)
                            .scaleEffect(isHovered ? 1.08 : 1.0)
                            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)

                        Image(systemName: icon)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(color)
                            .shadow(color: color.opacity(isHovered ? 0.55 : 0.25), radius: isHovered ? 12 : 8, x: 0, y: isHovered ? 6 : 4)
                            .scaleEffect(isHovered ? 1.08 : 1.0)
                            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
                    }

                    VStack(spacing: 6) {
                        Text(LocalizedStringKey(title))
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text(LocalizedStringKey(desc))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(isHovered ? .white : .secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(height: 32)
                            .animation(.easeInOut(duration: 0.2), value: isHovered)
                    }
                }
                .frame(width: 140)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
            }
        }
    }

    // MARK: - Anti-Jitter 5-Tab Studio Inspector (完全統一型)

    private var inspectorPanel: some View {
        let sidePadding: CGFloat = 12
        let contentWidth = inspectorWidth - (sidePadding * 2)

        return VStack(alignment: .leading, spacing: 0) {
            // 上端固定ヘッダー：ソース表示 ＋ クイック操作
            inspectorHeader
                .padding(.top, 8)
                .padding(.horizontal, sidePadding)
                .padding(.bottom, 8)
                .frame(width: inspectorWidth, alignment: .leading)

            Divider().opacity(0.15)

            // 5-Tab Studio Navigation Bar (SplatStereo / DepthStereo / PanorStereo と完全同一レイアウト)
            inspectorTabBar(contentWidth: contentWidth)
                .padding(.horizontal, sidePadding)
                .padding(.vertical, 7)
                .frame(width: inspectorWidth, alignment: .leading)

            Divider().opacity(0.15)

            // 中央スクロール領域（下端フッター廃止により縦スペースを最大化）
            ScrollViewReader { proxy in
                ScrollView([.vertical], showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        switch vm.selectedInspectorTab {
                        case 0:
                            VStack(alignment: .leading, spacing: 14) {
                                statusSummarySection
                                if vm.workspaceMode == .convert2DTo3D || vm.isVideoLoaded {
                                    depth2D3DConversionSection
                                } else {
                                    basicRecipeDisclosure
                                    stereoWindowSection
                                }
                            }
                            .id("tab_top_0")
                        case 1:
                            stereoviewCardMountSection
                                .id("tab_top_1")
                        case 2:
                            vintageRestorationSection
                                .id("tab_top_2")
                        case 3:
                            colorizationSection
                                .id("tab_top_3")
                        case 4:
                            exportTabSection
                                .id("tab_top_4")
                        default:
                            EmptyView()
                        }
                    }
                    .frame(width: contentWidth, alignment: .topLeading)
                    .padding(.horizontal, sidePadding)
                    .padding(.vertical, 12)
                    .background(ScrollViewAntiJitterConfigurator())
                }
                .scrollIndicators(.never)
                .frame(width: inspectorWidth, alignment: .topLeading)
                .onChange(of: vm.selectedInspectorTab) { _, newTab in
                    withAnimation(.easeInOut(duration: 0.16)) {
                        proxy.scrollTo("tab_top_\(newTab)", anchor: .top)
                    }
                }
            }
        }
        .frame(width: inspectorWidth, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder
    private func inspectorTabBar(contentWidth: CGFloat) -> some View {
        let is2D3DMode = vm.workspaceMode == .convert2DTo3D || vm.isVideoLoaded
        let tab0Pending = !is2D3DMode && vm.hasPendingRecipeChanges

        HStack(spacing: 5) {
            tabButtonWithPendingBadge(
                titleKey: is2D3DMode ? "tab_2d3d_short" : "tab_basic_short",
                icon: is2D3DMode ? "cube.transparent.fill" : "slider.horizontal.3",
                darkColor: .darkPurple,
                brightColor: .brightPurple,
                shortcut: "⌥⌘1",
                isSelected: vm.selectedInspectorTab == 0,
                hasPendingChanges: tab0Pending
            ) {
                selectInspectorTab(0)
            }

            tabButtonWithPendingBadge(
                titleKey: "tab_mount_short",
                icon: "photo.artframe",
                darkColor: .darkBlue,
                brightColor: .brightBlue,
                shortcut: "⌥⌘2",
                isSelected: vm.selectedInspectorTab == 1,
                hasPendingChanges: vm.hasPendingCardMountChanges
            ) {
                selectInspectorTab(1)
            }

            tabButtonWithPendingBadge(
                titleKey: "tab_restore_short",
                icon: "sparkles",
                darkColor: .motionPink,
                brightColor: .brightPink,
                shortcut: "⌥⌘3",
                isSelected: vm.selectedInspectorTab == 2,
                hasPendingChanges: vm.hasPendingRestorationChanges
            ) {
                selectInspectorTab(2)
            }

            tabButtonWithPendingBadge(
                titleKey: "tab_colorize_short",
                icon: "paintpalette.fill",
                darkColor: Color(red: 0.0, green: 0.45, blue: 0.65),
                brightColor: Color(red: 0.20, green: 0.85, blue: 0.98),
                shortcut: "⌥⌘4",
                isSelected: vm.selectedInspectorTab == 3,
                hasPendingChanges: vm.hasPendingColorizationChanges
            ) {
                selectInspectorTab(3)
            }

            tabButtonWithPendingBadge(
                titleKey: "tab_export_short",
                icon: "square.and.arrow.up.fill",
                darkColor: .videoTeal,
                brightColor: .brightTeal,
                shortcut: "⌥⌘5",
                isSelected: vm.selectedInspectorTab == 4,
                hasPendingChanges: false
            ) {
                selectInspectorTab(4)
            }
        }
        .frame(width: contentWidth, alignment: .leading)
    }

    @ViewBuilder
    private func tabButtonWithPendingBadge(
        titleKey: String,
        icon: String,
        darkColor: Color,
        brightColor: Color,
        shortcut: String,
        isSelected: Bool,
        hasPendingChanges: Bool,
        action: @escaping () -> Void
    ) -> some View {
        InspectorTabButton(
            titleKey: titleKey,
            icon: icon,
            darkColor: darkColor,
            brightColor: brightColor,
            shortcut: shortcut,
            isSelected: isSelected,
            action: action
        )
        .overlay(alignment: .topTrailing) {
            if hasPendingChanges {
                Circle()
                    .fill(Color.brightAmber)
                    .frame(width: 7, height: 7)
                    .shadow(color: Color.brightAmber.opacity(0.9), radius: 3)
                    .padding(.top, 5)
                    .padding(.trailing, 5)
                    .allowsHitTesting(false)
            }
        }
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
                sectionHeader(title: vm.workspaceMode == .convert2DTo3D ? "2D → 3D STATUS" : "RESTORATION STATUS", color: .brightBlue)
                Circle()
                    .fill(statusBadgeColor)
                    .frame(width: 6, height: 6)
                Text(LocalizedStringKey(statusBadgeText))
                    .appSystemFont(size: 10, weight: .medium)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                if vm.isVideoLoaded {
                    Button {
                        vm.refreshVideoEngineAndReprocess()
                    } label: {
                        Label("Re-run", systemImage: "sparkles")
                            .appSystemFont(size: 10.5, weight: .semibold)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.brightPurple)
                    .disabled(vm.isProcessing || vm.isExportingVideo)
                } else if vm.workspaceMode == .convert2DTo3D {
                    Button {
                        if let url = vm.leftURL {
                            vm.loadSingleSBSImage(url: url, resetRestoration: false, interpretationOverride: .force2D)
                        }
                    } label: {
                        Label("Re-run", systemImage: "sparkles")
                            .appSystemFont(size: 10.5, weight: .semibold)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.brightPurple)
                    .disabled(!vm.hasLoadedImages || vm.isProcessing)
                    .customTooltip(String(localized: "Re-run AI 2D → 3D Conversion"))
                } else {
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
                        .customTooltip(String(localized: "Auto Align & Window") + " (⇧⌘A)")

                        Button {
                            vm.resetAlignment()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10.5))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(!vm.isAligned || vm.isProcessing)
                        .customTooltip(String(localized: "Reset Alignment"))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                telemetryRow(
                    label: "Output Size",
                    value: vm.isAligned ? "\(vm.croppedWidth) × \(vm.croppedHeight)" : (vm.imageWidth > 0 ? "\(vm.imageWidth) × \(vm.imageHeight)" : "—")
                )

                if vm.isVideoLoaded {
                    if let meta = vm.videoMetadata {
                        telemetryRow(
                            label: "Video Info",
                            value: String(format: "%.1fs · %.1f fps · %@", meta.durationSeconds, meta.nominalFPS, meta.hasAudio ? "Audio" : "No Audio"),
                            highlight: .brightBlue
                        )
                    }
                    telemetryRow(
                        label: "AI Depth Engine",
                        value: vm.videoActiveEngineLabel.isEmpty ? settings.preferredDepthEngine.shortLabel : vm.videoActiveEngineLabel,
                        highlight: .brightPurple
                    )
                    telemetryRow(
                        label: "Stereo Base",
                        value: String(format: "%.1f %%", vm.virtualDepthBasePercent),
                        highlight: .brightAmber
                    )
                } else if vm.workspaceMode == .convert2DTo3D {
                    telemetryRow(
                        label: "AI Depth Engine",
                        value: vm.lastDepthEngineLabel.isEmpty ? settings.preferredDepthEngine.shortLabel : vm.lastDepthEngineLabel,
                        highlight: .brightPurple
                    )
                    telemetryRow(
                        label: "Inference Time",
                        value: vm.lastDepthInferenceMs > 0 ? String(format: "%.0f ms", vm.lastDepthInferenceMs) : "—",
                        highlight: .brightTeal
                    )
                    telemetryRow(
                        label: "Stereo Base",
                        value: vm.isAligned ? String(format: "%.1f %%", vm.virtualDepthBasePercent) : "—",
                        highlight: vm.isAligned ? .brightAmber : .secondary
                    )
                } else {
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
                        value: {
                            guard vm.isAligned else { return "—" }
                            if vm.isStereoMismatchSuspected {
                                return String(localized: "⚠️ Mismatched (Invalid Stereo)")
                            }
                            if vm.isPseudoscopicSuspected {
                                return String(localized: vm.isSwapped ? "⚠️ Reversed (Auto-Swapped)" : "⚠️ Reversed (Pseudoscopic)")
                            }
                            return String(localized: vm.hasWindowViolationRisk ? "Detected (Edge)" : "Clear")
                        }(),
                        highlight: {
                            guard vm.isAligned else { return .secondary }
                            if vm.isStereoMismatchSuspected {
                                return .palestineRed
                            }
                            if vm.isPseudoscopicSuspected {
                                return vm.isSwapped ? .brightAmber : .palestineRed
                            }
                            return vm.hasWindowViolationRisk ? .brightAmber : .brightTeal
                        }()
                    )
                }

                if vm.workspaceMode == .stereoRestore && ((vm.salvageAdvisory?.shouldShowSalvagePrompt == true) || vm.stereoReconstructionMode.isDepthSynthesized) {
                    let isDepthMode = vm.stereoReconstructionMode.isDepthSynthesized
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: isDepthMode ? "sparkles" : "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(isDepthMode ? .brightTeal : .brightAmber)
                            
                            VStack(alignment: .leading, spacing: 3) {
                                if vm.stereoReconstructionMode == .fullFrame2DDepth {
                                    Text(String(localized: "2D → 3D Conversion Active"))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                    Text(String(localized: "Full-frame 2D photo converted to 3D using AI depth estimation."))
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.85))
                                } else if vm.stereoReconstructionMode.isSingleEyeDepth {
                                    Text(String(localized: "Single-Eye 3D Conversion Active"))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                    Text(String(format: String(localized: "Reconstructed from %@ image using AI depth estimation."), vm.stereoReconstructionMode.activeSide == .left ? String(localized: "Left") : String(localized: "Right")))
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.85))
                                } else if let advisory = vm.salvageAdvisory {
                                    Text(advisory.isMismatchSuspected ? String(localized: "Stereo Mismatch Detected") : (advisory.isUnilateralDamageSuspected ? String(localized: "Unilateral Damage Detected") : String(localized: "Excessive Stereo Baseline")))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                    
                                    if advisory.isMismatchSuspected {
                                        Text(String(localized: "Left and right images appear mismatched or from different shots."))
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.85))
                                    } else if advisory.isUnilateralDamageSuspected {
                                        let damagedText = advisory.damagedSide == .left ? String(localized: "Left image has severe damage/defects.") : String(localized: "Right image has severe damage/defects.")
                                        Text(damagedText)
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.85))
                                    } else if advisory.isExcessiveDisparity {
                                        Text(String(format: String(localized: "Max disparity is %.1f%%, exceeding comfortable viewing limit."), advisory.disparityPercent))
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.85))
                                    }
                                }
                            }
                        }

                        // ユーザー判断によるアクションボタン群
                        if vm.stereoReconstructionMode == .fullFrame2DDepth {
                            if let url = vm.leftURL {
                                Button(action: {
                                    vm.loadSingleSBSImage(url: url, interpretationOverride: .forceStereo)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "rectangle.split.2x1")
                                        Text(String(localized: "Treat as Stereo (SBS / Card)"))
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                }
                                .buttonStyle(.bordered)
                                .tint(.secondary)
                            }
                        } else if vm.stereoReconstructionMode.isSingleEyeDepth {
                            HStack(spacing: 8) {
                                Button(action: {
                                    vm.revertToOriginalStereoPair()
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.uturn.backward")
                                        Text(String(localized: "Revert to Original Pair"))
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                }
                                .buttonStyle(.bordered)
                                .tint(.secondary)

                                let otherSide: StereoSingleEyeSide = (vm.stereoReconstructionMode.activeSide == .left) ? .right : .left
                                Button(action: {
                                    vm.convertSingleEyeToDepth3D(side: otherSide)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                        Text(String(format: String(localized: "Use %@ Instead"), otherSide == .left ? String(localized: "Left") : String(localized: "Right")))
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.brightTeal.opacity(0.8))
                            }
                        } else if let advisory = vm.salvageAdvisory {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "Select source image for 3D conversion:"))
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundColor(.white.opacity(0.75))

                                HStack(spacing: 8) {
                                    SalvageConversionButton(
                                        side: .left,
                                        isRecommended: advisory.suggestedSide == .left,
                                        defectPercent: advisory.leftDefectPercent,
                                        sharpnessScore: advisory.leftSharpnessScore,
                                        action: { vm.convertSingleEyeToDepth3D(side: .left) }
                                    )

                                    SalvageConversionButton(
                                        side: .right,
                                        isRecommended: advisory.suggestedSide == .right,
                                        defectPercent: advisory.rightDefectPercent,
                                        sharpnessScore: advisory.rightSharpnessScore,
                                        action: { vm.convertSingleEyeToDepth3D(side: .right) }
                                    )
                                }
                            }
                        }

                        // 優先 AI 深度エンジンと設定へのクイック導線
                        HStack(spacing: 6) {
                            Image(systemName: "cpu")
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)
                            Text(settings.preferredDepthEngine.shortLabel)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                            Spacer()
                            if vm.stereoReconstructionMode == .fullFrame2DDepth, let url = vm.leftURL {
                                Button(String(localized: "Re-run")) {
                                    vm.loadSingleSBSImage(url: url, interpretationOverride: .force2D)
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.brightTeal)
                                .disabled(vm.isProcessing)
                            } else if let activeSide = vm.stereoReconstructionMode.activeSide {
                                Button(String(localized: "Re-run")) {
                                    vm.convertSingleEyeToDepth3D(side: activeSide)
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.brightTeal)
                                .disabled(vm.isProcessing)
                            }
                            SettingsLink {
                                Label(String(localized: "Model Settings…"), systemImage: "gearshape")
                                    .font(.system(size: 9.5, weight: .medium))
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.brightBlue)
                        }
                        .padding(.top, 2)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((isDepthMode ? Color.brightTeal : Color.brightAmber).opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder((isDepthMode ? Color.brightTeal : Color.brightAmber).opacity(0.45), lineWidth: 1)
                    )
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Section 2: Dedicated 2D → 3D Conversion Controls

    private var depth2D3DConversionSection: some View {
        InspectorAccordionSection(
            title: "2D → 3D CONVERSION",
            accentColor: .brightPurple,
            shortcutHint: "⌥⌘1",
            summary: !vm.is2D3DSectionExpanded ? String(format: "%.1f%%", vm.virtualDepthBasePercent) : nil,
            borderColor: Color.brightPurple.opacity(0.35),
            isExpanded: $vm.is2D3DSectionExpanded
        ) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("AI Depth Engine")
                            .appSystemFont(size: 11, weight: .semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        SettingsLink {
                            Label(String(localized: "Model Settings…"), systemImage: "gearshape")
                                .appSystemFont(size: 10, weight: .medium)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.brightBlue)
                    }

                    Picker("Preferred Engine", selection: $settings.depthModelEngineRaw) {
                        ForEach(StudioDepthEngine.allCases) { engine in
                            Text(engine.shortLabel).tag(engine.rawValue)
                        }
                    }
                    .labelsHidden()
                    .disabled(vm.isProcessing || vm.isBatchRunning)
                }

                Divider().opacity(0.3)

                // 3点セット: Stereo Base (%)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Stereo Base (%)")
                            .appSystemFont(size: 11.5, weight: .semibold)
                        Spacer()
                        ResetButton(isModified: abs(vm.virtualDepthBasePercent - 3.0) > 0.05) {
                            vm.virtualDepthBasePercent = 3.0
                        }
                        .disabled(vm.isProcessing)
                        NumericInput(
                            value: $vm.virtualDepthBasePercent,
                            range: 0.5...6.0,
                            format: "%.1f"
                        )
                        .disabled(vm.isProcessing)
                    }
                    Slider(value: $vm.virtualDepthBasePercent, in: 0.5...6.0)
                        .tint(.brightPurple)
                        .disabled(vm.isProcessing)
                }

                // 3点セット: Depth Offset / Pop-out (px)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Depth Offset / Pop-out (px)")
                            .appSystemFont(size: 11.5, weight: .semibold)
                        Spacer()
                        ResetButton(isModified: abs(vm.windowShiftX) > 0.05) {
                            vm.windowShiftX = 0.0
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
                        .id("2d3d-\(vm.currentSourceName)-\(vm.isAligned)")
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

                // 3点セット: Depth Gamma
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Depth Gamma")
                            .appSystemFont(size: 11.5, weight: .semibold)
                        Spacer()
                        ResetButton(isModified: abs(vm.depthGamma - 1.0) > 0.05) {
                            vm.depthGamma = 1.0
                        }
                        .disabled(vm.isProcessing)
                        NumericInput(
                            value: $vm.depthGamma,
                            range: 0.4...2.2,
                            format: "%.2f"
                        )
                        .disabled(vm.isProcessing)
                    }
                    Slider(value: $vm.depthGamma, in: 0.4...2.2)
                        .tint(.brightTeal)
                        .disabled(vm.isProcessing)
                }

                StereoDepthBudgetMeterView(
                    nearPercent: vm.nearParallaxPercent,
                    farPercent: vm.farParallaxPercent,
                    hasWindowViolation: false,
                    isAvailable: vm.isAligned || vm.isVideoLoaded,
                    compact: false
                )
                .padding(.top, 2)

                if vm.isVideoLoaded {
                    Divider().opacity(0.3)

                    // 既存3D動画サルベージ（SBS片眼抽出 / 2Dフル）
                    VStack(alignment: .leading, spacing: 5) {
                        Text(String(localized: "Video Source"))
                            .appSystemFont(size: 11, weight: .semibold)
                            .foregroundColor(.secondary)
                        Picker("Video Source", selection: $vm.videoInputStereoSource) {
                            ForEach(VideoInputStereoSource.allCases) { src in
                                Text(src.localizedLabel).tag(src)
                            }
                        }
                        .labelsHidden()
                        .disabled(vm.isExportingVideo)
                        .onChange(of: vm.videoInputStereoSource) { _, _ in
                            vm.seekVideoAndRender(to: vm.videoCurrentTimeSeconds, resetSession: true, progressiveWarmup: true)
                        }

                        if let meta = vm.videoMetadata, meta.isLikelySBS && vm.videoInputStereoSource == .full2D {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "Likely SBS 3D video detected. You can extract one eye to reconstruct comfortable 3D:"))
                                    .font(.system(size: 9.5))
                                    .foregroundColor(.brightAmber)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 6) {
                                    Button(String(localized: "SBS → Left Eye")) {
                                        vm.videoInputStereoSource = .sbsLeft
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .tint(.brightAmber)
                                    Button(String(localized: "SBS → Right Eye")) {
                                        vm.videoInputStereoSource = .sbsRight
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .tint(.brightAmber)
                                }
                            }
                            .padding(6)
                            .background(Color.brightAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    if !settings.preferredDepthEngine.isDepthPro2Engine {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.brightAmber)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "video_depth_pro2_recommended"))
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                                if StudioDepthEngine.depthPro2Base.isInstalled(preferredAppFolder: "ViewStereo") {
                                    Button(String(localized: "Switch to Depth Pro 2 Base")) {
                                        settings.preferredDepthEngine = .depthPro2Base
                                        vm.refreshVideoEngineAndReprocess()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .tint(.brightAmber)
                                } else {
                                    SettingsLink {
                                        Text(String(localized: "Model Settings…"))
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundColor(.brightBlue)
                                }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.brightAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    }

                    // 時間的平滑化 (EMA)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Temporal Smoothing")
                                .appSystemFont(size: 11.5, weight: .semibold)
                            Spacer()
                            ResetButton(isModified: abs(vm.videoTemporalSmoothing - 0.85) > 0.02) {
                                vm.videoTemporalSmoothing = 0.85
                            }
                            Text(String(format: "%.0f%%", vm.videoTemporalSmoothing * 100))
                                .appSystemFont(size: 11, design: .monospaced)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $vm.videoTemporalSmoothing, in: 0.0...1.0)
                            .tint(.brightBlue)
                            .disabled(vm.videoLockDepthRange)
                    }

                    Toggle(String(localized: "Lock Depth Range"), isOn: $vm.videoLockDepthRange)
                        .appSystemFont(size: 11)
                        .toggleStyle(.switch)
                        .controlSize(.mini)

                    if let meta = vm.videoMetadata, meta.isHDR {
                        Toggle(String(localized: "Preserve HDR (10-bit HLG)"), isOn: $vm.videoPreserveHDR)
                            .appSystemFont(size: 11)
                            .tint(.brightAmber)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }

                    Toggle(String(localized: "Auto Cut Detection"), isOn: $vm.videoAutoCutDetection)
                        .appSystemFont(size: 11)
                        .toggleStyle(.switch)
                        .controlSize(.mini)

                    Button {
                        vm.refreshVideoEngineAndReprocess()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "cube.transparent.fill")
                            Text(LocalizedStringKey("Re-run Video Frame"))
                        }
                    }
                    .buttonStyle(InspectorActionButtonStyle(accentColor: .brightPurple, isPending: false))
                    .disabled(vm.isProcessing || vm.isExportingVideo)
                } else {
                    Button {
                        if let url = vm.leftURL {
                            vm.loadSingleSBSImage(url: url, resetRestoration: false, interpretationOverride: .force2D)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "cube.transparent.fill")
                            Text(LocalizedStringKey("Re-run 2D → 3D Conversion"))
                        }
                    }
                    .buttonStyle(InspectorActionButtonStyle(accentColor: .brightPurple, isPending: false))
                    .disabled(!vm.hasLoadedImages || vm.isProcessing)
                }
            }
        }
    }

    // MARK: - Section 3: Stereo Window Fine-Tuning (Collapsible)

    private var stereoWindowSection: some View {
        InspectorAccordionSection(
            title: "STEREO WINDOW",
            accentColor: .brightAmber,
            shortcutHint: "⌥⌘2",
            summary: vm.isAligned ? String(format: String(localized: "Auto: %.1f px"), vm.autoOptimalShiftX) : nil,
            borderColor: Color.brightAmber.opacity(vm.isAligned ? 0.35 : 0.14),
            isExpanded: $vm.isWindowSectionExpanded
        ) {
            // 3点セット: スライダー + ResetButton + NumericInput
            VStack(alignment: .leading, spacing: 8) {
                if vm.stereoReconstructionMode.isDepthSynthesized {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Virtual Baseline (%)")
                                .appSystemFont(size: 12, weight: .semibold)
                            Spacer()
                            ResetButton(isModified: abs(vm.virtualDepthBasePercent - 3.0) > 0.05) {
                                vm.virtualDepthBasePercent = 3.0
                            }
                            NumericInput(
                                value: $vm.virtualDepthBasePercent,
                                range: 0.5...6.0,
                                format: "%.1f"
                            )
                        }
                        Slider(value: $vm.virtualDepthBasePercent, in: 0.5...6.0)
                            .tint(.brightTeal)

                        HStack {
                            Text("Depth Gamma")
                                .appSystemFont(size: 12, weight: .semibold)
                            Spacer()
                            ResetButton(isModified: abs(vm.depthGamma - 1.0) > 0.05) {
                                vm.depthGamma = 1.0
                            }
                            NumericInput(
                                value: $vm.depthGamma,
                                range: 0.4...2.2,
                                format: "%.2f"
                            )
                        }
                        Slider(value: $vm.depthGamma, in: 0.4...2.2)
                            .tint(.brightTeal)
                    }
                    .padding(.bottom, 4)
                    Divider().opacity(0.3)
                }

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

                StereoDepthBudgetMeterView(
                    nearPercent: vm.nearParallaxPercent,
                    farPercent: vm.farParallaxPercent,
                    hasWindowViolation: vm.hasWindowViolationRisk,
                    isAvailable: vm.isAligned,
                    compact: false,
                    onAutoOptimize: (!vm.stereoReconstructionMode.isDepthSynthesized && abs(vm.windowShiftX - vm.autoOptimalShiftX) > 0.5) ? {
                        vm.windowShiftX = vm.autoOptimalShiftX
                        vm.applyManualWindowShift()
                    } : nil
                )
                .padding(.top, 4)
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
            shortcutHint: "⌥⌘3",
            summary: !vm.isCardMountSectionExpanded ? String(localized: String.LocalizationValue(vm.cardMountPreset.rawValue)) : nil,
            borderColor: isCardActive ? Color.brightBlue.opacity(0.42) : Color.white.opacity(0.14),
            hasPendingChanges: vm.hasPendingCardMountChanges,
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

                Divider().opacity(0.3)

                Button {
                    vm.applyCardMountConfig()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(LocalizedStringKey("Apply Card Mount"))
                    }
                }
                .buttonStyle(InspectorActionButtonStyle(accentColor: .brightBlue, isPending: vm.hasPendingCardMountChanges))
                .disabled(!vm.hasLoadedImages || vm.isProcessing)
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
            shortcutHint: "⌥⌘4",
            summary: !vm.isRestorationSectionExpanded ? vintageRestorationSummaryText : nil,
            borderColor: (vm.hasActiveVintageRestoration || vm.effectiveRemoveUnilateralNoise) ? Color.brightPink.opacity(0.42) : Color.white.opacity(0.14),
            hasPendingChanges: vm.hasPendingRestorationChanges,
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
                        .customTooltip(String(localized: "Apply 1860s Albumen Preset"))

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
                        .customTooltip(String(localized: "Apply 1890s Hand-Tinted Preset"))

                        Button {
                            vm.resetVintageRestoration()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled((!vm.hasActiveVintageRestoration && !vm.isRestorationEnabled) || vm.isProcessing)
                        .customTooltip(String(localized: "Reset Vintage Restoration"))
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
                        }
                        .buttonStyle(InspectorActionButtonStyle(accentColor: .brightPink, isPending: vm.hasPendingRestorationChanges))
                        .disabled(!vm.hasLoadedImages || vm.isProcessing)
                    }

                    Toggle("Show Original (Before Restore)", isOn: $vm.isShowingBeforeRestoration)
                        .appSystemFont(size: 11.5)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.brightPink)
                        .disabled(!vm.hasLoadedImages || !vm.hasActiveVintageRestoration)

                    Toggle("Keep Restoration Recipe Across Images", isOn: $settings.keepRecipeAcrossImages)
                        .appSystemFont(size: 11.5)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.brightPink)
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
            shortcutHint: "⌥⌘5",
            summary: !vm.isColorizationSectionExpanded
                ? String(localized: String.LocalizationValue(vm.restorationColorizationMode.rawValue))
                : nil,
            borderColor: vm.hasActiveColorization ? accent.opacity(0.42) : Color.white.opacity(0.14),
            hasPendingChanges: vm.hasPendingColorizationChanges,
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
                    }
                    .buttonStyle(InspectorActionButtonStyle(accentColor: accent, isPending: vm.hasPendingColorizationChanges))
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
                    .customTooltip(String(localized: "Reset Colorization"))
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
            shortcutHint: "⌥⌘1",
            summary: !vm.isRecipeSectionExpanded ? recipeSummaryText : nil,
            borderColor: Color.white.opacity(0.14),
            hasPendingChanges: vm.hasPendingRecipeChanges,
            isExpanded: $vm.isRecipeSectionExpanded
        ) {
            VStack(alignment: .leading, spacing: 14) {
                // Card Detection & Input Interpretation
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(title: "STEREO CARD DETECTION", color: .brightPurple)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Input Mode (2D Auto-Detect)")
                            .appSystemFont(size: 11, weight: .semibold)
                            .foregroundColor(.secondary)
                        Picker("Input Mode", selection: $vm.inputInterpretation) {
                            ForEach(StereoInputInterpretation.allCases) { mode in
                                Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                            }
                        }
                        .labelsHidden()
                    }

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

                Divider().opacity(0.3)

                Button {
                    vm.applyRecipeAndRealign()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                        Text(LocalizedStringKey("Apply Recipe & Re-align"))
                    }
                }
                .buttonStyle(InspectorActionButtonStyle(accentColor: .brightPurple, isPending: vm.hasPendingRecipeChanges))
                .disabled(!vm.hasLoadedImages || vm.isProcessing)
            }
        }
    }

    // MARK: - Fixed Footer: Unified Export & Batch

    // MARK: - Section 5: Export & Batch Output Tab (⌘5 / ⌥⌘5)

    private var exportTabSection: some View {
        InspectorAccordionSection(
            title: "EXPORT & BATCH OUTPUT",
            accentColor: .brightTeal,
            shortcutHint: "⌥⌘5",
            summary: nil,
            borderColor: Color.brightTeal.opacity(0.35),
            isExpanded: .constant(true)
        ) {
            VStack(alignment: .leading, spacing: 12) {
            if vm.isVideoLoaded {
                HStack(spacing: 8) {
                    Text("Video Format")
                        .appSystemFont(size: 11.5, weight: .semibold)
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker("Video Format", selection: $vm.videoExportFormat) {
                        ForEach(StereoVideoExportFormat.allCases) { fmt in
                            Text(LocalizedStringKey(fmt.rawValue)).tag(fmt)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 230)
                    .disabled(vm.isExportingVideo)
                }

                if vm.isExportingVideo {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(vm.videoExportStatusText.isEmpty ? String(localized: "Exporting 3D Video...") : vm.videoExportStatusText)
                                .appSystemFont(size: 10.5, weight: .medium, design: .monospaced)
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(vm.videoExportProgress * 100))%")
                                .appSystemFont(size: 10.5, weight: .bold, design: .monospaced)
                                .foregroundColor(.brightTeal)
                        }
                        ProgressView(value: vm.videoExportProgress)
                            .tint(.brightTeal)
                    }

                    Button {
                        vm.cancelVideoExport()
                    } label: {
                        Label("Cancel Export", systemImage: "xmark.circle.fill")
                            .appSystemFont(size: 11.5, weight: .bold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.palestineRed)
                } else {
                    HStack(spacing: 6) {
                        Button {
                            vm.exportVideo(toQuickOutput: true)
                        } label: {
                            Label("Export 3D Video", systemImage: "film.stack.fill")
                                .appSystemFont(size: 11.5, weight: .bold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.palestineGreen)
                        .disabled(vm.isProcessing || vm.videoMetadata == nil)
                        .customTooltip(String(localized: "Quick Export to Output Folder") + " (⇧⌘E)")

                        Button {
                            vm.exportVideo(toQuickOutput: false)
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.bordered)
                        .disabled(vm.isProcessing || vm.videoMetadata == nil)
                        .customTooltip(String(localized: "Export Video As...") + " (⌘E)")

                        SpatialDeliveryMenuButton(
                            isEnabled: !vm.isProcessing && vm.videoMetadata != nil && !vm.isExportingVideo,
                            prepareItems: {
                                try await vm.prepareVideoForDelivery()
                            },
                            onStatusUpdate: { msg in
                                vm.statusMessage = msg
                            }
                        )
                    }
                }
            } else {
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

            // 共通出力先 + バッチ設定ポップオーバー
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10.5))
                    .foregroundColor(.brightTeal)

                Text(vm.batchOutputFolder?.lastPathComponent ?? (vm.browserStore.isVirtualSelection ? String(localized: "Select Output...") : "ViewStereo_Output"))
                    .appSystemFont(size: 10.5, design: .monospaced)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Button("Output...") {
                    vm.chooseBatchOutputFolderPanel()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(vm.isBatchRunning)

                Button {
                    isShowingBatchSettingsPopover.toggle()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(vm.batchWarningPolicy != .exportAll || vm.batchIncludeSubfolders || vm.batchSaveReport ? .brightTeal : .secondary)
                .customTooltip(String(localized: "Batch & Output Settings"))
                .popover(isPresented: $isShowingBatchSettingsPopover, arrowEdge: .leading) {
                    batchSettingsPopoverContent
                }
            }

            HStack(spacing: 6) {
                Button {
                    vm.quickExportToWorkspaceOutput()
                } label: {
                    Label("Quick Export", systemImage: "bolt.fill")
                        .appSystemFont(size: 11.5, weight: .bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(.palestineGreen)
                .disabled(!vm.hasLoadedImages || vm.isProcessing || vm.isBatchRunning)
                .customTooltip(String(localized: "Quick Export to Output Folder") + " (⇧⌘E)")

                if vm.isBatchRunning {
                    Button {
                        vm.cancelBatchProcessing()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle.fill")
                            .appSystemFont(size: 11.5, weight: .bold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.palestineRed)
                } else {
                    FooterBatchActionButton(vm: vm, store: vm.browserStore)
                }

                Button {
                    vm.exportImage()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .disabled(!vm.hasLoadedImages || vm.isProcessing || vm.isBatchRunning)
                .customTooltip(String(localized: "Export Image...") + " (⌘E)")

                SpatialDeliveryMenuButton(
                    isEnabled: (vm.hasLoadedImages || vm.browserStore.selectedBatchCount > 0 || vm.isVideoLoaded) && !vm.isProcessing && !vm.isBatchRunning && !vm.isExportingVideo,
                    prepareItems: {
                        if vm.isVideoLoaded {
                            return try await vm.prepareVideoForDelivery()
                        } else {
                            return try await vm.prepareSelectedLayoutForDelivery()
                        }
                    },
                    onStatusUpdate: { msg in
                        vm.statusMessage = msg
                    }
                )

                Button {
                    vm.exportAdjustmentReport()
                } label: {
                    Image(systemName: "doc.text")
                        .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .disabled(!vm.isAligned || vm.isBatchRunning)
                .customTooltip(String(localized: "Save Adjustment Report (.txt)"))
            }
            }
        }
        }
    }

    private var batchSettingsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey("Batch & Output Settings"))
                .appSystemFont(size: 12.5, weight: .bold)
                .foregroundColor(.white)

            Divider().opacity(0.3)

            if vm.workspaceMode == .stereoRestore {
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

                VStack(alignment: .leading, spacing: 4) {
                    Text("On Stereo Warning")
                        .appSystemFont(size: 11, weight: .semibold)
                        .foregroundColor(.secondary)
                    Picker("On Stereo Warning", selection: $vm.batchWarningPolicy) {
                        ForEach(BatchWarningPolicy.allCases) { policy in
                            Text(LocalizedStringKey(policy.rawValue)).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .disabled(vm.isBatchRunning)
                }
            }

            Toggle("Include Subfolders (Recursive)", isOn: $vm.batchIncludeSubfolders)
                .appSystemFont(size: 11.5)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.brightTeal)
                .disabled(vm.isBatchRunning)

            Toggle("Save Adjustment Report (.txt)", isOn: $vm.batchSaveReport)
                .appSystemFont(size: 11.5)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.brightTeal)
                .disabled(vm.isBatchRunning)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(Color(red: 0.12, green: 0.12, blue: 0.15))
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

    private func selectInspectorTab(_ index: Int) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if !vm.isShowingInspector {
                vm.isShowingInspector = true
            }
            vm.selectedInspectorTab = index
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

/// インスペクタ専用の高コントラスト・アクションボタンスタイル
/// パステルのベタ塗りによる白文字の埋没を完全に防止し、
/// ダーク背景（濃い透過トーン）＋アクセント枠線（1px）＋クッキリとした白太字で抜群の視認性を確保する
private struct InspectorActionButtonStyle: ButtonStyle {
    let accentColor: Color
    var isPending: Bool = false
    var fullWidth: Bool = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let activeColor = isPending ? Color.brightAmber : accentColor
        configuration.label
            .appSystemFont(size: 12, weight: .bold)
            .foregroundColor(
                isEnabled
                    ? (isPending ? Color.brightAmber : Color.white)
                    : Color.white.opacity(0.35)
            )
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 12 : 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isEnabled
                            ? (configuration.isPressed
                                ? activeColor.opacity(0.28)
                                : (isPending ? activeColor.opacity(0.20) : activeColor.opacity(0.14)))
                            : Color.white.opacity(0.04)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isEnabled
                            ? (isPending ? activeColor : activeColor.opacity(0.85))
                            : Color.white.opacity(0.12),
                        lineWidth: isPending ? 1.5 : 1.0
                    )
            )
            .contentShape(Rectangle())
    }
}

private struct InspectorAccordionSection<Content: View>: View {
    let title: String
    let accentColor: Color
    let shortcutHint: String
    let summary: String?
    let borderColor: Color
    var hasPendingChanges: Bool = false
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: 4, height: 16)

                Text(LocalizedStringKey(title))
                    .appSystemFont(size: 12.5, weight: .bold)
                    .foregroundColor(.white)
                    .tracking(0.3)
                    .lineLimit(1)

                if hasPendingChanges {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color.brightAmber)
                            .frame(width: 6, height: 6)
                        Text(LocalizedStringKey("Pending"))
                            .appSystemFont(size: 9.5, weight: .bold)
                            .foregroundColor(Color.brightAmber)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.brightAmber.opacity(0.18), in: Capsule())
                }

                Spacer(minLength: 6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accentColor.opacity(0.14))

            Divider()
                .background(accentColor.opacity(0.28))

            content()
                .padding(12)
        }
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: 1)
        )
    }
}

private struct SalvageConversionButton: View {
    let side: StereoSingleEyeSide
    let isRecommended: Bool
    let defectPercent: Double
    let sharpnessScore: Double
    let action: () -> Void

    var body: some View {
        if isRecommended {
            buttonContent
                .buttonStyle(.borderedProminent)
                .tint(.brightTeal)
        } else {
            buttonContent
                .buttonStyle(.bordered)
                .tint(.secondary)
        }
    }

    private var buttonContent: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    if isRecommended {
                        Image(systemName: "sparkles")
                    }
                    Text(buttonTitle)
                }
                .font(.system(size: 10.5, weight: isRecommended ? .bold : .medium))

                Text(String(format: String(localized: "Defect: %.1f%% | Sharp: %.0f"), defectPercent, sharpnessScore))
                    .font(.system(size: 8.5))
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
        }
    }

    private var buttonTitle: String {
        switch side {
        case .left:
            return isRecommended ? String(localized: "✨ Convert Left (Recommended)") : String(localized: "Convert Left")
        case .right:
            return isRecommended ? String(localized: "✨ Convert Right (Recommended)") : String(localized: "Convert Right")
        }
    }
}

private struct FooterBatchActionButton: View {
    @ObservedObject var vm: ViewStereoViewModel
    @ObservedObject var store: WorkspaceBrowserStore

    var body: some View {
        let batchCount = store.selectedBatchCount
        Button {
            vm.startBatchProcessingFromBrowser()
        } label: {
            Label(
                String(format: String(localized: "Batch (%lld)"), Int64(batchCount)),
                systemImage: "square.stack.3d.up.fill"
            )
            .appSystemFont(size: 11.5, weight: .bold)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .buttonStyle(.borderedProminent)
        .tint(.brightTeal)
        .disabled(batchCount == 0 || vm.isProcessing)
        .customTooltip(String(localized: "Batch Process Selection / Folder") + " (⇧⌘B)")
    }
}
