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
        fallbackVersion: "0.1.0",
        fallbackBuild: "1",
        websiteURL: nil,
        websiteLabel: nil,
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
            }
            CommandGroup(replacing: .newItem) {
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

                Button("2D") { vm.displayMode = .twoD }
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
                Button("Stereoview Card") { vm.displayMode = .stereoviewCard }
                    .keyboardShortcut("8", modifiers: .command)
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
            Section("Appearance & Accessibility") {
                Toggle("Large Text Mode (1.2x UI Scale)", isOn: $settings.useLargeTextMode)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 180)
        .preferredColorScheme(.dark)
    }
}
