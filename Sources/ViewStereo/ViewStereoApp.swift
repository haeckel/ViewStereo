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
        fallbackVersion: "0.1.6",
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
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
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

                Button("Open Stereoview Card, L/R or SBS...") {
                    vm.openImagesPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Batch Process Folder...") {
                    vm.openBatchFolderPanel()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(vm.isBatchRunning || vm.isProcessing)

                Divider()

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

                Button("Toggle Batch Processing Panel") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if !vm.isShowingInspector { vm.isShowingInspector = true }
                        vm.isBatchSectionExpanded.toggle()
                    }
                }
                .keyboardShortcut("6", modifiers: [.option, .command])
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

    var body: some View {
        Form {
            Section("Auto Correction") {
                Toggle("Auto-Swap Reversed Stereo (Pseudoscopic)", isOn: $settings.autoSwapPseudoscopic)
            }

            Section("Appearance & Accessibility") {
                Toggle("Large Text Mode (1.2x UI Scale)", isOn: $settings.useLargeTextMode)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 230)
        .preferredColorScheme(.dark)
    }
}
