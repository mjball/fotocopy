import SwiftUI

enum FotocopyWorkspace: String, CaseIterable, Identifiable {
    case importPhotos
    case cullBursts
    case organize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .importPhotos: return "Import"
        case .cullBursts: return "Cull"
        case .organize: return "Organize"
        }
    }

    var windowTitle: String {
        switch self {
        case .importPhotos: return "Photo Import"
        case .cullBursts: return "Burst Cull"
        case .organize: return "Organize Library"
        }
    }

    var symbolName: String {
        switch self {
        case .importPhotos: return "square.and.arrow.down"
        case .cullBursts: return "rectangle.stack"
        case .organize: return "checklist"
        }
    }
}

/// An individual burst is the selectable leaf within Cull. App-level tasks
/// render their active state independently, so Cull can remain active while a
/// burst is selected below it.
enum FotocopySidebarDestination: Hashable {
    case burst(URL)
}

/// Keeps Fotocopy file-first: Import and Cull are two views over ordinary
/// folders, rather than separate applications or a managed photo library.
struct FotocopyShellView: View {
    @AppStorage(PreferenceKeys.activeWorkspace) private var workspaceRaw = FotocopyWorkspace.importPhotos.rawValue
    @Bindable var cullModel: CullViewModel
    @State private var sidebarSelection: FotocopySidebarDestination?
    @Binding var cullReviewLayout: CullReviewLayout
    @Bindable var driveTemperatureMonitor: ExternalDriveTemperatureMonitor
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    private var workspace: FotocopyWorkspace {
        get { FotocopyWorkspace(rawValue: workspaceRaw) ?? .importPhotos }
        nonmutating set { workspaceRaw = newValue.rawValue }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            workspaceSidebar
        } detail: {
            workspaceDetail
        }
        .navigationTitle(workspace.windowTitle)
        .toolbar {
            if workspace == .cullBursts {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 10) {
                        if cullModel.folderURL != nil {
                            CullReviewLayoutToolbarControl(layout: $cullReviewLayout)
                            CullFolderNavigationToolbarControl(model: cullModel)
                        }

                        if cullModel.folderURL != nil, driveTemperatureMonitor.primaryReading != nil {
                            Divider()
                                .frame(height: 22)
                        }

                        ExternalDriveTemperatureToolbarStatus(monitor: driveTemperatureMonitor)

                        if cullModel.isScanning {
                            Button {
                                cullModel.cancel()
                            } label: {
                                Label("Cancel", systemImage: "xmark")
                            }
                            .labelStyle(.titleAndIcon)
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .help("Cancel the current burst scan")
                        } else if cullModel.folderURL != nil {
                            Button {
                                cullModel.scan()
                            } label: {
                                Label("Rescan", systemImage: "arrow.clockwise")
                            }
                            .labelStyle(.titleAndIcon)
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .disabled(cullModel.isMoving)
                            .help("Scan this folder again for bursts")
                        }
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    ExternalDriveTemperatureToolbarStatus(monitor: driveTemperatureMonitor)
                }
            }
        }
        .onAppear {
            if sidebarSelection == nil {
                synchronizeSidebarSelectionWithWorkspace()
            }
        }
        .onChange(of: sidebarSelection) { _, selection in
            applySidebarSelection(selection)
        }
        .onChange(of: workspaceRaw) { previousRawValue, currentRawValue in
            synchronizeSidebarSelectionWithWorkspace()
        }
        .onChange(of: cullModel.selectedBurstID) { _, burstID in
            guard workspace == .cullBursts,
                  cullModel.destination == .bursts,
                  let burstID else { return }
            sidebarSelection = .burst(burstID)
        }
        .onChange(of: cullReviewLayout) { _, layout in
            sidebarVisibility = layout == .browse ? .all : .detailOnly
        }
    }

    private var workspaceSidebar: some View {
        ScrollViewReader { proxy in
            List(selection: $sidebarSelection) {
                Section("Tasks") {
                    TaskSidebarRow(
                        task: .importPhotos,
                        isActive: workspace == .importPhotos,
                        action: activateImport
                    )
                    TaskSidebarRow(
                        task: .cullBursts,
                        isActive: workspace == .cullBursts,
                        action: activateCull
                    )
                    TaskSidebarRow(
                        task: .organize,
                        isActive: workspace == .organize,
                        action: activateOrganize
                    )
                }

                if workspace == .cullBursts {
                    CullSidebarSections(model: cullModel)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 255, max: 340)
            .task(id: cullModel.selectedBurstID) {
                await scrollSelectedBurstIntoView(cullModel.selectedBurstID, using: proxy)
            }
        }
    }

    @ViewBuilder
    private var workspaceDetail: some View {
        switch workspace {
        case .importPhotos:
            ContentView()
        case .cullBursts:
            CullWorkspaceView(model: cullModel, layout: $cullReviewLayout)
        case .organize:
            CullLibraryDecisionsView(model: cullModel)
        }
    }

    private func applySidebarSelection(_ selection: FotocopySidebarDestination?) {
        guard let selection else { return }

        switch selection {
        case .burst(let burstID):
            workspace = .cullBursts
            cullModel.destination = .bursts
            cullModel.selectedBurstID = burstID
            cullModel.syncSelectedFrame()
        }
    }

    private func synchronizeSidebarSelectionWithWorkspace() {
        let storedWorkspace = workspace
        if storedWorkspace == .cullBursts {
            if let burstID = cullModel.selectedBurstID {
                sidebarSelection = .burst(burstID)
                return
            }
        }
        sidebarSelection = nil
    }

    /// Mirror vertical keyboard navigation in the sidebar so the selected
    /// burst remains visible while photographers review a long shoot.
    private func scrollSelectedBurstIntoView(_ burstID: URL?, using proxy: ScrollViewProxy) async {
        guard let burstID, workspace == .cullBursts else { return }
        await Task.yield()
        guard !Task.isCancelled, cullModel.selectedBurstID == burstID else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            proxy.scrollTo(burstID, anchor: .center)
        }
    }

    private var currentCullSidebarDestination: FotocopySidebarDestination? {
        cullModel.selectedBurstID.map(FotocopySidebarDestination.burst)
    }

    private func activateCull() {
        cullModel.showBurstCulling()
        guard workspace != .cullBursts else { return }
        workspace = .cullBursts
    }

    private func activateOrganize() {
        cullModel.showLibraryDecisions()
        workspace = .organize
        sidebarSelection = nil
    }

    private func activateImport() {
        guard workspace != .importPhotos else { return }
        workspace = .importPhotos
        sidebarSelection = nil
    }
}

/// These compact controls stay next to the review layout because both change
/// what the culler is looking at. Their full names and shortcuts remain
/// available from the Cull menu and in the help text.
private struct CullFolderNavigationToolbarControl: View {
    @Bindable var model: CullViewModel

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.moveCullFolder(by: -1)
            } label: {
                Image(systemName: "chevron.backward")
            }
            .accessibilityLabel("Previous Cull Folder")
            .help("Previous Cull Folder (⌘[)")
            .disabled(!model.canNavigatePreviousCullFolder)

            Button {
                model.moveCullFolder(by: 1)
            } label: {
                Image(systemName: "chevron.forward")
            }
            .accessibilityLabel("Next Cull Folder")
            .help("Next Cull Folder (⌘])")
            .disabled(!model.canNavigateNextCullFolder)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityElement(children: .contain)
    }
}

/// A fixed-width control keeps Full, Compact, and Minimal visually balanced
/// in the toolbar. The native segmented picker widened and redistributed its
/// labels depending on toolbar space, which made the review controls feel
/// unstable beside the drive status.
private struct CullReviewLayoutToolbarControl: View {
    @Binding var layout: CullReviewLayout

    var body: some View {
        HStack(spacing: 7) {
            Text("View")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                ForEach(Array(CullReviewLayout.allCases.enumerated()), id: \.element.id) { index, candidate in
                    Button {
                        layout = candidate
                    } label: {
                        Text(candidate.title)
                            .font(.caption.weight(candidate == layout ? .semibold : .regular))
                            .frame(width: 64, height: 28)
                            .contentShape(Rectangle())
                            .background {
                                if candidate == layout {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(.tertiary)
                                        .padding(2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(candidate.title) review layout")
                    .accessibilityAddTraits(candidate == layout ? .isSelected : [])

                    if index < CullReviewLayout.allCases.count - 1 {
                        Rectangle()
                            .fill(.separator.opacity(0.6))
                            .frame(width: 1, height: 16)
                    }
                }
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.separator.opacity(0.55), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help("Choose how much surrounding UI is shown while reviewing bursts")
        }
    }
}

private struct TaskSidebarRow: View {
    let task: FotocopyWorkspace
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(task.title, systemImage: task.symbolName)
                .font(isActive ? .body.weight(.semibold) : .body)
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isActive ? Color.accentColor : Color.clear)
        }
    }
}
