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
            guard workspace == .cullBursts, let burstID else { return }
            sidebarSelection = .burst(burstID)
        }
    }

    private var workspaceSidebar: some View {
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
        sidebarSelection = nil
    }

    private var currentCullSidebarDestination: FotocopySidebarDestination? {
        cullModel.selectedBurstID.map(FotocopySidebarDestination.burst)
    }

    private func activateCull() {
        guard workspace != .cullBursts else { return }
        workspace = .cullBursts
    }

    private func activateImport() {
        guard workspace != .importPhotos else { return }
        workspace = .importPhotos
        sidebarSelection = nil
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
