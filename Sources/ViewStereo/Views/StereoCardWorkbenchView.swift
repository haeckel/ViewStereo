import AppKit
import StereoStudioCore
import SwiftUI

// MARK: - StereoCardWorkbenchView

struct StereoCardWorkbenchView: View {
    @ObservedObject var vm: ViewStereoViewModel
    @StateObject private var session: StereoWorkbenchSession
    @State private var splitRatio: CGFloat = 0.5
    @Environment(\.dismiss) private var dismiss

    init(vm: ViewStereoViewModel) {
        self.vm = vm
        _session = StateObject(wrappedValue: StereoWorkbenchSession(vm: vm))
    }

    var body: some View {
        VStack(spacing: 0) {
            topWorkbenchBar
            Divider().opacity(0.3)

            HStack(spacing: 0) {
                // 左メイン領域（同時分割／Card／Window）
                workbenchCanvasArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.08, green: 0.08, blue: 0.09))

                Divider().opacity(0.35)

                // 右インスペクター（Anti-Jitter 固定幅）
                workbenchInspectorPanel
                    .frame(width: 325)
                    .background(Color(red: 0.11, green: 0.11, blue: 0.13))
            }

            Divider().opacity(0.3)
            bottomWorkbenchFooter
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 1180, minHeight: 760)
        .task {
            await session.loadCurrentVMState()
        }
        .onChange(of: vm.leftURL) { _, _ in
            Task {
                await session.loadCurrentVMState()
            }
        }
        .onDisappear {
            if session.isDirty {
                session.saveCurrentChangesToQueue()
            }
        }
        .overlay(hiddenShortcutButtons)
    }

    // MARK: - Top Bar

    private var topWorkbenchBar: some View {
        HStack(spacing: 12) {
            // ナビゲーション
            HStack(spacing: 4) {
                Button {
                    session.navigatePrevious()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .customTooltip(String(localized: "Previous Image") + " (⌘←)")

                Button {
                    session.navigateNext()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .customTooltip(String(localized: "Next Image") + " (⌘→)")
            }

            // アイテム位置とファイル名
            HStack(spacing: 6) {
                if session.totalItemCount > 0 {
                    Text("\(session.currentItemIndex + 1) / \(session.totalItemCount)")
                        .appSystemFont(size: 11.5, weight: .bold, design: .monospaced)
                        .foregroundColor(.brightAmber)
                }

                Text(session.currentFileName.isEmpty ? String(localized: "No Card Open") : session.currentFileName)
                    .appSystemFont(size: 12, weight: .semibold)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .leading)

                if session.isDirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .customTooltip(String(localized: "Unsaved Changes"))
                }
            }

            Divider().frame(height: 18)

            // 表示レイアウト切替（Split / Card / Window）
            Picker("Layout Mode", selection: $session.layoutMode) {
                ForEach(WorkbenchLayoutMode.allCases) { mode in
                    Label(LocalizedStringKey(mode.rawValue), systemImage: mode.iconName)
                        .tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 250)

            Spacer()

            // バックグラウンド保存中バッジ
            if session.saveQueue.pendingCount > 0 {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(String(format: String(localized: "Saving (%d in background)..."), session.saveQueue.pendingCount))
                        .appSystemFont(size: 10.5, weight: .medium)
                        .foregroundColor(.brightTeal)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.brightTeal.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            // 保存 & 次へ
            HStack(spacing: 8) {
                Button {
                    session.resetWindowShiftToAuto()
                } label: {
                    Text("Auto Window")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .customTooltip(String(localized: "Reset Window to Auto Optimal"))

                Button {
                    session.saveCurrentChangesToQueue()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Save")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
                .customTooltip(String(localized: "Save Changes to Folder Settings") + " (⌘S)")

                Button {
                    session.saveAndNext()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("Save & Next")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.brightAmber)
                .controlSize(.small)
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .customTooltip(String(localized: "Save & Open Next Image") + " (⌘→)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.28))
    }

    // MARK: - Main Canvas Area (Split / Card / Window)

    private var workbenchCanvasArea: some View {
        GeometryReader { geo in
            let totalH = geo.size.height
            switch session.layoutMode {
            case .cardOnly:
                cardCanvasView(size: geo.size)
            case .windowOnly:
                stereoWindowCanvasView(size: geo.size)
            case .split:
                let clampedRatio = min(0.75, max(0.25, splitRatio))
                let topH = totalH * clampedRatio
                let botH = totalH - topH - 6

                VStack(spacing: 0) {
                    cardCanvasView(size: CGSize(width: geo.size.width, height: topH))
                        .frame(height: topH)

                    // ドラッグ仕切りバー
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 6)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let nextH = topH + value.translation.height
                                    splitRatio = min(0.75, max(0.25, nextH / max(1.0, totalH)))
                                }
                        )

                    stereoWindowCanvasView(size: CGSize(width: geo.size.width, height: botH))
                        .frame(height: botH)
                }
            }
        }
    }

    // MARK: - Card & Mask Canvas

    private func cardCanvasView(size: CGSize) -> some View {
        ZStack {
            Color(white: session.previewStyle == .whiteCutout ? 0.94 : 0.10)

            if let img = session.renderedCardImage {
                let imgRect = fitRect(
                    contentSize: img.size,
                    in: size,
                    padding: 14
                )

                ZStack(alignment: .topLeading) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: imgRect.width, height: imgRect.height)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)

                    // 6本ガイド線 ＆ リアルタイム アーチ曲線
                    if session.toolMode == .adjustGuides {
                        guidesAndArchOverlayCanvas(size: imgRect.size)
                            .allowsHitTesting(false)
                    }

                    // SAM ポイントのオーバーレイ
                    if !session.points.isEmpty {
                        samPointsOverlayCanvas(size: imgRect.size)
                            .allowsHitTesting(false)
                    }

                    // ガイドドラッグ＆クリック用ジェスチャ
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: imgRect.width, height: imgRect.height)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { value in
                                    if session.toolMode == .adjustGuides {
                                        handleGuideDragChanged(value: value, in: imgRect.size)
                                    }
                                }
                                .onEnded { value in
                                    if session.toolMode == .adjustGuides {
                                        handleGuideDragEnded(in: imgRect.size, endLocation: value.location)
                                    } else {
                                        handleCanvasClick(at: value.location, in: imgRect.size)
                                    }
                                }
                        )
                }
                .frame(width: imgRect.width, height: imgRect.height)
                .position(x: imgRect.midX, y: imgRect.midY)
            } else if session.isLoadingCard || vm.isProcessing {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading & Analyzing Stereoview Card...")
                        .appSystemFont(size: 13, weight: .bold)
                        .foregroundColor(.white)
                    if !session.currentFileName.isEmpty {
                        Text(session.currentFileName)
                            .appSystemFont(size: 11, design: .monospaced)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(24)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            } else if session.isPreparingEmbedding {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Preparing SAM 2.1 Mask..."))
                        .appSystemFont(size: 11.5, weight: .semibold)
                        .foregroundColor(.brightBlue)
                }
                .padding(16)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("No Stereoview Card Mount Context")
                        .appSystemFont(size: 12.5, weight: .semibold)
                        .foregroundColor(.secondary)
                    Text("Double-click a stereoview card image in the file browser.")
                        .appSystemFont(size: 11)
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
        }
        .clipped()
    }

    // MARK: - Stereo Window Canvas

    private func stereoWindowCanvasView(size: CGSize) -> some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.06)

            if let img = session.renderedStereoImage {
                let imgRect = fitRect(contentSize: img.size, in: size, padding: 12)

                VStack(spacing: 6) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: imgRect.width, height: imgRect.height)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)

                    // ウィンドウ違反アラート
                    if session.hasWindowViolationRisk {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Stereo Window Violation Risk: Subject crosses frame edge")
                                .appSystemFont(size: 11, weight: .semibold)
                                .foregroundColor(.orange)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .position(x: size.width * 0.5, y: size.height * 0.5)
            } else if session.isLoadingCard || vm.isProcessing {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing & Rectifying Stereo Window...")
                        .appSystemFont(size: 11)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Stereo Window preview will appear here.")
                    .appSystemFont(size: 12)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .clipped()
    }

    // MARK: - Right Inspector Panel (Anti-Jitter)

    private var workbenchInspectorPanel: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                // Section 1: MASK & GUIDES
                maskAndGuidesSection

                Divider().opacity(0.3)

                // Section 2: STEREO WINDOW
                stereoWindowSection
            }
            .padding(14)
        }
    }

    private var maskAndGuidesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "rectangle.split.2x2")
                    .foregroundColor(.brightBlue)
                Text("1. MASK & GUIDES (G)")
                    .appSystemFont(size: 12, weight: .bold)
                Spacer()
            }

            // ツールモードピッカー
            Picker("Tool Mode", selection: $session.toolMode) {
                Label(String(localized: "Guides (G)"), systemImage: "rectangle.split.2x2")
                    .tag(MaskEditorToolMode.adjustGuides)
                Label(String(localized: "+ Photo"), systemImage: "plus.circle.fill")
                    .tag(MaskEditorToolMode.positivePoint)
                Label(String(localized: "- Mount"), systemImage: "minus.circle.fill")
                    .tag(MaskEditorToolMode.negativePoint)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: session.toolMode) { _, newMode in
                if newMode != .adjustGuides {
                    session.isDirectGuideMaskActive = false
                }
            }

            // ガイド枠から直接マスク生成
            Button {
                session.toggleDirectGuideMask()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: session.isDirectGuideMaskActive ? "checkmark.seal.fill" : "square.dashed.inset.filled")
                    Text("Generate from Guides")
                    Text("D")
                        .appSystemFont(size: 9.5, weight: .semibold, design: .monospaced)
                        .padding(.horizontal, 4)
                        .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(session.isDirectGuideMaskActive ? .green : .secondary)
            .controlSize(.small)

            Toggle(isOn: $session.lockEqualGuideWidth) {
                Text("Lock Equal Width")
                    .appSystemFont(size: 11)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            // 上アーチ
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Top Arch")
                        .appSystemFont(size: 11, weight: .medium)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", session.guideTopArchRatio * 100.0))
                        .appSystemFont(size: 10.5, design: .monospaced)
                }
                Slider(value: $session.guideTopArchRatio, in: 0.0...0.45, step: 0.005) { _ in
                    session.applyDirectGuideMask(recordUndo: false)
                }
                .tint(.brightBlue)
            }

            // 下角丸
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Bottom Round")
                        .appSystemFont(size: 11, weight: .medium)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", session.guideBotRoundRatio * 100.0))
                        .appSystemFont(size: 10.5, design: .monospaced)
                }
                Slider(value: $session.guideBotRoundRatio, in: 0.0...0.20, step: 0.005) { _ in
                    session.applyDirectGuideMask(recordUndo: false)
                }
                .tint(.brightBlue)
            }

            // プレビュースタイル切替
            HStack {
                Text("Preview:")
                    .appSystemFont(size: 11, weight: .medium)
                    .foregroundColor(.secondary)
                Spacer()
                Picker("Preview Style", selection: $session.previewStyle) {
                    Text("Overlay").tag(MaskEditorPreviewStyle.overlay)
                    Text("White Cutout").tag(MaskEditorPreviewStyle.whiteCutout)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
        }
    }

    private var stereoWindowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "eyeglasses")
                    .foregroundColor(.brightAmber)
                Text("2. STEREO WINDOW (←/→)")
                    .appSystemFont(size: 12, weight: .bold)
                Spacer()
            }

            // プレビュー方式 (Anaglyph / SBS)
            Picker("Stereo Preview", selection: $session.stereoPreviewMode) {
                Label(String(localized: "Anaglyph (V)"), systemImage: "eyeglasses")
                    .tag(WorkbenchStereoPreviewMode.anaglyph)
                Label(String(localized: "SBS"), systemImage: "rectangle.split.2x1")
                    .tag(WorkbenchStereoPreviewMode.sbs)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: session.stereoPreviewMode) { _, _ in
                session.updateStereoPreview()
            }

            // Horizontal Shift (px) 3点セット
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Horizontal Shift (px)")
                        .appSystemFont(size: 11.5, weight: .semibold)
                    Spacer()
                    ResetButton(isModified: abs(session.windowShiftX - session.autoOptimalShiftX) > 0.05) {
                        session.resetWindowShiftToAuto()
                    }
                    NumericInput(
                        value: $session.windowShiftX,
                        range: -300.0...300.0,
                        format: "%.1f"
                    ) {
                        session.isDirty = true
                        session.updateStereoPreview()
                    }
                }

                Slider(value: $session.windowShiftX, in: -300.0...300.0) { editing in
                    if !editing {
                        session.isDirty = true
                        session.updateStereoPreview()
                    }
                }
                .tint(.brightAmber)
                .onChange(of: session.windowShiftX) { _, _ in
                    session.isDirty = true
                    session.updateStereoPreview()
                }
            }

            // Swap L/R
            Toggle(isOn: $session.isSwapped) {
                Text("Swap Left / Right")
                    .appSystemFont(size: 11)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .onChange(of: session.isSwapped) { _, _ in
                session.isDirty = true
                session.updateStereoPreview()
            }

            // StereoDepthBudgetMeterView
            StereoDepthBudgetMeterView(
                nearPercent: session.nearParallaxPercent,
                farPercent: session.farParallaxPercent,
                hasWindowViolation: session.hasWindowViolationRisk,
                isAvailable: true,
                compact: false,
                onAutoOptimize: {
                    session.resetWindowShiftToAuto()
                }
            )
            .padding(.top, 4)
        }
    }

    // MARK: - Bottom Footer Bar

    private var bottomWorkbenchFooter: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $vm.autoExportTrainingDatasetOnMaskApply) {
                Text("Auto-export 3-class PNG")
                    .appSystemFont(size: 11)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            Button {
                chooseDatasetDirectory()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(URL(fileURLWithPath: vm.trainingDatasetDirectoryPath).lastPathComponent)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let banner = session.statusBanner {
                HStack(spacing: 4) {
                    Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(banner.isError ? .orange : .green)
                    Text(banner.text)
                        .appSystemFont(size: 10.5)
                        .foregroundColor(banner.isError ? .orange : .secondary)
                }
            }

            Spacer()

            Button {
                session.undoLastAction()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("z", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.24))
    }

    // MARK: - Shortcuts (Space, V, G, D, Arrows)

    private var hiddenShortcutButtons: some View {
        Group {
            // Space: 常にカード側の Overlay ↔ White Cutout 切替
            Button("Toggle Mask Preview Style") {
                withAnimation(.easeInOut(duration: 0.12)) {
                    session.previewStyle = (session.previewStyle == .overlay) ? .whiteCutout : .overlay
                }
                session.updateStereoPreview()
            }
            .keyboardShortcut(.space, modifiers: [])
            .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)

            // V: 常にウィンドウ側の Anaglyph ↔ SBS 切替
            Button("Toggle Stereo Mode") {
                session.stereoPreviewMode = (session.stereoPreviewMode == .anaglyph) ? .sbs : .anaglyph
                session.updateStereoPreview()
            }
            .keyboardShortcut("v", modifiers: [])
            .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)

            // G: ガイド調整 ↔ SAM 点補正切替
            Button("Toggle Guides") {
                session.toolMode = (session.toolMode == .adjustGuides) ? .positivePoint : .adjustGuides
            }
            .keyboardShortcut("g", modifiers: [])
            .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)

            // D: ガイドから直接マスク生成 (トグル)
            Button("Toggle Direct Guide Mask") {
                session.toggleDirectGuideMask()
            }
            .keyboardShortcut("d", modifiers: [])
            .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)

            // Left / Right Arrow: windowShiftX 微調整
            Button("Shift Left") {
                session.adjustWindowShift(delta: -1.0)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)

            Button("Shift Right") {
                session.adjustWindowShift(delta: 1.0)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)

            Button("Shift Left Fast") {
                session.adjustWindowShift(delta: -5.0)
            }
            .keyboardShortcut(.leftArrow, modifiers: .shift)
            .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)

            Button("Shift Right Fast") {
                session.adjustWindowShift(delta: 5.0)
            }
            .keyboardShortcut(.rightArrow, modifiers: .shift)
            .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)
        }
    }

    // MARK: - Canvas Guide Overlay & Geometry Helpers

    private func guidesAndArchOverlayCanvas(size: CGSize) -> some View {
        let w = size.width
        let h = size.height
        let boxL = session.baseAnchorBoxL
        let boxR = session.baseAnchorBoxR
        let archParams = StereoCardSegmenter.makeGuideArchParams(
            topRyRatio: session.guideTopArchRatio,
            botRyRatio: session.guideBotRoundRatio
        )

        return Canvas { context, _ in
            let splitMidX = ((boxL.normMaxX + boxR.normMinX) * 0.5) * w

            func drawGuide(from p0: CGPoint, to p1: CGPoint, color: Color) {
                var path = Path()
                path.move(to: p0)
                path.addLine(to: p1)
                context.stroke(path, with: .color(.black.opacity(0.55)), lineWidth: 2.8)
                context.stroke(path, with: .color(color), lineWidth: 1.4)
            }

            // 1. アーチ・角丸輪郭
            for box in [boxL, boxR] {
                let rect = CGRect(
                    x: box.normMinX * w,
                    y: box.normMinY * h,
                    width: max(4, (box.normMaxX - box.normMinX) * w),
                    height: max(4, (box.normMaxY - box.normMinY) * h)
                )
                let archPath = makeArchContourPath(in: rect, params: archParams)
                context.stroke(archPath, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
                context.stroke(archPath, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.4, dash: [6, 4]))
            }

            // 2. 水平ガイド
            let yTL = boxL.normMinY * h
            let yTR = boxR.normMinY * h
            drawGuide(from: CGPoint(x: 0, y: yTL), to: CGPoint(x: splitMidX, y: yTL), color: .cyan)
            drawGuide(from: CGPoint(x: splitMidX, y: yTR), to: CGPoint(x: w, y: yTR), color: .green)

            let yBL = boxL.normMaxY * h
            let yBR = boxR.normMaxY * h
            drawGuide(from: CGPoint(x: 0, y: yBL), to: CGPoint(x: splitMidX, y: yBL), color: .cyan)
            drawGuide(from: CGPoint(x: splitMidX, y: yBR), to: CGPoint(x: w, y: yBR), color: .green)

            // 3. 垂直ガイド
            drawGuide(from: CGPoint(x: boxL.normMinX * w, y: 0), to: CGPoint(x: boxL.normMinX * w, y: h), color: .cyan)
            drawGuide(from: CGPoint(x: boxL.normMaxX * w, y: 0), to: CGPoint(x: boxL.normMaxX * w, y: h), color: .cyan)
            drawGuide(from: CGPoint(x: boxR.normMinX * w, y: 0), to: CGPoint(x: boxR.normMinX * w, y: h), color: .green)
            drawGuide(from: CGPoint(x: boxR.normMaxX * w, y: 0), to: CGPoint(x: boxR.normMaxX * w, y: h), color: .green)
        }
        .frame(width: w, height: h)
    }

    private func makeArchContourPath(in rect: CGRect, params: StereoCardSegmenter.ArchShapeParams) -> Path {
        let x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
        let w = rect.width, h = rect.height
        let hasTop = (params.topRxRatio > 0.005 && params.topRyRatio > 0.005)
        let hasBot = (params.botRxRatio > 0.005 && params.botRyRatio > 0.005)
        let isFullArch = hasTop && params.topRxRatio >= 0.48

        let rxTop = hasTop ? min(w * 0.5, w * params.topRxRatio) : 0.0
        let ryTop = hasTop ? min(h * 0.5, h * params.topRyRatio) : 0.0
        let rxBot = hasBot ? min(w * 0.45, w * params.botRxRatio) : 0.0
        let ryBot = hasBot ? min(h * 0.45, h * params.botRyRatio) : 0.0

        var p = Path()
        let steps = 28

        if isFullArch {
            p.move(to: CGPoint(x: x0, y: y0 + ryTop))
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let a = (t * 2.0) - 1.0
                let px = x0 + t * w
                let py = y0 + ryTop * (1.0 - sqrt(max(0.0, 1.0 - a * a)))
                p.addLine(to: CGPoint(x: px, y: py))
            }
        } else if hasTop {
            p.move(to: CGPoint(x: x0, y: y0 + ryTop))
            for i in 0...14 {
                let theta = Double.pi * (1.0 - Double(i) / 14.0 * 0.5)
                let px = (x0 + rxTop) + rxTop * cos(theta)
                let py = (y0 + ryTop) - ryTop * sin(theta)
                p.addLine(to: CGPoint(x: px, y: py))
            }
            p.addLine(to: CGPoint(x: x1 - rxTop, y: y0))
            for i in 0...14 {
                let theta = Double.pi * 0.5 * (1.0 - Double(i) / 14.0)
                let px = (x1 - rxTop) + rxTop * cos(theta)
                let py = (y0 + ryTop) - ryTop * sin(theta)
                p.addLine(to: CGPoint(x: px, y: py))
            }
        } else {
            p.move(to: CGPoint(x: x0, y: y0))
            p.addLine(to: CGPoint(x: x1, y: y0))
        }

        if hasBot {
            p.addLine(to: CGPoint(x: x1, y: y1 - ryBot))
            for i in 0...14 {
                let theta = Double.pi * 0.5 * (Double(i) / 14.0)
                let px = (x1 - rxBot) + rxBot * cos(theta)
                let py = (y1 - ryBot) + ryBot * sin(theta)
                p.addLine(to: CGPoint(x: px, y: py))
            }
            p.addLine(to: CGPoint(x: x0 + rxBot, y: y1))
            for i in 0...14 {
                let theta = Double.pi * (0.5 + 0.5 * Double(i) / 14.0)
                let px = (x0 + rxBot) + rxBot * cos(theta)
                let py = (y1 - ryBot) + ryBot * sin(theta)
                p.addLine(to: CGPoint(x: px, y: py))
            }
        } else {
            p.addLine(to: CGPoint(x: x1, y: y1))
            p.addLine(to: CGPoint(x: x0, y: y1))
        }
        p.closeSubpath()
        return p
    }

    private func samPointsOverlayCanvas(size: CGSize) -> some View {
        let w = size.width, h = size.height
        return ZStack(alignment: .topLeading) {
            ForEach(session.points) { pt in
                Image(systemName: pt.isPositive ? "plus.circle.fill" : "minus.circle.fill")
                    .foregroundColor(pt.isPositive ? .green : .red)
                    .background(Color.black.opacity(0.6), in: Circle())
                    .font(.system(size: 13, weight: .bold))
                    .position(x: pt.normX * w, y: pt.normY * h)
            }
        }
        .frame(width: w, height: h)
    }

    private func handleCanvasClick(at pt: CGPoint, in size: CGSize) {
        let w = max(1.0, size.width)
        let h = max(1.0, size.height)
        let nx = Double(pt.x / w)
        let ny = Double(pt.y / h)
        let splitMidX = ((session.baseAnchorBoxL.normMaxX + session.baseAnchorBoxR.normMinX) * 0.5) * w
        let side: CardPrintSide = (pt.x <= splitMidX) ? .left : .right

        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            session.removeNearestPoint(normX: nx, normY: ny)
            return
        }

        let isPositive = (session.toolMode == .positivePoint)
        session.addPromptPoint(normX: nx, normY: ny, isPositive: isPositive, side: side)
    }

    private func handleGuideDragChanged(value: DragGesture.Value, in size: CGSize) {
        let w = max(1.0, size.width)
        let h = max(1.0, size.height)
        let nx = min(1.0, max(0.0, Double(value.location.x / w)))
        let ny = min(1.0, max(0.0, Double(value.location.y / h)))

        if session.draggingGuide == nil {
            session.draggingGuide = hitTestGuide(at: value.startLocation, size: size)
            session.pendingDragSnapshot = session.captureSnapshot()
        }

        guard let handle = session.draggingGuide else { return }
        let minW = 0.05, minH = 0.08
        let useWidthLock = session.lockEqualGuideWidth

        switch handle {
        case .top:
            let maxTop = min(session.baseAnchorBoxL.normMaxY, session.baseAnchorBoxR.normMaxY) - minH
            let clamped = min(max(0.0, maxTop), ny)
            session.baseAnchorBoxL.normMinY = clamped
            session.baseAnchorBoxR.normMinY = clamped
        case .bottom:
            let minBot = max(session.baseAnchorBoxL.normMinY, session.baseAnchorBoxR.normMinY) + minH
            let clamped = max(min(1.0, minBot), ny)
            session.baseAnchorBoxL.normMaxY = clamped
            session.baseAnchorBoxR.normMaxY = clamped
        case .leftOuter:
            if useWidthLock {
                let maxAllowedW = max(minW, min(session.baseAnchorBoxL.normMaxX, 1.0 - session.baseAnchorBoxR.normMinX))
                let clampedW = min(maxAllowedW, max(minW, session.baseAnchorBoxL.normMaxX - nx))
                session.baseAnchorBoxL.normMinX = session.baseAnchorBoxL.normMaxX - clampedW
                session.baseAnchorBoxR.normMaxX = session.baseAnchorBoxR.normMinX + clampedW
            } else {
                session.baseAnchorBoxL.normMinX = min(session.baseAnchorBoxL.normMaxX - minW, nx)
            }
        case .leftInner:
            let lo = session.baseAnchorBoxL.normMinX + minW
            let hi = session.baseAnchorBoxR.normMinX - minW
            session.baseAnchorBoxL.normMaxX = min(hi, max(lo, nx))
        case .rightInner:
            let lo = session.baseAnchorBoxL.normMaxX + minW
            let hi = session.baseAnchorBoxR.normMaxX - minW
            session.baseAnchorBoxR.normMinX = min(hi, max(lo, nx))
        case .rightOuter:
            if useWidthLock {
                let maxAllowedW = max(minW, min(session.baseAnchorBoxL.normMaxX, 1.0 - session.baseAnchorBoxR.normMinX))
                let clampedW = min(maxAllowedW, max(minW, nx - session.baseAnchorBoxR.normMinX))
                session.baseAnchorBoxR.normMaxX = session.baseAnchorBoxR.normMinX + clampedW
                session.baseAnchorBoxL.normMinX = session.baseAnchorBoxL.normMaxX - clampedW
            } else {
                session.baseAnchorBoxR.normMaxX = max(session.baseAnchorBoxR.normMinX + minW, nx)
            }
        }
        session.effectiveBoxL = session.baseAnchorBoxL
        session.effectiveBoxR = session.baseAnchorBoxR
    }

    private func handleGuideDragEnded(in size: CGSize, endLocation: CGPoint) {
        session.draggingGuide = nil
        if let snap = session.pendingDragSnapshot {
            if snap.baseAnchorBoxL != session.baseAnchorBoxL || snap.baseAnchorBoxR != session.baseAnchorBoxR {
                session.pushSnapshot(snap)
                session.isDirty = true
                if session.isDirectGuideMaskActive {
                    session.applyDirectGuideMask(recordUndo: false)
                } else {
                    session.rerunBothSidesInference()
                }
            }
            session.pendingDragSnapshot = nil
        }
    }

    private func hitTestGuide(at pt: CGPoint, size: CGSize) -> WorkbenchGuideHandle? {
        let w = size.width, h = size.height
        let tol: CGFloat = 14.0
        let boxL = session.baseAnchorBoxL
        let boxR = session.baseAnchorBoxR

        let yTopL = boxL.normMinY * h
        let yBotL = boxL.normMaxY * h
        let xLO = boxL.normMinX * w
        let xLI = boxL.normMaxX * w
        let xRI = boxR.normMinX * w
        let xRO = boxR.normMaxX * w

        if abs(pt.x - xLO) < tol { return .leftOuter }
        if abs(pt.x - xLI) < tol { return .leftInner }
        if abs(pt.x - xRI) < tol { return .rightInner }
        if abs(pt.x - xRO) < tol { return .rightOuter }
        if abs(pt.y - yTopL) < tol { return .top(side: .left) }
        if abs(pt.y - yBotL) < tol { return .bottom(side: .left) }
        return nil
    }

    private func fitRect(contentSize: CGSize, in bounds: CGSize, padding: CGFloat) -> CGRect {
        let availW = max(1, bounds.width - padding * 2)
        let availH = max(1, bounds.height - padding * 2)
        let scale = min(availW / max(1, contentSize.width), availH / max(1, contentSize.height))
        let drawW = contentSize.width * scale
        let drawH = contentSize.height * scale
        let x = (bounds.width - drawW) * 0.5
        let y = (bounds.height - drawH) * 0.5
        return CGRect(x: x, y: y, width: drawW, height: drawH)
    }

    private func chooseDatasetDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: vm.trainingDatasetDirectoryPath, isDirectory: true)
        panel.prompt = String(localized: "Select")
        if panel.runModal() == .OK, let url = panel.url {
            vm.trainingDatasetDirectoryPath = url.path
        }
    }
}
