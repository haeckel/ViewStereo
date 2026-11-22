import AppKit
import StereoStudioCore
import SwiftUI

extension AboutBrandInfo {
    static let viewStereo = AboutBrandInfo(
        prefixTitle: "View",
        suffixTitle: "Stereo",
        badgeLetter: "V",
        subtitleKey: nil,
        engineTagline: "19th Century Stereoview Restoration & Intelligent Stereo Window Studio",
        fallbackVersion: "0.1.7",
        fallbackBuild: "1",
        websiteURL: URL(string: "https://viewstereo.p-media.jp/"),
        websiteLabel: "viewstereo.p-media.jp",
        copyrightText: "© 2026 ViewStereo Project. All rights reserved.",
        windowWidth: 540,
        windowHeight: 390
    )
}

final class ViewStereoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSWindow.allowsAutomaticWindowTabbing = false
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }
}

@main
struct ViewStereoApp: App {
    @NSApplicationDelegateAdaptor(ViewStereoAppDelegate.self) var appDelegate
    @StateObject private var vm = ViewStereoViewModel()
    @Environment(\.openWindow) private var openWindow

    init() {
        StudioUpdateManager.shared.configure(brand: .viewStereo)
    }

    private var isJapanese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("ja") ?? true
    }

    var body: some Scene {
        // 1. メインウィンドウ
        WindowGroup(id: "main") {
            ContentView(vm: vm)
                .onOpenURL { url in
                    vm.handleDroppedURLs([url])
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About ViewStereo") {
                    openWindow(id: "about")
                }
                Button("Check for Updates...") {
                    StudioUpdateManager.shared.checkForUpdates(isUserInitiated: true)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    vm.resetToInitialState()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled((!vm.hasLoadedImages && vm.batchCompletionSummary == nil) || vm.isProcessing || vm.isBatchRunning)

                Button("Open Workspace Folder...") {
                    vm.openWorkspaceFolderPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(vm.isBatchRunning)

                Button(vm.workspaceMode == .convert2DTo3D
                    ? String(localized: "Open 2D Photos...")
                    : String(localized: "Open Stereoview Card, L/R or SBS...")) {
                    vm.openImagesPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Batch Process Selection / Folder") {
                    vm.startBatchProcessingFromBrowser()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(vm.isBatchRunning || vm.isProcessing)

                Button("Verify Selected Stereo") {
                    vm.startStereoVerificationFromBrowser()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(vm.workspaceMode == .convert2DTo3D || vm.isBatchRunning || vm.isProcessing)

                Divider()

                Button("Select All Files in Browser") {
                    if NSApp.keyWindow?.firstResponder is NSTextView {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    } else {
                        vm.selectAllBrowserFiles()
                    }
                }
                .keyboardShortcut("a", modifiers: .command)

                Button("Deselect All") {
                    vm.deselectAllBrowserNodes()
                }
                .keyboardShortcut("a", modifiers: [.option, .command])

                Divider()

                Button("Quick Export to Output Folder") {
                    vm.quickExportToWorkspaceOutput()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!vm.hasLoadedImages || vm.isProcessing || vm.isBatchRunning)

                Button("Export Image...") {
                    vm.exportImage()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!vm.hasLoadedImages || vm.isProcessing || vm.isBatchRunning)
            }
            CommandMenu("Stereo") {
                Button("Auto Align & Window") {
                    vm.runAutoAlignment()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!vm.hasLoadedImages || vm.isProcessing)

                Button("Swap Left / Right") {
                    vm.swapLeftRight()
                }
                .keyboardShortcut("x", modifiers: [])
                .disabled(vm.isProcessing)

                Divider()

                Button("StereoView") { vm.displayMode = .stereoviewCard }
                    .keyboardShortcut("1", modifiers: .command)
                Button("SBS") { vm.displayMode = .sbs }
                    .keyboardShortcut("2", modifiers: .command)
                Button("LR/RL") { vm.displayMode = .lrrl }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Dubois") { vm.displayMode = .dubois }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Color Anaglyph") { vm.displayMode = .colorAnaglyph }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Gray Anaglyph") { vm.displayMode = .grayAnaglyph }
                    .keyboardShortcut("6", modifiers: .command)
                Button("Polarized") { vm.displayMode = .polarized }
                    .keyboardShortcut("7", modifiers: .command)
                Button("2D") { vm.displayMode = .twoD }
                    .keyboardShortcut("8", modifiers: .command)
            }
            CommandMenu("Panels") {
                Button("Toggle File Browser") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        vm.isShowingFileBrowser.toggle()
                    }
                }
                .keyboardShortcut("l", modifiers: [.option, .command])

                Button("Toggle Sidebar") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        vm.isShowingInspector.toggle()
                    }
                }
                .keyboardShortcut("0", modifiers: [.option, .command])

                Divider()

                Button("Toggle Basic Recipe Panel") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if !vm.isShowingInspector { vm.isShowingInspector = true }
                        vm.isRecipeSectionExpanded.toggle()
                    }
                }
                .keyboardShortcut("1", modifiers: [.option, .command])

                Button("Toggle Stereo Window Panel") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if !vm.isShowingInspector { vm.isShowingInspector = true }
                        vm.isWindowSectionExpanded.toggle()
                    }
                }
                .keyboardShortcut("2", modifiers: [.option, .command])

                Button("Toggle Stereoview Card Mount Panel") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if !vm.isShowingInspector { vm.isShowingInspector = true }
                        vm.isCardMountSectionExpanded.toggle()
                    }
                }
                .keyboardShortcut("3", modifiers: [.option, .command])

                Button("Toggle Vintage Restoration Panel") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if !vm.isShowingInspector { vm.isShowingInspector = true }
                        vm.isRestorationSectionExpanded.toggle()
                    }
                }
                .keyboardShortcut("4", modifiers: [.option, .command])

                Button("Toggle Colorization Panel") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if !vm.isShowingInspector { vm.isShowingInspector = true }
                        vm.isColorizationSectionExpanded.toggle()
                    }
                }
                .keyboardShortcut("5", modifiers: [.option, .command])
            }
            CommandGroup(replacing: .help) {
                Button("ViewStereo Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        // 2. ヘルプウィンドウ
        Window("ViewStereo Help", id: "help") {
            HelpView(isJapanese: isJapanese, fallbackAppName: "ViewStereo")
        }
        .defaultSize(width: 720, height: 560)

        // 3. アバウトウィンドウ
        Window("About ViewStereo", id: "about") {
            AboutView(brand: .viewStereo)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // 4. 設定ウィンドウ
        Settings {
            AppSettingsView()
        }
    }
}

struct AppSettingsView: View {
    @ObservedObject private var settings = ViewStereoSettings.shared
    @StateObject private var downloader = StudioDepthModelDownloader(appFolder: "ViewStereo")

    var body: some View {
        TabView {
            // タブ1: 全般
            Form {
                Section("Workspace & Startup") {
                    Picker("On Launch", selection: $settings.startupFolderActionRaw) {
                        ForEach(StartupFolderAction.allCases) { action in
                            Text(LocalizedStringKey(action.rawValue)).tag(action.rawValue)
                        }
                    }

                    Toggle("Keep Restoration Recipe Across Images", isOn: $settings.keepRecipeAcrossImages)
                }

                Section("Auto Correction") {
                    Toggle("Auto-Swap Reversed Stereo (Pseudoscopic)", isOn: $settings.autoSwapPseudoscopic)
                }

                Section("Appearance & Accessibility") {
                    Toggle("Large Text Mode (1.2x UI Scale)", isOn: $settings.useLargeTextMode)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            // タブ2: AI モデル
            AIModelsSettingsTab(settings: settings, downloader: downloader)
                .tabItem {
                    Label("AI Models", systemImage: "cpu")
                }
        }
        .frame(width: 580, height: 680)
        .preferredColorScheme(.dark)
    }
}

private struct AIModelsSettingsTab: View {
    @ObservedObject var settings: ViewStereoSettings
    @ObservedObject var downloader: StudioDepthModelDownloader
    @State private var memoryReleasedNotice: String? = nil

    private var isJapanese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("ja") ?? true
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                // MARK: - 深度推定 AI エンジン ヘッダー
                HStack(spacing: 12) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title2)
                        .foregroundColor(.palestineGreen)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Depth Estimation AI Engine"))
                            .font(.headline)

                        let ready = StudioDepthEngine.isAnyModelInstalled(preferredAppFolder: "ViewStereo")
                        Text(ready ? String(localized: "Model Ready") : String(localized: "Apple Vision Fallback Active (No Core ML Model)"))
                            .font(.subheadline.bold())
                            .foregroundColor(ready ? .palestineGreen : .orange)
                    }

                    Spacer()

                    Picker(String(localized: "Preferred Engine"), selection: $settings.depthModelEngineRaw) {
                        ForEach(StudioDepthEngine.allCases) { engine in
                            Text(engine.shortLabel).tag(engine.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 230)
                }

                Text(String(localized: "depth_ai_engine_description"))
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                // MARK: - 使用可能な深度モデル一覧
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "Available Depth Models (MoGe-2 / Depth Anything / Apple Depth Pro 2)"))
                        .font(.system(.subheadline, design: .rounded).bold())

                    ForEach(StudioDepthEngine.allCases) { engine in
                        DepthModelRowCard(
                            engine: engine,
                            isActive: settings.depthModelEngineRaw == engine.rawValue,
                            located: engine.locateInstalledModel(preferredAppFolder: "ViewStereo"),
                            isJapanese: isJapanese,
                            downloader: downloader,
                            onSelect: {
                                settings.depthModelEngineRaw = engine.rawValue
                            },
                            onDownload: {
                                downloader.downloadModel(for: engine) { _ in
                                    settings.depthModelEngineRaw = engine.rawValue
                                }
                            }
                        )
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))

                if downloader.isDownloading {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(downloader.statusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button(String(localized: "Cancel")) {
                                downloader.cancelDownload()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        ProgressView(value: downloader.progress)
                    }
                }

                if let err = downloader.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.palestineRed)
                }

                Divider()

                // MARK: - メモリ管理
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(String(localized: "Release depth AI models after inference"), isOn: $settings.releaseAIModelsAfterGeneration)
                        .font(.system(.headline, design: .rounded))
                        .tint(.palestineGreen)

                    Text(String(localized: "release_depth_ai_models_description"))
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button(action: {
                            ViewStereoDepthSynthesizer.shared.releaseCachedModels()
                            memoryReleasedNotice = String(localized: "Cached depth AI models released from memory.")
                        }) {
                            Label(String(localized: "Release Memory Now"), systemImage: "arrow.counterclockwise.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if let notice = memoryReleasedNotice {
                            Text(notice)
                                .font(.caption)
                                .foregroundColor(.palestineGreen)
                        }
                    }
                    .padding(.top, 2)
                }

                Divider()

                // MARK: - 内蔵修復・解析 AI モデル
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundColor(.indigo)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Bundled Restoration & Segmentation Models"))
                                .font(.headline)
                            Text(String(localized: "bundled_models_description"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    bundledModelRow(name: "StereoCardSeg", desc: String(localized: "Stereoview card mount & L/R panel segmentation"))
                    bundledModelRow(name: "SAM2_1TinyImageEncoderFLOAT16", title: "SAM 2.1 Tiny", desc: String(localized: "Subject foreground mask & occlusion boundary"))
                    bundledModelRow(name: "NAFNetDeblur", title: "NAFNet Deblur", desc: String(localized: "Optical deblurring & vintage focus restoration"))
                    bundledModelRow(name: "StereoColorizer", title: "StereoColorizer (DDColor)", desc: String(localized: "Mono-to-color historical photo restoration"))
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func bundledModelRow(name: String, title: String? = nil, desc: String) -> some View {
        let present = Bundle.main.url(forResource: name, withExtension: "mlmodelc") != nil
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(present ? .brightTeal : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title ?? name)
                    .font(.system(.subheadline, design: .rounded).bold())
                Text(desc)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(present ? String(localized: "Bundled") : String(localized: "Missing"))
                .font(.system(.caption, design: .rounded).bold())
                .foregroundColor(present ? .brightTeal : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill((present ? Color.brightTeal : Color.secondary).opacity(0.12)))
        }
        .padding(.vertical, 4)
    }
}

private struct DepthModelRowCard: View {
    let engine: StudioDepthEngine
    let isActive: Bool
    let located: StudioModelLocator.LocatedModel?
    let isJapanese: Bool
    @ObservedObject var downloader: StudioDepthModelDownloader
    let onSelect: () -> Void
    let onDownload: () -> Void

    private var installed: Bool { located != nil }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: engine.isAppleEngine ? "apple.logo" : (engine.isMoGeEngine ? "gyroscope" : "cube.transparent"))
                .foregroundColor(engine.isAppleEngine ? .primary : (engine.isMoGeEngine ? .brightTeal : .blue))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(isJapanese ? engine.displayName : engine.displayNameEN)
                        .font(.system(.subheadline, design: .rounded).bold())
                    if isActive {
                        Text(String(localized: "Selected"))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.brightBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.brightBlue.opacity(0.14)))
                    }
                }
                HStack(spacing: 4) {
                    Text(isJapanese ? engine.badgeSummary : engine.badgeSummaryEN)
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.secondary)
                    if let loc = located, loc.ownerFolder != "ViewStereo" {
                        Text(String(format: String(localized: "· Shared from %@"), loc.ownerFolder))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.brightBlue.opacity(0.9))
                    }
                }
            }

            Spacer()

            if installed {
                Text(String(localized: "Available"))
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundColor(.palestineGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.palestineGreen.opacity(0.12)))
            } else if downloader.isDownloading && downloader.downloadingEngine == engine {
                ProgressView(value: downloader.progress)
                    .frame(width: 60)
            } else {
                Button(String(localized: "Download")) {
                    onDownload()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(downloader.isDownloading)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(isActive ? 0.12 : 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isActive ? Color.brightBlue.opacity(0.4) : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if installed {
                onSelect()
            }
        }
    }
}
