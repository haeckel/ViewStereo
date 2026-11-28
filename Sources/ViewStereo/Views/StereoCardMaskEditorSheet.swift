import AppKit
import SwiftUI
import StereoStudioCore

// MARK: - Step 2 Phase 2-2: 1クリック正負点補正 UI + Photoshop風 6本ガイド調整 + 直接マスク生成

enum MaskEditorPreviewStyle: String, CaseIterable, Identifiable {
    case overlay = "Overlay"
    case whiteCutout = "White Cutout"

    var id: String { rawValue }
}

enum MaskEditorToolMode: String, CaseIterable, Identifiable {
    case positivePoint
    case negativePoint
    case adjustGuides

    var id: String { rawValue }
}

private enum GuideLineHandle: Equatable {
    case top(side: CardPrintSide)
    case bottom(side: CardPrintSide)
    case leftOuter
    case leftInner
    case rightInner
    case rightOuter

    var isHorizontal: Bool {
        switch self {
        case .top, .bottom: return true
        default: return false
        }
    }
}

private struct MaskEditorSnapshot {
    let points: [InteractivePromptPoint]
    let baseAnchorBoxL: InteractivePromptBox
    let baseAnchorBoxR: InteractivePromptBox
    let effectiveBoxL: InteractivePromptBox?
    let effectiveBoxR: InteractivePromptBox?
    let hasCustomBoxL: Bool
    let hasCustomBoxR: Bool
    let maskL: [Bool]
    let probL: [Float]
    let maskR: [Bool]
    let probR: [Float]
    let guideTopArchRatio: Double
    let guideBotRoundRatio: Double
    let isDirectGuideMaskActive: Bool
}

struct StereoCardMaskEditorSheet: View {
    @ObservedObject var vm: ViewStereoViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var activeSide: CardPrintSide = .left
    @State private var toolMode: MaskEditorToolMode = .adjustGuides
    @State private var useBoxAnchor: Bool = true
    @State private var previewStyle: MaskEditorPreviewStyle = .overlay

    @State private var points: [InteractivePromptPoint] = []
    @State private var embeddingCache: SAMImageEmbeddingCache? = nil
    @State private var isPreparingEmbedding: Bool = false
    @State private var isInferring: Bool = false
    @State private var isSavingOrApplying: Bool = false

    @State private var initialAnchorBoxL = InteractivePromptBox(normMinX: 0.04, normMinY: 0.08, normMaxX: 0.48, normMaxY: 0.92)
    @State private var initialAnchorBoxR = InteractivePromptBox(normMinX: 0.52, normMinY: 0.08, normMaxX: 0.96, normMaxY: 0.92)
    @State private var baseAnchorBoxL = InteractivePromptBox(normMinX: 0.04, normMinY: 0.08, normMaxX: 0.48, normMaxY: 0.92)
    @State private var baseAnchorBoxR = InteractivePromptBox(normMinX: 0.52, normMinY: 0.08, normMaxX: 0.96, normMaxY: 0.92)
    @State private var effectiveBoxL: InteractivePromptBox? = nil
    @State private var effectiveBoxR: InteractivePromptBox? = nil
    @State private var hasCustomBoxL: Bool = false
    @State private var hasCustomBoxR: Bool = false

    // Photoshop 風 6 本ガイド線状態
    @State private var hoveredGuide: GuideLineHandle? = nil
    @State private var draggingGuide: GuideLineHandle? = nil
    @State private var draggingGuideIndependent: Bool = false
    @State private var lockEqualGuideWidth: Bool = true
    @State private var pendingDragSnapshot: MaskEditorSnapshot? = nil

    // ガイド＋アーチ直接適用パラメータ
    @State private var initialTopArchRatio: Double = 0.0
    @State private var initialBotRoundRatio: Double = 0.0
    @State private var guideTopArchRatio: Double = 0.0
    @State private var guideBotRoundRatio: Double = 0.0
    @State private var isDirectGuideMaskActive: Bool = false
    @State private var isProgrammaticArchUpdate: Bool = false

    @State private var undoStack: [MaskEditorSnapshot] = []

    @State private var maskW: Int = 256
    @State private var maskH: Int = 128
    @State private var initialMaskL: [Bool] = []
    @State private var initialProbL: [Float] = []
    @State private var initialMaskR: [Bool] = []
    @State private var initialProbR: [Float] = []

    @State private var currentMaskL: [Bool] = []
    @State private var currentProbL: [Float] = []
    @State private var currentMaskR: [Bool] = []
    @State private var currentProbR: [Float] = []

    @State private var previewBaseRGB: [UInt8] = []
    @State private var previewBaseW: Int = 0
    @State private var previewBaseH: Int = 0
    @State private var renderedPreviewImage: NSImage? = nil

    @State private var lastElapsedMs: Double? = nil
    @State private var cacheStatusText: String = ""
    @State private var statusBanner: (text: String, isError: Bool)? = nil
    @State private var inferenceTask: Task<Void, Never>? = nil

    private var defaultSheetSize: CGSize {
        let visible = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 親ウィンドウのタイトルバー・シートマージン分のみ確保し、ほぼ画面いっぱいに表示
        let w = max(1100, floor(visible.width - 24))
        let h = max(760, floor(visible.height - 64))
        return CGSize(width: w, height: h)
    }

    var body: some View {
        VStack(spacing: 0) {
            topControlBar
            Divider().opacity(0.25)
            editorCanvasArea
            Divider().opacity(0.25)
            bottomFooterBar
        }
        .frame(
            minWidth: 980,
            idealWidth: defaultSheetSize.width,
            maxWidth: .infinity,
            minHeight: 700,
            idealHeight: defaultSheetSize.height,
            maxHeight: .infinity
        )
        .background(SheetWindowSizer(targetSize: defaultSheetSize))
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await initializeEditorSession()
        }
        .onDisappear {
            inferenceTask?.cancel()
            NSCursor.arrow.set()
        }
    }

    // MARK: - Top Control Bar

    private var topControlBar: some View {
        VStack(spacing: 8) {
            // 1段目: ガイド調整・直接マスク生成を主役にしたメインバー
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars.inverse")
                        .foregroundColor(.brightBlue)
                    Text("1-Click Mask Editor (SAM 2.1)")
                        .appSystemFont(size: 13.5, weight: .bold)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Divider().frame(height: 18)

                // ツールモード（ガイド調整を先頭に配置）
                Picker("Prompt Mode", selection: $toolMode) {
                    Label(String(localized: "Guides (G)"), systemImage: "rectangle.split.2x2")
                        .tag(MaskEditorToolMode.adjustGuides)
                    Label(String(localized: "+ Photo"), systemImage: "plus.circle.fill")
                        .tag(MaskEditorToolMode.positivePoint)
                    Label(String(localized: "- Mount"), systemImage: "minus.circle.fill")
                        .tag(MaskEditorToolMode.negativePoint)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 295)

                Text(toolMode == .adjustGuides
                     ? String(localized: "Outer: sync W · Inner: move · ⌥: single")
                     : String(localized: "⌥+Click: Invert"))
                    .appSystemFont(size: 10.5)
                    .foregroundColor(toolMode == .adjustGuides ? .brightBlue : .secondary)
                    .lineLimit(1)

                Spacer()

                // ガイド枠から直接マスク生成（Dキーでも実行）
                Button {
                    applyDirectGuideMask(recordUndo: true)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isDirectGuideMaskActive ? "checkmark.seal.fill" : "square.dashed.inset.filled")
                        Text("Generate Mask from Guides")
                        Text("D")
                            .appSystemFont(size: 9.5, weight: .semibold, design: .monospaced)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isDirectGuideMaskActive ? .green : .brightBlue)
                .controlSize(.small)
                .keyboardShortcut("d", modifiers: [])
                .disabled(isPreparingEmbedding || isSavingOrApplying)

                // Space キー対応の瞬時切替ボタン（半透明マスク重畳 ↔ 純白背景切り抜きプレビュー）
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        previewStyle = (previewStyle == .overlay) ? .whiteCutout : .overlay
                    }
                    rebuildRenderedPreview()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: previewStyle == .overlay ? "square.on.square" : "scissors")
                        Text(previewStyle == .overlay
                             ? String(localized: "Overlay Mask")
                             : String(localized: "White Cutout"))
                        Text("Space")
                            .appSystemFont(size: 9.5, weight: .semibold, design: .monospaced)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.space, modifiers: [])
            }

            // 2段目: モード別スライダー・補助コントロール
            HStack(spacing: 12) {
                if toolMode == .adjustGuides {
                    HStack(spacing: 6) {
                        Text("Top Arch")
                            .appSystemFont(size: 11, weight: .semibold)
                            .foregroundColor(.secondary)
                        Slider(
                            value: $guideTopArchRatio,
                            in: 0.0...0.45,
                            step: 0.005,
                            onEditingChanged: { editing in
                                if editing {
                                    pushCurrentSnapshot()
                                }
                            }
                        )
                        .frame(width: 180)
                        .controlSize(.mini)
                        .tint(.brightBlue)
                        .onChange(of: guideTopArchRatio) { _, _ in
                            guard !isProgrammaticArchUpdate else { return }
                            applyDirectGuideMask(recordUndo: false)
                        }
                        Text(String(format: "%.0f%%", guideTopArchRatio * 100.0))
                            .appSystemFont(size: 10.5, design: .monospaced)
                            .frame(width: 34, alignment: .trailing)
                    }

                    HStack(spacing: 6) {
                        Text("Bottom Round")
                            .appSystemFont(size: 11, weight: .semibold)
                            .foregroundColor(.secondary)
                        Slider(
                            value: $guideBotRoundRatio,
                            in: 0.0...0.20,
                            step: 0.005,
                            onEditingChanged: { editing in
                                if editing {
                                    pushCurrentSnapshot()
                                }
                            }
                        )
                        .frame(width: 130)
                        .controlSize(.mini)
                        .tint(.brightBlue)
                        .onChange(of: guideBotRoundRatio) { _, _ in
                            guard !isProgrammaticArchUpdate else { return }
                            applyDirectGuideMask(recordUndo: false)
                        }
                        Text(String(format: "%.0f%%", guideBotRoundRatio * 100.0))
                            .appSystemFont(size: 10.5, design: .monospaced)
                            .frame(width: 34, alignment: .trailing)
                    }

                    Divider().frame(height: 16)
                } else {
                    // 点補正モード時のみ左右プリント切替とBoxアンカー維持を表示
                    Picker("Target Side", selection: $activeSide) {
                        Text(LocalizedStringKey("Left Print (1)")).tag(CardPrintSide.left)
                        Text(LocalizedStringKey("Right Print (2)")).tag(CardPrintSide.right)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)

                    Toggle(isOn: $useBoxAnchor) {
                        Text("Keep Box Anchor (Auto-Expand)")
                            .appSystemFont(size: 11.5)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(.brightBlue)
                    .disabled(isDirectGuideMaskActive)
                    .onChange(of: useBoxAnchor) { _, _ in
                        guard !isDirectGuideMaskActive else { return }
                        let needL = hasCustomBoxL || points.contains { $0.side == .left }
                        let needR = hasCustomBoxR || points.contains { $0.side == .right }
                        if needL && needR {
                            rerunBothSidesInference()
                        } else if needL {
                            rerunInference(for: .left, forceIfNoPoints: hasCustomBoxL)
                        } else if needR {
                            rerunInference(for: .right, forceIfNoPoints: hasCustomBoxR)
                        }
                    }
                }

                if toolMode == .adjustGuides {
                    Toggle(isOn: $lockEqualGuideWidth) {
                        Text("Lock Equal Width")
                            .appSystemFont(size: 11)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(.brightBlue)
                }

                Spacer()

                // ショートカット用非表示ボタン
                Button("Select Left") { activeSide = .left }
                    .keyboardShortcut("1", modifiers: [])
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .allowsHitTesting(false)
                Button("Select Right") { activeSide = .right }
                    .keyboardShortcut("2", modifiers: [])
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .allowsHitTesting(false)
                Button("Toggle Guides G") {
                    toolMode = (toolMode == .adjustGuides) ? .positivePoint : .adjustGuides
                }
                .keyboardShortcut("g", modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)
                Button("Toggle Guides B") {
                    toolMode = (toolMode == .adjustGuides) ? .positivePoint : .adjustGuides
                }
                .keyboardShortcut("b", modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)

                Button {
                    undoLastAction()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("z", modifiers: .command)
                .disabled(undoStack.isEmpty || isInferring || isPreparingEmbedding)

                Button {
                    resetSidePoints(activeSide)
                } label: {
                    Text(activeSide == .left ? String(localized: "Reset Left") : String(localized: "Reset Right"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!(points.contains { $0.side == activeSide } || (activeSide == .left ? hasCustomBoxL : hasCustomBoxR) || isDirectGuideMaskActive) || isInferring || isPreparingEmbedding)

                Button {
                    resetAllToInitial()
                } label: {
                    Text("Reset All")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled((points.isEmpty && !hasCustomBoxL && !hasCustomBoxR && !isDirectGuideMaskActive && undoStack.isEmpty) || isInferring || isPreparingEmbedding)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.25))
    }

    // MARK: - Interactive Canvas Area

    private var editorCanvasArea: some View {
        ZStack {
            Color(white: previewStyle == .whiteCutout ? 0.94 : 0.10)

            GeometryReader { geo in
                if previewBaseW > 0, previewBaseH > 0 {
                    let imgRect = fitRect(
                        contentSize: CGSize(width: previewBaseW, height: previewBaseH),
                        in: geo.size,
                        padding: 18
                    )
                    let localRect = CGRect(origin: .zero, size: imgRect.size)

                    // 画像・オーバーレイ・ガイド線・ジェスチャをすべて画像ローカル座標系 (0...imgRect.width, 0...imgRect.height) に統一
                    ZStack(alignment: .topLeading) {
                        if let nsImg = renderedPreviewImage {
                            Image(nsImage: nsImg)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: imgRect.width, height: imgRect.height)
                                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                        }

                        // 通常モード時の薄い Box アンカー枠
                        if toolMode != .adjustGuides && previewStyle == .overlay && useBoxAnchor {
                            boxOverlayView(
                                box: effectiveBoxL ?? baseAnchorBoxL,
                                color: .cyan,
                                isActive: activeSide == .left,
                                in: localRect
                            )
                            boxOverlayView(
                                box: effectiveBoxR ?? baseAnchorBoxR,
                                color: .green,
                                isActive: activeSide == .right,
                                in: localRect
                            )
                        }

                        // Photoshop 風 6本ガイド線 ＋ リアルタイム アーチ曲線オーバーレイ
                        if toolMode == .adjustGuides {
                            guidesAndArchOverlayCanvas(size: imgRect.size)
                                .allowsHitTesting(false)
                        }

                        // 透明クリック＆ドラッグヒット領域（画像ローカル座標系）
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: imgRect.width, height: imgRect.height)
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                    .onChanged { value in
                                        guard !isPreparingEmbedding, !isSavingOrApplying else { return }
                                        if toolMode == .adjustGuides {
                                            handleGuideDragChanged(value: value, in: imgRect.size)
                                        }
                                    }
                                    .onEnded { value in
                                        guard !isPreparingEmbedding, !isSavingOrApplying else { return }
                                        if toolMode == .adjustGuides {
                                            handleGuideDragEnded(in: imgRect.size, endLocation: value.location)
                                        } else {
                                            let dist = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                                            if dist < 12.0 {
                                                let nx = value.location.x / max(1.0, imgRect.width)
                                                let ny = value.location.y / max(1.0, imgRect.height)
                                                handleCanvasTap(normX: nx, normY: ny)
                                            }
                                        }
                                    }
                            )

                        // 打点マーカー表示（コンテキストメニューを確実に受け取るため最前面）
                        if !isDirectGuideMaskActive {
                            ForEach(points) { pt in
                                let px = pt.normX * imgRect.width
                                let py = pt.normY * imgRect.height
                                pointMarkerView(pt)
                                    .position(x: px, y: py)
                                    .contextMenu {
                                        Button("Remove Point", role: .destructive) {
                                            removePoint(pt)
                                        }
                                    }
                            }
                        }
                    }
                    .frame(width: imgRect.width, height: imgRect.height)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if draggingGuide != nil {
                                updateCursor(for: draggingGuide)
                            } else if toolMode == .adjustGuides {
                                let hit = hitTestGuide(at: location, size: imgRect.size)
                                hoveredGuide = hit
                                updateCursor(for: hit)
                            } else {
                                hoveredGuide = nil
                                NSCursor.crosshair.set()
                            }
                        case .ended:
                            hoveredGuide = nil
                            if draggingGuide == nil {
                                NSCursor.arrow.set()
                            }
                        }
                    }
                    .position(x: imgRect.midX, y: imgRect.midY)
                }
            }

            if isPreparingEmbedding || isSavingOrApplying {
                VStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(1.05)
                    Text(isSavingOrApplying
                         ? String(localized: "Refining GPU mask & updating card...")
                         : String(localized: "Preparing SAM 2.1 image embedding..."))
                        .appSystemFont(size: 12, weight: .semibold)
                        .foregroundColor(.white)
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Photoshop-Style 6 Guides + Arch Preview Canvas

    private func guidesAndArchOverlayCanvas(size: CGSize) -> some View {
        let w = size.width
        let h = size.height
        let boxL = baseAnchorBoxL
        let boxR = baseAnchorBoxR
        let archParams = StereoCardSegmenter.makeGuideArchParams(
            topRyRatio: guideTopArchRatio,
            botRyRatio: guideBotRoundRatio
        )
        let activeHandle = draggingGuide ?? hoveredGuide

        return Canvas { context, _ in
            let splitMidX = ((boxL.normMaxX + boxR.normMinX) * 0.5) * w

            func drawGuideLine(from p0: CGPoint, to p1: CGPoint, color: Color, isHighlighted: Bool) {
                var path = Path()
                path.move(to: p0)
                path.addLine(to: p1)
                context.stroke(path, with: .color(.black.opacity(0.55)), lineWidth: isHighlighted ? 4.2 : 2.8)
                context.stroke(path, with: .color(isHighlighted ? .yellow : color), lineWidth: isHighlighted ? 2.4 : 1.4)
            }

            // 1. リアルタイム アーチ・角丸輪郭プレビュー
            for (box, strokeCol) in [(boxL, Color.white.opacity(0.92)), (boxR, Color.white.opacity(0.92))] {
                let rect = CGRect(
                    x: box.normMinX * w,
                    y: box.normMinY * h,
                    width: max(4, (box.normMaxX - box.normMinX) * w),
                    height: max(4, (box.normMaxY - box.normMinY) * h)
                )
                let archPath = makeArchContourPath(in: rect, params: archParams)
                context.stroke(archPath, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: 2.8, dash: [6, 4]))
                context.stroke(archPath, with: .color(strokeCol), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }

            // 2. 水平ガイド（上端）
            let topSynced = abs(boxL.normMinY - boxR.normMinY) < 0.002
            let topHL = (activeHandle == .top(side: .left) || activeHandle == .top(side: .right))
            if topSynced {
                let y = boxL.normMinY * h
                drawGuideLine(from: CGPoint(x: 0, y: y), to: CGPoint(x: w, y: y), color: Color(red: 0.25, green: 0.85, blue: 1.0), isHighlighted: topHL)
            } else {
                let yL = boxL.normMinY * h
                let yR = boxR.normMinY * h
                drawGuideLine(from: CGPoint(x: 0, y: yL), to: CGPoint(x: splitMidX, y: yL), color: .cyan, isHighlighted: activeHandle == .top(side: .left))
                drawGuideLine(from: CGPoint(x: splitMidX, y: yR), to: CGPoint(x: w, y: yR), color: .green, isHighlighted: activeHandle == .top(side: .right))
            }

            // 3. 水平ガイド（下端）
            let botSynced = abs(boxL.normMaxY - boxR.normMaxY) < 0.002
            let botHL = (activeHandle == .bottom(side: .left) || activeHandle == .bottom(side: .right))
            if botSynced {
                let y = boxL.normMaxY * h
                drawGuideLine(from: CGPoint(x: 0, y: y), to: CGPoint(x: w, y: y), color: Color(red: 0.25, green: 0.85, blue: 1.0), isHighlighted: botHL)
            } else {
                let yL = boxL.normMaxY * h
                let yR = boxR.normMaxY * h
                drawGuideLine(from: CGPoint(x: 0, y: yL), to: CGPoint(x: splitMidX, y: yL), color: .cyan, isHighlighted: activeHandle == .bottom(side: .left))
                drawGuideLine(from: CGPoint(x: splitMidX, y: yR), to: CGPoint(x: w, y: yR), color: .green, isHighlighted: activeHandle == .bottom(side: .right))
            }

            // 4. 垂直ガイド 4 本（左外・左内・右内・右外）
            let xLO = boxL.normMinX * w
            let xLI = boxL.normMaxX * w
            let xRI = boxR.normMinX * w
            let xRO = boxR.normMaxX * w
            drawGuideLine(from: CGPoint(x: xLO, y: 0), to: CGPoint(x: xLO, y: h), color: .cyan, isHighlighted: activeHandle == .leftOuter)
            drawGuideLine(from: CGPoint(x: xLI, y: 0), to: CGPoint(x: xLI, y: h), color: .cyan, isHighlighted: activeHandle == .leftInner)
            drawGuideLine(from: CGPoint(x: xRI, y: 0), to: CGPoint(x: xRI, y: h), color: .green, isHighlighted: activeHandle == .rightInner)
            drawGuideLine(from: CGPoint(x: xRO, y: 0), to: CGPoint(x: xRO, y: h), color: .green, isHighlighted: activeHandle == .rightOuter)
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

    private func hitTestGuide(at point: CGPoint, size: CGSize) -> GuideLineHandle? {
        let w = max(1.0, size.width)
        let h = max(1.0, size.height)
        let hitTol: CGFloat = 8.0
        let splitMidX = ((baseAnchorBoxL.normMaxX + baseAnchorBoxR.normMinX) * 0.5) * w
        let sideAtX: CardPrintSide = (point.x <= splitMidX) ? .left : .right

        let topY = ((sideAtX == .left) ? baseAnchorBoxL.normMinY : baseAnchorBoxR.normMinY) * h
        let botY = ((sideAtX == .left) ? baseAnchorBoxL.normMaxY : baseAnchorBoxR.normMaxY) * h

        let candidates: [(GuideLineHandle, CGFloat)] = [
            (.top(side: sideAtX), abs(point.y - topY)),
            (.bottom(side: sideAtX), abs(point.y - botY)),
            (.leftOuter, abs(point.x - baseAnchorBoxL.normMinX * w)),
            (.leftInner, abs(point.x - baseAnchorBoxL.normMaxX * w)),
            (.rightInner, abs(point.x - baseAnchorBoxR.normMinX * w)),
            (.rightOuter, abs(point.x - baseAnchorBoxR.normMaxX * w)),
        ]

        guard let best = candidates.min(by: { $0.1 < $1.1 }), best.1 <= hitTol else {
            return nil
        }
        return best.0
    }

    private func updateCursor(for handle: GuideLineHandle?) {
        if let h = handle {
            if h.isHorizontal {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.resizeLeftRight.set()
            }
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func handleGuideDragChanged(value: DragGesture.Value, in size: CGSize) {
        let w = max(1.0, size.width)
        let h = max(1.0, size.height)

        if draggingGuide == nil {
            guard let hit = hitTestGuide(at: value.startLocation, size: size) else { return }
            draggingGuide = hit
            draggingGuideIndependent = NSEvent.modifierFlags.contains(.option)
            pendingDragSnapshot = captureSnapshot()
            updateCursor(for: hit)
        }

        guard let handle = draggingGuide else { return }
        let nx = min(1.0, max(0.0, Double(value.location.x / w)))
        let ny = min(1.0, max(0.0, Double(value.location.y / h)))
        let minW = 0.05
        let minH = 0.08
        let useWidthLock = lockEqualGuideWidth && !draggingGuideIndependent

        switch handle {
        case .top(let side):
            if !draggingGuideIndependent {
                let maxTop = min(baseAnchorBoxL.normMaxY, baseAnchorBoxR.normMaxY) - minH
                let clamped = min(max(0.0, maxTop), ny)
                baseAnchorBoxL.normMinY = clamped
                baseAnchorBoxR.normMinY = clamped
            } else if side == .left {
                baseAnchorBoxL.normMinY = min(baseAnchorBoxL.normMaxY - minH, ny)
            } else {
                baseAnchorBoxR.normMinY = min(baseAnchorBoxR.normMaxY - minH, ny)
            }
        case .bottom(let side):
            if !draggingGuideIndependent {
                let minBot = max(baseAnchorBoxL.normMinY, baseAnchorBoxR.normMinY) + minH
                let clamped = max(min(1.0, minBot), ny)
                baseAnchorBoxL.normMaxY = clamped
                baseAnchorBoxR.normMaxY = clamped
            } else if side == .left {
                baseAnchorBoxL.normMaxY = max(baseAnchorBoxL.normMinY + minH, ny)
            } else {
                baseAnchorBoxR.normMaxY = max(baseAnchorBoxR.normMinY + minH, ny)
            }
        case .leftOuter:
            if useWidthLock {
                let maxAllowedW = max(minW, min(baseAnchorBoxL.normMaxX, 1.0 - baseAnchorBoxR.normMinX))
                let clampedW = min(maxAllowedW, max(minW, baseAnchorBoxL.normMaxX - nx))
                baseAnchorBoxL.normMinX = baseAnchorBoxL.normMaxX - clampedW
                baseAnchorBoxR.normMaxX = baseAnchorBoxR.normMinX + clampedW
            } else {
                baseAnchorBoxL.normMinX = min(baseAnchorBoxL.normMaxX - minW, nx)
            }
        case .leftInner:
            if useWidthLock {
                let curW = max(minW, baseAnchorBoxL.normMaxX - baseAnchorBoxL.normMinX)
                let lo = curW
                let hi = baseAnchorBoxR.normMinX
                if lo <= hi {
                    let newMaxX = min(hi, max(lo, nx))
                    baseAnchorBoxL.normMaxX = newMaxX
                    baseAnchorBoxL.normMinX = newMaxX - curW
                } else {
                    baseAnchorBoxL.normMinX = 0.0
                    baseAnchorBoxL.normMaxX = max(minW, hi)
                }
            } else {
                let lo = baseAnchorBoxL.normMinX + minW
                let hi = min(baseAnchorBoxR.normMinX, baseAnchorBoxR.normMaxX - minW)
                baseAnchorBoxL.normMaxX = min(hi, max(lo, nx))
            }
        case .rightInner:
            if useWidthLock {
                let curW = max(minW, baseAnchorBoxR.normMaxX - baseAnchorBoxR.normMinX)
                let lo = baseAnchorBoxL.normMaxX
                let hi = 1.0 - curW
                if lo <= hi {
                    let newMinX = min(hi, max(lo, nx))
                    baseAnchorBoxR.normMinX = newMinX
                    baseAnchorBoxR.normMaxX = newMinX + curW
                } else {
                    baseAnchorBoxR.normMinX = min(1.0 - minW, lo)
                    baseAnchorBoxR.normMaxX = 1.0
                }
            } else {
                let lo = max(baseAnchorBoxL.normMaxX, baseAnchorBoxL.normMinX + minW)
                let hi = baseAnchorBoxR.normMaxX - minW
                baseAnchorBoxR.normMinX = min(hi, max(lo, nx))
            }
        case .rightOuter:
            if useWidthLock {
                let maxAllowedW = max(minW, min(baseAnchorBoxL.normMaxX, 1.0 - baseAnchorBoxR.normMinX))
                let clampedW = min(maxAllowedW, max(minW, nx - baseAnchorBoxR.normMinX))
                baseAnchorBoxR.normMaxX = baseAnchorBoxR.normMinX + clampedW
                baseAnchorBoxL.normMinX = baseAnchorBoxL.normMaxX - clampedW
            } else {
                baseAnchorBoxR.normMaxX = max(baseAnchorBoxR.normMinX + minW, nx)
            }
        }

        effectiveBoxL = baseAnchorBoxL
        effectiveBoxR = baseAnchorBoxR
    }

    private func handleGuideDragEnded(in size: CGSize, endLocation: CGPoint) {
        guard let handle = draggingGuide else { return }
        let wasIndependent = draggingGuideIndependent
        let usedWidthLock = lockEqualGuideWidth && !wasIndependent
        draggingGuide = nil
        draggingGuideIndependent = false

        let hitAfter = hitTestGuide(at: endLocation, size: size)
        hoveredGuide = hitAfter
        updateCursor(for: hitAfter)

        if let snap = pendingDragSnapshot {
            let changed = (snap.baseAnchorBoxL != baseAnchorBoxL) || (snap.baseAnchorBoxR != baseAnchorBoxR)
            if changed {
                pushSnapshot(snap)
            }
            pendingDragSnapshot = nil
            guard changed else { return }
        }

        useBoxAnchor = true
        let updatedLeft: Bool
        let updatedRight: Bool
        switch handle {
        case .top(let side), .bottom(let side):
            updatedLeft = !wasIndependent || side == .left
            updatedRight = !wasIndependent || side == .right
        case .leftOuter:
            updatedLeft = true
            updatedRight = usedWidthLock
        case .rightOuter:
            updatedLeft = usedWidthLock
            updatedRight = true
        case .leftInner:
            updatedLeft = true
            updatedRight = false
        case .rightInner:
            updatedLeft = false
            updatedRight = true
        }

        if updatedLeft { hasCustomBoxL = true }
        if updatedRight { hasCustomBoxR = true }

        if isDirectGuideMaskActive {
            applyDirectGuideMask(recordUndo: false)
            return
        }

        if updatedLeft {
            points.removeAll { pt in
                pt.side == .left && pt.isPositive && (
                    pt.normX < baseAnchorBoxL.normMinX || pt.normX > baseAnchorBoxL.normMaxX ||
                    pt.normY < baseAnchorBoxL.normMinY || pt.normY > baseAnchorBoxL.normMaxY
                )
            }
        }
        if updatedRight {
            points.removeAll { pt in
                pt.side == .right && pt.isPositive && (
                    pt.normX < baseAnchorBoxR.normMinX || pt.normX > baseAnchorBoxR.normMaxX ||
                    pt.normY < baseAnchorBoxR.normMinY || pt.normY > baseAnchorBoxR.normMaxY
                )
            }
        }

        if updatedLeft && updatedRight {
            rerunBothSidesInference()
        } else if updatedLeft {
            rerunInference(for: .left, forceIfNoPoints: true)
        } else if updatedRight {
            rerunInference(for: .right, forceIfNoPoints: true)
        }
    }

    private func applyDirectGuideMask(recordUndo: Bool) {
        if recordUndo {
            pushCurrentSnapshot()
        }
        inferenceTask?.cancel()
        isInferring = false
        let arch = StereoCardSegmenter.makeGuideArchParams(
            topRyRatio: guideTopArchRatio,
            botRyRatio: guideBotRoundRatio
        )
        let direct = StereoCardSegmenter.buildGuideDirectMasks(
            boxL: baseAnchorBoxL,
            boxR: baseAnchorBoxR,
            archParams: arch,
            maskW: maskW,
            maskH: maskH
        )
        currentMaskL = direct.maskL
        currentProbL = direct.probL
        currentMaskR = direct.maskR
        currentProbR = direct.probR
        effectiveBoxL = baseAnchorBoxL
        effectiveBoxR = baseAnchorBoxR
        hasCustomBoxL = true
        hasCustomBoxR = true
        isDirectGuideMaskActive = true
        statusBanner = nil
        rebuildRenderedPreview()
    }

    private func boxOverlayView(
        box: InteractivePromptBox,
        color: Color,
        isActive: Bool,
        in rect: CGRect
    ) -> some View {
        let bx = rect.minX + box.normMinX * rect.width
        let by = rect.minY + box.normMinY * rect.height
        let bw = max(4, (box.normMaxX - box.normMinX) * rect.width)
        let bh = max(4, (box.normMaxY - box.normMinY) * rect.height)
        return RoundedRectangle(cornerRadius: 3)
            .stroke(
                color.opacity(isActive ? 0.85 : 0.35),
                style: StrokeStyle(lineWidth: isActive ? 1.8 : 1.0, dash: [6, 4])
            )
            .frame(width: bw, height: bh)
            .position(x: bx + bw * 0.5, y: by + bh * 0.5)
            .allowsHitTesting(false)
    }

    private func pointMarkerView(_ pt: InteractivePromptPoint) -> some View {
        let isFocusedSide = (pt.side == activeSide)
        let fillColor: Color = pt.isPositive ? .green : .red
        return ZStack {
            Circle()
                .fill(fillColor.opacity(isFocusedSide ? 0.92 : 0.55))
                .frame(width: 16, height: 16)
            Circle()
                .stroke(Color.white.opacity(isFocusedSide ? 0.95 : 0.6), lineWidth: 1.8)
                .frame(width: 16, height: 16)
            Image(systemName: pt.isPositive ? "plus" : "minus")
                .font(.system(size: 9, weight: .black))
                .foregroundColor(.white)
        }
        .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
    }

    // MARK: - Bottom Footer Bar

    private var bottomFooterBar: some View {
        VStack(spacing: 8) {
            if let banner = statusBanner {
                HStack(spacing: 6) {
                    Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(banner.isError ? .orange : .green)
                    Text(banner.text)
                        .appSystemFont(size: 11.5, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background((banner.isError ? Color.orange : Color.green).opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    if !cacheStatusText.isEmpty {
                        Text(cacheStatusText)
                            .appSystemFont(size: 10.5, weight: .semibold, design: .monospaced)
                            .foregroundColor(.brightBlue)
                    }
                    if let ms = lastElapsedMs {
                        Text(String(format: "%.0f ms", ms))
                            .appSystemFont(size: 10.5, design: .monospaced)
                            .foregroundColor(.secondary)
                    }
                    let stats = maskAreaStats
                    Text(String(format: "L: %.1f%%  R: %.1f%%  LR: %.1f%%", stats.leftPct, stats.rightPct, stats.lrPct))
                        .appSystemFont(size: 10.5, weight: .medium, design: .monospaced)
                        .foregroundColor(stats.lrPct < 85.0 ? .orange : .secondary)
                    if let px = guidePixelSizes {
                        let matched = abs(px.lw - px.rw) <= 1 && abs(px.lh - px.rh) <= 1
                        HStack(spacing: 3) {
                            if matched {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                            }
                            Text("L: \(px.lw)×\(px.lh)  R: \(px.rw)×\(px.rh) px")
                        }
                        .appSystemFont(size: 10.5, weight: .semibold, design: .monospaced)
                        .foregroundColor(matched ? .green : .orange)
                    }
                    if isInferring {
                        ProgressView().controlSize(.mini)
                    }
                }

                Spacer()

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
                .help(vm.trainingDatasetDirectoryPath)

                Button {
                    let url = URL(fileURLWithPath: vm.trainingDatasetDirectoryPath, isDirectory: true)
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal dataset folder in Finder")
            }

            HStack(spacing: 10) {
                Text(toolMode == .adjustGuides
                     ? String(localized: "Drag 6 guides (H synced by default, ⌥+Drag for single side) · Adjust arch sliders for direct mask")
                     : String(localized: "Click: add point (Green = Photo, Red = Mount) · Shift+Click near point: remove"))
                    .appSystemFont(size: 10.5)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .disabled(isSavingOrApplying)

                Button("Save Dataset Only") {
                    Task { await saveDatasetOnlyTapped() }
                }
                .buttonStyle(.bordered)
                .disabled(isPreparingEmbedding || isSavingOrApplying || currentProbL.isEmpty)

                Button {
                    Task { await applyAndCloseTapped() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Apply & Re-align")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.brightBlue)
                .keyboardShortcut(.defaultAction)
                .disabled(isPreparingEmbedding || isSavingOrApplying || currentProbL.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.25))
    }

    // MARK: - Snapshot & Undo Helpers

    private func captureSnapshot() -> MaskEditorSnapshot {
        MaskEditorSnapshot(
            points: points,
            baseAnchorBoxL: baseAnchorBoxL,
            baseAnchorBoxR: baseAnchorBoxR,
            effectiveBoxL: effectiveBoxL,
            effectiveBoxR: effectiveBoxR,
            hasCustomBoxL: hasCustomBoxL,
            hasCustomBoxR: hasCustomBoxR,
            maskL: currentMaskL,
            probL: currentProbL,
            maskR: currentMaskR,
            probR: currentProbR,
            guideTopArchRatio: guideTopArchRatio,
            guideBotRoundRatio: guideBotRoundRatio,
            isDirectGuideMaskActive: isDirectGuideMaskActive
        )
    }

    private func pushSnapshot(_ snap: MaskEditorSnapshot) {
        undoStack.append(snap)
        if undoStack.count > 30 {
            undoStack.removeFirst()
        }
    }

    private func pushCurrentSnapshot() {
        pushSnapshot(captureSnapshot())
    }

    private func setArchRatiosProgrammatically(top: Double, bot: Double) {
        isProgrammaticArchUpdate = true
        guideTopArchRatio = top
        guideBotRoundRatio = bot
        DispatchQueue.main.async {
            isProgrammaticArchUpdate = false
        }
    }

    private func undoLastAction() {
        guard let prev = undoStack.popLast() else { return }
        inferenceTask?.cancel()
        isInferring = false
        points = prev.points
        baseAnchorBoxL = prev.baseAnchorBoxL
        baseAnchorBoxR = prev.baseAnchorBoxR
        effectiveBoxL = prev.effectiveBoxL
        effectiveBoxR = prev.effectiveBoxR
        hasCustomBoxL = prev.hasCustomBoxL
        hasCustomBoxR = prev.hasCustomBoxR
        currentMaskL = prev.maskL
        currentProbL = prev.probL
        currentMaskR = prev.maskR
        currentProbR = prev.probR
        setArchRatiosProgrammatically(top: prev.guideTopArchRatio, bot: prev.guideBotRoundRatio)
        isDirectGuideMaskActive = prev.isDirectGuideMaskActive
        rebuildRenderedPreview()
    }

    // MARK: - Initialization & Inference Logic

    private func initializeEditorSession() async {
        guard let ctx = vm.currentMountContext else {
            statusBanner = (String(localized: "No source stereoview card context available."), true)
            return
        }

        isPreparingEmbedding = true
        let cardW = max(1, ctx.cardWidth)
        let cardH = max(1, ctx.cardHeight)

        baseAnchorBoxL = InteractivePromptBox(
            normMinX: Double(ctx.leftBox.x0) / Double(cardW),
            normMinY: Double(ctx.leftBox.y0) / Double(cardH),
            normMaxX: Double(ctx.leftBox.x1) / Double(cardW),
            normMaxY: Double(ctx.leftBox.y1) / Double(cardH)
        )
        baseAnchorBoxR = InteractivePromptBox(
            normMinX: Double(ctx.rightBox.x0) / Double(cardW),
            normMinY: Double(ctx.rightBox.y0) / Double(cardH),
            normMaxX: Double(ctx.rightBox.x1) / Double(cardW),
            normMaxY: Double(ctx.rightBox.y1) / Double(cardH)
        )
        initialAnchorBoxL = baseAnchorBoxL
        initialAnchorBoxR = baseAnchorBoxR
        effectiveBoxL = baseAnchorBoxL
        effectiveBoxR = baseAnchorBoxR
        hasCustomBoxL = false
        hasCustomBoxR = false

        initialTopArchRatio = min(0.45, max(0.0, ctx.archParams.topRyRatio))
        initialBotRoundRatio = min(0.20, max(0.0, ctx.archParams.botRyRatio))
        setArchRatiosProgrammatically(top: initialTopArchRatio, bot: initialBotRoundRatio)
        isDirectGuideMaskActive = false
        undoStack.removeAll()

        let (prevRGB, pw, ph) = ViewStereoViewModel.downsampleForPreview(ctx.cardRGB, width: cardW, height: cardH, maxDim: 1400)
        previewBaseRGB = prevRGB
        previewBaseW = pw
        previewBaseH = ph

        let t0 = CFAbsoluteTimeGetCurrent()
        let cache = await Task.detached(priority: .userInitiated) {
            StereoCardSegmenter.shared.prepareInteractiveEmbedding(
                cardRGB: ctx.cardRGB,
                width: ctx.cardWidth,
                height: ctx.cardHeight
            )
        }.value
        let prepMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

        embeddingCache = cache
        let targetW = cache?.validW ?? max(64, ctx.maskWidth)
        let targetH = cache?.validH ?? max(32, ctx.maskHeight)
        maskW = targetW
        maskH = targetH

        let initial = StereoCardSegmenter.makeInitialInteractiveMasks(
            from: ctx,
            targetW: targetW,
            targetH: targetH
        )
        initialMaskL = initial.maskL
        initialProbL = initial.probL
        initialMaskR = initial.maskR
        initialProbR = initial.probR
        currentMaskL = initial.maskL
        currentProbL = initial.probL
        currentMaskR = initial.maskR
        currentProbR = initial.probR

        cacheStatusText = cache != nil
            ? String(format: "SAM Cache Ready (%.0f ms)", prepMs)
            : String(localized: "SAM Cache Unavailable")
        isPreparingEmbedding = false
        rebuildRenderedPreview()
    }

    private func handleCanvasTap(normX: Double, normY: Double) {
        guard !isPreparingEmbedding, !isSavingOrApplying, toolMode != .adjustGuides else { return }
        let clampedX = min(1.0, max(0.0, normX))
        let clampedY = min(1.0, max(0.0, normY))
        let flags = NSEvent.modifierFlags

        if flags.contains(.shift) {
            if let nearest = nearestPoint(normX: clampedX, normY: clampedY, threshold: 0.025) {
                removePoint(nearest)
                return
            }
        }

        pushCurrentSnapshot()
        isDirectGuideMaskActive = false

        let basePositive = (toolMode == .positivePoint)
        let positive = flags.contains(.option) ? !basePositive : basePositive
        let newPoint = InteractivePromptPoint(
            side: activeSide,
            normX: clampedX,
            normY: clampedY,
            isPositive: positive
        )
        points.append(newPoint)
        rerunInference(for: activeSide, forceIfNoPoints: activeSide == .left ? hasCustomBoxL : hasCustomBoxR)
    }

    private func nearestPoint(normX: Double, normY: Double, threshold: Double) -> InteractivePromptPoint? {
        var best: (InteractivePromptPoint, Double)? = nil
        for pt in points {
            let d = hypot(pt.normX - normX, pt.normY - normY)
            if d <= threshold && (best == nil || d < best!.1) {
                best = (pt, d)
            }
        }
        return best?.0
    }

    private func removePoint(_ pt: InteractivePromptPoint) {
        pushCurrentSnapshot()
        points.removeAll { $0.id == pt.id }
        let keepCustom = (pt.side == .left) ? hasCustomBoxL : hasCustomBoxR
        rerunInference(for: pt.side, forceIfNoPoints: keepCustom)
    }

    private func resetSidePoints(_ side: CardPrintSide) {
        pushCurrentSnapshot()
        isDirectGuideMaskActive = false
        points.removeAll { $0.side == side }
        if side == .left {
            hasCustomBoxL = false
            baseAnchorBoxL = initialAnchorBoxL
            currentMaskL = initialMaskL
            currentProbL = initialProbL
            effectiveBoxL = initialAnchorBoxL
        } else {
            hasCustomBoxR = false
            baseAnchorBoxR = initialAnchorBoxR
            currentMaskR = initialMaskR
            currentProbR = initialProbR
            effectiveBoxR = initialAnchorBoxR
        }
        rebuildRenderedPreview()
    }

    private func resetAllToInitial() {
        pushCurrentSnapshot()
        inferenceTask?.cancel()
        isInferring = false
        isDirectGuideMaskActive = false
        points.removeAll()
        hasCustomBoxL = false
        hasCustomBoxR = false
        baseAnchorBoxL = initialAnchorBoxL
        baseAnchorBoxR = initialAnchorBoxR
        currentMaskL = initialMaskL
        currentProbL = initialProbL
        currentMaskR = initialMaskR
        currentProbR = initialProbR
        effectiveBoxL = initialAnchorBoxL
        effectiveBoxR = initialAnchorBoxR
        setArchRatiosProgrammatically(top: initialTopArchRatio, bot: initialBotRoundRatio)
        lastElapsedMs = nil
        rebuildRenderedPreview()
    }

    /// 対向側の最新マスク重心（編集反映済み）を動的に取得
    private func resolvedOtherCenter(for side: CardPrintSide) -> (normX: Double, normY: Double)? {
        let otherSide: CardPrintSide = (side == .left) ? .right : .left
        let otherMask = (otherSide == .left) ? currentMaskL : currentMaskR
        let otherWasEdited = (otherSide == .left)
            ? (hasCustomBoxL || points.contains { $0.side == .left })
            : (hasCustomBoxR || points.contains { $0.side == .right })
        let sideHasUserNeg = points.contains { $0.side == side && !$0.isPositive }

        if !useBoxAnchor && !otherWasEdited && sideHasUserNeg {
            return nil
        }
        if let centroid = StereoCardSegmenter.computeMaskCentroid(mask: otherMask, width: maskW, height: maskH) {
            return centroid
        }
        return (otherSide == .left)
            ? (effectiveBoxL ?? baseAnchorBoxL).centerNorm
            : (effectiveBoxR ?? baseAnchorBoxR).centerNorm
    }

    private func rerunInference(for side: CardPrintSide, forceIfNoPoints: Bool) {
        let sidePoints = points.filter { $0.side == side }
        let isCustomBox = (side == .left) ? hasCustomBoxL : hasCustomBoxR
        if sidePoints.isEmpty && !forceIfNoPoints && !isCustomBox {
            if side == .left {
                currentMaskL = initialMaskL
                currentProbL = initialProbL
                effectiveBoxL = baseAnchorBoxL
            } else {
                currentMaskR = initialMaskR
                currentProbR = initialProbR
                effectiveBoxR = baseAnchorBoxR
            }
            rebuildRenderedPreview()
            return
        }

        guard let cache = embeddingCache else {
            statusBanner = (String(localized: "SAM 2.1 embedding is not ready."), true)
            return
        }

        let anchorBox = (side == .left) ? baseAnchorBoxL : baseAnchorBoxR
        let otherCenter = resolvedOtherCenter(for: side)
        let allPoints = points
        let boxAnchorEnabled = useBoxAnchor

        inferenceTask?.cancel()
        isInferring = true
        inferenceTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                StereoCardSegmenter.shared.predictInteractiveMask(
                    cache: cache,
                    side: side,
                    points: allPoints,
                    anchorBox: anchorBox,
                    otherBoxCenter: otherCenter,
                    useBoxAnchor: boxAnchorEnabled
                )
            }.value

            guard !Task.isCancelled else { return }
            isInferring = false

            guard let res = result else {
                statusBanner = (String(localized: "Interactive SAM inference failed."), true)
                return
            }

            if side == .left {
                currentMaskL = res.mask
                currentProbL = res.softProb
                effectiveBoxL = res.effectiveBox
            } else {
                currentMaskR = res.mask
                currentProbR = res.softProb
                effectiveBoxR = res.effectiveBox
            }
            lastElapsedMs = res.elapsedMs
            statusBanner = nil
            rebuildRenderedPreview()
        }
    }

    /// 水平ガイドの左右連動ドラッグ終了時に左右両方を単一タスクで順次再推論する
    private func rerunBothSidesInference() {
        guard let cache = embeddingCache else {
            statusBanner = (String(localized: "SAM 2.1 embedding is not ready."), true)
            return
        }
        let boxL = baseAnchorBoxL
        let boxR = baseAnchorBoxR
        let allPoints = points
        let boxAnchorEnabled = useBoxAnchor
        let otherForL = resolvedOtherCenter(for: .left)

        inferenceTask?.cancel()
        isInferring = true
        inferenceTask = Task {
            let pairRes = await Task.detached(priority: .userInitiated) { () -> (InteractiveMaskResult?, InteractiveMaskResult?) in
                let resL = StereoCardSegmenter.shared.predictInteractiveMask(
                    cache: cache,
                    side: .left,
                    points: allPoints,
                    anchorBox: boxL,
                    otherBoxCenter: otherForL,
                    useBoxAnchor: boxAnchorEnabled
                )
                let otherForR: (normX: Double, normY: Double)?
                if let resL, let cL = StereoCardSegmenter.computeMaskCentroid(mask: resL.mask, width: resL.validW, height: resL.validH) {
                    otherForR = cL
                } else {
                    otherForR = boxL.centerNorm
                }
                let resR = StereoCardSegmenter.shared.predictInteractiveMask(
                    cache: cache,
                    side: .right,
                    points: allPoints,
                    anchorBox: boxR,
                    otherBoxCenter: otherForR,
                    useBoxAnchor: boxAnchorEnabled
                )
                return (resL, resR)
            }.value

            guard !Task.isCancelled else { return }
            isInferring = false

            var totalMs = 0.0
            if let rL = pairRes.0 {
                currentMaskL = rL.mask
                currentProbL = rL.softProb
                effectiveBoxL = rL.effectiveBox
                totalMs += rL.elapsedMs
            }
            if let rR = pairRes.1 {
                currentMaskR = rR.mask
                currentProbR = rR.softProb
                effectiveBoxR = rR.effectiveBox
                totalMs += rR.elapsedMs
            }
            if pairRes.0 != nil || pairRes.1 != nil {
                lastElapsedMs = totalMs
                statusBanner = nil
                rebuildRenderedPreview()
            } else {
                statusBanner = (String(localized: "Interactive SAM inference failed."), true)
            }
        }
    }

    // MARK: - Preview Rendering

    private func rebuildRenderedPreview() {
        let w = previewBaseW
        let h = previewBaseH
        guard w > 0, h > 0, previewBaseRGB.count >= w * h * 3,
              maskW > 0, maskH > 0,
              currentProbL.count >= maskW * maskH,
              currentProbR.count >= maskW * maskH else {
            return
        }

        var outRGB = previewBaseRGB
        let style = previewStyle
        let mw = maskW
        let mh = maskH

        for y in 0..<h {
            let fy = (Double(y) + 0.5) / Double(h) * Double(mh) - 0.5
            let y0 = max(0, min(mh - 1, Int(floor(fy))))
            let y1 = max(0, min(mh - 1, y0 + 1))
            let ay = Float(max(0.0, min(1.0, fy - Double(y0))))
            let row0 = y0 * mw
            let row1 = y1 * mw
            let dRow = y * w * 3

            for x in 0..<w {
                let fx = (Double(x) + 0.5) / Double(w) * Double(mw) - 0.5
                let x0 = max(0, min(mw - 1, Int(floor(fx))))
                let x1 = max(0, min(mw - 1, x0 + 1))
                let ax = Float(max(0.0, min(1.0, fx - Double(x0))))

                let w00 = (1 - ax) * (1 - ay)
                let w10 = ax * (1 - ay)
                let w01 = (1 - ax) * ay
                let w11 = ax * ay

                let p00 = row0 + x0, p10 = row0 + x1, p01 = row1 + x0, p11 = row1 + x1
                let pL = currentProbL[p00] * w00 + currentProbL[p10] * w10 + currentProbL[p01] * w01 + currentProbL[p11] * w11
                let pR = currentProbR[p00] * w00 + currentProbR[p10] * w10 + currentProbR[p01] * w01 + currentProbR[p11] * w11

                let idx = dRow + x * 3
                let r = Float(outRGB[idx])
                let g = Float(outRGB[idx + 1])
                let b = Float(outRGB[idx + 2])

                switch style {
                case .overlay:
                    let alpha = max(pL, pR)
                    let dim: Float = 0.45 + 0.55 * min(Float(1.0), max(Float(0.0), (alpha - 0.35) / 0.30))
                    outRGB[idx]     = UInt8(min(255, max(0, Int((r * dim).rounded()))))
                    outRGB[idx + 1] = UInt8(min(255, max(0, Int((g * dim).rounded()))))
                    outRGB[idx + 2] = UInt8(min(255, max(0, Int((b * dim).rounded()))))

                case .whiteCutout:
                    let alpha = max(pL, pR)
                    let softA = min(Float(1.0), max(Float(0.0), (alpha - 0.35) / 0.30))
                    outRGB[idx]     = UInt8(min(255, max(0, Int((r * softA + 255.0 * (1.0 - softA)).rounded()))))
                    outRGB[idx + 1] = UInt8(min(255, max(0, Int((g * softA + 255.0 * (1.0 - softA)).rounded()))))
                    outRGB[idx + 2] = UInt8(min(255, max(0, Int((b * softA + 255.0 * (1.0 - softA)).rounded()))))
                }
            }
        }

        if let cgImg = StereoCardSegmenter.shared.makeCGImage(from: outRGB, width: w, height: h) {
            renderedPreviewImage = NSImage(cgImage: cgImg, size: NSSize(width: w, height: h))
        }
    }

    // MARK: - Actions

    private func currentDirectOverrides() -> (arch: StereoCardSegmenter.ArchShapeParams?, boxes: (left: InteractivePromptBox, right: InteractivePromptBox)?) {
        guard isDirectGuideMaskActive else { return (nil, nil) }
        let arch = StereoCardSegmenter.makeGuideArchParams(
            topRyRatio: guideTopArchRatio,
            botRyRatio: guideBotRoundRatio
        )
        return (arch, (left: baseAnchorBoxL, right: baseAnchorBoxR))
    }

    private func saveDatasetOnlyTapped() async {
        isSavingOrApplying = true
        let overrides = currentDirectOverrides()
        let wasEdited = !points.isEmpty || hasCustomBoxL || hasCustomBoxR || isDirectGuideMaskActive
        let res = await vm.exportTrainingDatasetOnly(
            maskL: currentMaskL,
            softProbL: currentProbL,
            maskR: currentMaskR,
            softProbR: currentProbR,
            maskW: maskW,
            maskH: maskH,
            points: points,
            wasManuallyEdited: wasEdited,
            overrideArchParams: overrides.arch,
            overrideBoxes: overrides.boxes
        )
        isSavingOrApplying = false
        switch res {
        case .success(let exported):
            statusBanner = ("Saved 3-class PNG: \(exported.maskURL.lastPathComponent) (L=\(exported.leftPixels)px, R=\(exported.rightPixels)px)", false)
        case .failure(let err):
            statusBanner = (err.localizedDescription, true)
        }
    }

    private func applyAndCloseTapped() async {
        isSavingOrApplying = true
        let overrides = currentDirectOverrides()
        let ok = await vm.applyInteractiveMaskCorrection(
            maskL: currentMaskL,
            softProbL: currentProbL,
            maskR: currentMaskR,
            softProbR: currentProbR,
            maskW: maskW,
            maskH: maskH,
            points: points,
            exportTrainingData: vm.autoExportTrainingDatasetOnMaskApply,
            overrideArchParams: overrides.arch,
            overrideBoxes: overrides.boxes
        )
        isSavingOrApplying = false
        if ok {
            dismiss()
        } else {
            statusBanner = (String(localized: "Failed to refine and apply mask correction."), true)
        }
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

    private var guidePixelSizes: (lw: Int, lh: Int, rw: Int, rh: Int)? {
        guard let ctx = vm.currentMountContext, ctx.cardWidth > 0, ctx.cardHeight > 0 else { return nil }
        let w = Double(ctx.cardWidth)
        let h = Double(ctx.cardHeight)
        let lw = max(1, Int(((baseAnchorBoxL.normMaxX - baseAnchorBoxL.normMinX) * w).rounded()))
        let lh = max(1, Int(((baseAnchorBoxL.normMaxY - baseAnchorBoxL.normMinY) * h).rounded()))
        let rw = max(1, Int(((baseAnchorBoxR.normMaxX - baseAnchorBoxR.normMinX) * w).rounded()))
        let rh = max(1, Int(((baseAnchorBoxR.normMaxY - baseAnchorBoxR.normMinY) * h).rounded()))
        return (lw, lh, rw, rh)
    }

    private var maskAreaStats: (leftPct: Double, rightPct: Double, lrPct: Double) {
        let total = max(1, currentMaskL.count)
        let cntL = currentMaskL.reduce(0) { $0 + ($1 ? 1 : 0) }
        let cntR = currentMaskR.reduce(0) { $0 + ($1 ? 1 : 0) }
        let leftPct = Double(cntL) / Double(total) * 100.0
        let rightPct = Double(cntR) / Double(total) * 100.0
        let maxLR = max(1, max(cntL, cntR))
        let lrPct = Double(min(cntL, cntR)) / Double(maxLR) * 100.0
        return (leftPct, rightPct, lrPct)
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
}

/// macOS の .sheet が minWidth/minHeight で縮まって開くのを防ぎ、初回表示時に画面いっぱいのサイズを適用する
private struct SheetWindowSizer: NSViewRepresentable {
    let targetSize: CGSize

    final class Coordinator {
        var didApply = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SizerNSView {
        let view = SizerNSView()
        let desired = targetSize
        view.onMoveToWindow = { [weak coordinator = context.coordinator] window in
            guard let window, let coordinator, !coordinator.didApply else { return }
            coordinator.didApply = true
            Task { @MainActor in
                let visible = (window.screen ?? NSScreen.main)?.visibleFrame
                    ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                let clamped = CGSize(
                    width: min(desired.width, max(980, floor(visible.width - 24))),
                    height: min(desired.height, max(700, floor(visible.height - 64)))
                )
                window.setContentSize(clamped)
            }
        }
        return view
    }

    func updateNSView(_ nsView: SizerNSView, context: Context) {}

    final class SizerNSView: NSView {
        var onMoveToWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMoveToWindow?(window)
        }
    }
}
