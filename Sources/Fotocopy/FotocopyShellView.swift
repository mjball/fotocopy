import SwiftUI

enum FotocopyWorkspace: String, CaseIterable, Identifiable {
    case importPhotos
    case cullBursts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .importPhotos: return "Import"
        case .cullBursts: return "Cull"
        }
    }

    var windowTitle: String {
        switch self {
        case .importPhotos: return "Photo Import"
        case .cullBursts: return "Burst Cull"
        }
    }

    var symbolName: String {
        switch self {
        case .importPhotos: return "square.and.arrow.down"
        case .cullBursts: return "rectangle.stack"
        }
    }
}

/// One selection type lets the native sidebar highlight both app workspaces
/// and the burst currently under review without introducing nested split views.
enum FotocopySidebarDestination: Hashable {
    case workspace(FotocopyWorkspace)
    case burst(URL)
}

/// Keeps Fotocopy file-first: Import and Cull are two views over ordinary
/// folders, rather than separate applications or a managed photo library.
struct FotocopyShellView: View {
    @AppStorage(PreferenceKeys.activeWorkspace) private var workspaceRaw = FotocopyWorkspace.importPhotos.rawValue
    @State private var cullModel = CullViewModel()
    @State private var sidebarSelection: FotocopySidebarDestination?

    private var workspace: FotocopyWorkspace {
        get { FotocopyWorkspace(rawValue: workspaceRaw) ?? .importPhotos }
        nonmutating set { workspaceRaw = newValue.rawValue }
    }

    var body: some View {
        NavigationSplitView {
            workspaceSidebar
        } detail: {
            workspaceDetail
        }
        .navigationTitle(workspace.windowTitle)
        .onAppear {
            CullApplicationLifecycle.activeModel = cullModel
            if sidebarSelection == nil {
                sidebarSelection = .workspace(workspace)
            }
        }
        .onChange(of: sidebarSelection) { _, selection in
            applySidebarSelection(selection)
        }
        .onChange(of: workspaceRaw) { previousRawValue, currentRawValue in
            guard let previousWorkspace = FotocopyWorkspace(rawValue: previousRawValue),
                  let currentWorkspace = FotocopyWorkspace(rawValue: currentRawValue),
                  previousWorkspace == .cullBursts,
                  currentWorkspace != .cullBursts,
                  cullModel.hasPendingCullChanges else {
                synchronizeSidebarSelectionWithWorkspace()
                return
            }

            // App menu commands write the workspace preference directly. Put
            // the UI back on Cull before offering the same Apply/Discard/Cancel
            // choice used by the sidebar.
            workspace = previousWorkspace
            sidebarSelection = currentCullSidebarDestination
            cullModel.requestLeavingCull(
                onContinue: {
                    workspace = currentWorkspace
                    sidebarSelection = .workspace(currentWorkspace)
                },
                onCancel: {
                    sidebarSelection = currentCullSidebarDestination
                }
            )
        }
        .onChange(of: cullModel.selectedBurstID) { _, burstID in
            guard workspace == .cullBursts, let burstID else { return }
            sidebarSelection = .burst(burstID)
        }
    }

    private var workspaceSidebar: some View {
        List(selection: $sidebarSelection) {
            Section("Workspaces") {
                Label(FotocopyWorkspace.importPhotos.title, systemImage: FotocopyWorkspace.importPhotos.symbolName)
                    .tag(FotocopySidebarDestination.workspace(.importPhotos))
                Label(FotocopyWorkspace.cullBursts.title, systemImage: FotocopyWorkspace.cullBursts.symbolName)
                    .tag(FotocopySidebarDestination.workspace(.cullBursts))
            }

            if workspace == .cullBursts {
                CullSidebarSections(model: cullModel)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 210, ideal: 255, max: 340)
    }

    @ViewBuilder
    private var workspaceDetail: some View {
        switch workspace {
        case .importPhotos:
            ContentView()
        case .cullBursts:
            CullWorkspaceView(model: cullModel)
        }
    }

    private func applySidebarSelection(_ selection: FotocopySidebarDestination?) {
        guard let selection else { return }

        switch selection {
        case .workspace(let selectedWorkspace):
            guard workspace == .cullBursts,
                  selectedWorkspace != .cullBursts,
                  cullModel.hasPendingCullChanges else {
                workspace = selectedWorkspace
                return
            }

            sidebarSelection = currentCullSidebarDestination
            cullModel.requestLeavingCull(
                onContinue: {
                    workspace = selectedWorkspace
                    sidebarSelection = .workspace(selectedWorkspace)
                },
                onCancel: {
                    sidebarSelection = currentCullSidebarDestination
                }
            )
        case .burst(let burstID):
            workspace = .cullBursts
            cullModel.selectedBurstID = burstID
            cullModel.syncSelectedFrame()
        }
    }

    private func synchronizeSidebarSelectionWithWorkspace() {
        let storedWorkspace = workspace
        if storedWorkspace == .cullBursts, let burstID = cullModel.selectedBurstID {
            sidebarSelection = .burst(burstID)
            return
        }
        sidebarSelection = .workspace(storedWorkspace)
    }

    private var currentCullSidebarDestination: FotocopySidebarDestination {
        if let burstID = cullModel.selectedBurstID {
            return .burst(burstID)
        }
        return .workspace(.cullBursts)
    }
}
