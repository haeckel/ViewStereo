import AppKit
import Combine
import StereoStudioCore
import SwiftUI

@MainActor
private final class BrowserRootFlagObserver: ObservableObject {
    @Published private(set) var hasRootFolder: Bool
    private var cancellable: AnyCancellable?

    init(store: WorkspaceBrowserStore) {
        self.hasRootFolder = store.rootFolder != nil
        self.cancellable = store.$rootFolder
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] next in
                guard let self, self.hasRootFolder != next else { return }
                self.hasRootFolder = next
            }
    }
}

struct WorkspaceFileBrowserView: View {
    let vm: ViewStereoViewModel
    let store: WorkspaceBrowserStore
    let width: CGFloat
    @StateObject private var rootObserver: BrowserRootFlagObserver

    @MainActor
    init(vm: ViewStereoViewModel, store: WorkspaceBrowserStore, width: CGFloat) {
        self.vm = vm
        self.store = store
        self.width = width
        _rootObserver = StateObject(wrappedValue: BrowserRootFlagObserver(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrowserHeaderView(vm: vm, store: store)
                .frame(width: width, alignment: .leading)
                .background(Color.black.opacity(0.24))

            Divider().opacity(0.35)

            if !rootObserver.hasRootFolder {
                EmptyWorkspaceView(vm: vm)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
            } else {
                BrowserTreeContainerView(vm: vm, store: store)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)

                Divider().opacity(0.35)

                BrowserBottomActionBar(vm: vm, store: store)
                    .frame(width: width, alignment: .leading)
                    .background(Color.black.opacity(0.28))
            }
        }
        .frame(width: width, alignment: .topLeading)
        .clipped()
    }
}

// MARK: - Header

private struct BrowserHeaderView: View {
    @ObservedObject var vm: ViewStereoViewModel
    @ObservedObject var store: WorkspaceBrowserStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.brightAmber)

                Text(store.displayTitle ?? String(localized: "No Folder Open"))
                    .appSystemFont(size: 12.5, weight: .bold)
                    .foregroundColor(store.rootFolder == nil ? .secondary : .white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if store.isScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                }

                Spacer(minLength: 4)

                Button {
                    vm.openWorkspaceFolderPanel()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.brightAmber)
                .disabled(vm.isBatchRunning)
                .customTooltip(String(localized: "Open Workspace Folder...") + " (⇧⌘O)")

                Button {
                    WorkspaceThumbnailCache.shared.invalidateAll()
                    vm.refreshWorkspaceBrowser()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .disabled(store.rootFolder == nil || vm.isBatchRunning)
                .customTooltip(String(localized: "Refresh Folder"))
            }

            if store.rootFolder != nil {
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        TextField(LocalizedStringKey("Filter files..."), text: $store.searchText)
                            .textFieldStyle(.plain)
                            .appSystemFont(size: 11)
                        if !store.searchText.isEmpty {
                            Button {
                                store.searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

                    Button {
                        store.showWarningsOnly.toggle()
                    } label: {
                        Image(systemName: store.showWarningsOnly ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundColor(store.showWarningsOnly ? .brightAmber : .secondary)
                            .padding(5)
                            .background(
                                store.showWarningsOnly ? Color.brightAmber.opacity(0.18) : Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                    }
                    .buttonStyle(.plain)
                    .customTooltip(String(localized: "Show Warnings & Errors Only"))

                    Button {
                        store.viewMode = (store.viewMode == .compactList) ? .largeThumbnail : .compactList
                    } label: {
                        Image(systemName: store.viewMode == .compactList ? "square.grid.2x2" : "list.bullet")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(5)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .customTooltip(store.viewMode == .compactList ? String(localized: "Switch to Large Thumbnails") : String(localized: "Switch to Compact List"))
                }

                HStack(spacing: 6) {
                    Button {
                        vm.selectAllBrowserFiles()
                    } label: {
                        Label("Select All", systemImage: "checkmark.square")
                            .appSystemFont(size: 10.5, weight: .medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .customTooltip(String(localized: "Select All Files in Browser") + " (⌘A)")

                    Button {
                        vm.deselectAllBrowserNodes()
                    } label: {
                        Label("Deselect", systemImage: "square")
                            .appSystemFont(size: 10.5, weight: .medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(store.selectedNodeIDs.isEmpty)
                    .customTooltip(String(localized: "Deselect All") + " (⌥⌘A)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Empty State

private struct EmptyWorkspaceView: View {
    let vm: ViewStereoViewModel
    @ObservedObject private var settings = ViewStereoSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 32))
                    .foregroundColor(.brightAmber.opacity(0.85))
                Text(LocalizedStringKey("Select a working folder to browse stereoviews and batch process."))
                    .appSystemFont(size: 11.5)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    vm.openWorkspaceFolderPanel(initialMode: .stereoRestore)
                } label: {
                    Label("Open Stereo Folder...", systemImage: "rectangle.split.2x1")
                        .appSystemFont(size: 11.5, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.brightAmber)

                Button {
                    vm.openWorkspaceFolderPanel(initialMode: .convert2DTo3D)
                } label: {
                    Label("Open 2D → 3D Folder...", systemImage: "cube.transparent")
                        .appSystemFont(size: 11.5, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.brightPurple)
            }
            .padding(.horizontal, 16)

            if !settings.recentWorkspaceFolderPaths.isEmpty {
                Divider().opacity(0.25).padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey("RECENT FOLDERS"))
                        .appSystemFont(size: 10, weight: .bold)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 14)

                    ForEach(settings.recentWorkspaceFolderPaths.prefix(5), id: \.self) { path in
                        let url = URL(fileURLWithPath: path, isDirectory: true)
                        Button {
                            if FileManager.default.fileExists(atPath: path) {
                                vm.setWorkspaceRootFolder(url)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.brightAmber.opacity(0.8))
                                Text(url.lastPathComponent)
                                    .appSystemFont(size: 11.5, weight: .medium)
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer()
        }
    }
}

// MARK: - Tree List (Native NSOutlineView isolated from SwiftUI selection re-evaluation)

private struct BrowserTreeContainerView: View {
    let vm: ViewStereoViewModel
    let store: WorkspaceBrowserStore
    @ObservedObject private var settings = ViewStereoSettings.shared

    var body: some View {
        ZStack {
            WorkspaceOutlineView(
                store: store,
                isLargeText: settings.useLargeTextMode,
                currentWorkspaceMode: { vm.workspaceMode },
                isBatchRunning: { vm.isBatchRunning },
                onOpenItem: { item in
                    vm.openBrowserItem(item)
                },
                onOpenForce2D: { url in
                    vm.loadSingleSBSImage(url: url, interpretationOverride: .force2D)
                },
                onOpenForceStereo: { url in
                    vm.loadSingleSBSImage(url: url, interpretationOverride: .forceStereo)
                },
                onOpenLRPair: { left, right in
                    vm.loadSeparateImages(left: left, right: right)
                },
                onBatchSelection: {
                    vm.startBatchProcessingFromBrowser()
                },
                onVerifySelection: {
                    vm.startStereoVerificationFromBrowser()
                },
                onSetRootFolder: { folder in
                    vm.setWorkspaceRootFolder(folder)
                }
            )

            BrowserEmptyOverlayView(store: store)
                .allowsHitTesting(false)
        }
    }
}

private struct BrowserEmptyOverlayView: View {
    @ObservedObject var store: WorkspaceBrowserStore

    var body: some View {
        if store.rootNodes().isEmpty && !store.isScanning {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.6))
                Text(LocalizedStringKey(store.showWarningsOnly ? "No warnings or errors recorded." : "No stereo images found in this folder."))
                    .appSystemFont(size: 11.5)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                Spacer()
            }
        }
    }
}

// MARK: - Bottom Action Bar

private struct BrowserBottomActionBar: View {
    @ObservedObject var vm: ViewStereoViewModel
    @ObservedObject var store: WorkspaceBrowserStore

    var body: some View {
        let batchCount = store.selectedBatchCount
        let selectedCount = store.selectedNodeIDs.count

        VStack(alignment: .leading, spacing: 8) {
            if vm.workspaceMode == .stereoRestore && selectedCount == 2 && store.twoSelectedUnpairedFiles() != nil {
                Button {
                    vm.openTwoSelectedAsLRPair()
                } label: {
                    Label("Open 2 Selected as L/R Pair", systemImage: "square.split.2x1")
                        .appSystemFont(size: 11, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .tint(.brightBlue)
                .disabled(vm.isBatchRunning)
            }

            if vm.isBatchRunning {
                Button {
                    vm.cancelBatchProcessing()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                        Text("\(vm.isBatchVerifyOnly ? String(localized: "Cancel Verify") : String(localized: "Cancel Batch")) (\(vm.batchCompletedCount)/\(vm.batchTotalCount))")
                            .appSystemFont(size: 11.5, weight: .bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .tint(.palestineRed)
            } else {
                VStack(spacing: 6) {
                    if vm.workspaceMode == .stereoRestore {
                        Button {
                            vm.startStereoVerificationFromBrowser()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.shield.fill")
                                Text(verifyButtonTitle(itemCount: batchCount, selectionCount: selectedCount))
                                    .appSystemFont(size: 11, weight: .semibold)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(.brightAmber)
                        .disabled(batchCount == 0 || vm.isProcessing)
                        .customTooltip(String(localized: "Check stereo alignment & warnings without exporting") + " (⇧⌘V)")
                    }

                    let is2D3D = vm.workspaceMode == .convert2DTo3D
                    let isBatchDisabled = batchCount == 0 || vm.isProcessing
                    let btnGradient: [Color] = is2D3D
                        ? [Color(red: 0.28, green: 0.22, blue: 0.82), Color(red: 0.02, green: 0.50, blue: 0.78)]
                        : [Color(red: 0.02, green: 0.47, blue: 0.34), Color(red: 0.04, green: 0.58, blue: 0.42)]
                    let btnStroke: Color = is2D3D ? .brightBlue : .brightTeal

                    Button {
                        vm.startBatchProcessingFromBrowser()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: is2D3D ? "cube.transparent.fill" : "play.fill")
                            Text(batchButtonTitle(itemCount: batchCount, selectionCount: selectedCount))
                                .appSystemFont(size: 11.5, weight: .bold)
                                .lineLimit(1)
                        }
                        .foregroundStyle(isBatchDisabled ? .white.opacity(0.4) : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(
                                    isBatchDisabled
                                        ? LinearGradient(colors: [Color.white.opacity(0.08)], startPoint: .leading, endPoint: .trailing)
                                        : LinearGradient(colors: btnGradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(isBatchDisabled ? Color.white.opacity(0.12) : btnStroke.opacity(0.75), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBatchDisabled)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func verifyButtonTitle(itemCount: Int, selectionCount: Int) -> String {
        if selectionCount == 0 {
            return String(format: String(localized: "Verify Folder (%lld)"), Int64(itemCount))
        }
        return String(format: String(localized: "Verify Selected (%lld)"), Int64(itemCount))
    }

    private func batchButtonTitle(itemCount: Int, selectionCount: Int) -> String {
        if vm.workspaceMode == .convert2DTo3D {
            if selectionCount == 0 {
                return String(format: String(localized: "Batch 2D→3D (%lld)"), Int64(itemCount))
            }
            return String(format: String(localized: "Convert Selected 2D→3D (%lld)"), Int64(itemCount))
        }
        if selectionCount == 0 {
            return String(format: String(localized: "Batch Folder (%lld)"), Int64(itemCount))
        }
        return String(format: String(localized: "Batch Selected (%lld)"), Int64(itemCount))
    }
}
