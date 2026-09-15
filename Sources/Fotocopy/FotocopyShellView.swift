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
        case .cullBursts: return "Photo Cull"
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

/// A focused review target is selectable beneath Cull. App-level tasks render
/// their active state independently, so Cull can remain active while a burst
/// or the single-frame queue is selected below it.
enum FotocopySidebarDestination: Hashable {
    case burst(URL)
    case singleFrames
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
                if cullModel.folderURL != nil {
                    if #available(macOS 26.0, *) {
                        CullPrimaryToolbarContent(
                            layout: $cullReviewLayout,
                            model: cullModel
                        )
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        CullPrimaryToolbarContent(
                            layout: $cullReviewLayout,
                            model: cullModel
                        )
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    ExternalDriveTemperatureToolbarStatus(monitor: driveTemperatureMonitor)
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
        .onChange(of: cullModel.selectedReviewGroupID) { _, groupID in
            guard workspace == .cullBursts, let groupID else { return }
            sidebarSelection = sidebarDestination(for: groupID)
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
            .task(id: cullModel.selectedReviewGroupID) {
                await scrollSelectedReviewGroupIntoView(cullModel.selectedReviewGroupID, using: proxy)
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
            CullLibraryDecisionsView(
                library: cullModel.library,
                openDate: { cullModel.requestUse(folder: $0.dateFolderURL) }
            )
        }
    }

    private func applySidebarSelection(_ selection: FotocopySidebarDestination?) {
        guard let selection else { return }

        switch selection {
        case .burst(let burstID):
            workspace = .cullBursts
            cullModel.selectReviewGroup(withID: .burst(burstID))
        case .singleFrames:
            workspace = .cullBursts
            cullModel.showSingleFrameCulling()
        }
    }

    private func synchronizeSidebarSelectionWithWorkspace() {
        let storedWorkspace = workspace
        if storedWorkspace == .cullBursts {
            if let groupID = cullModel.selectedReviewGroupID {
                sidebarSelection = sidebarDestination(for: groupID)
                return
            }
        }
        sidebarSelection = nil
    }

    /// Mirror vertical keyboard navigation in the sidebar so the selected
    /// review group remains visible while photographers review a long shoot.
    private func scrollSelectedReviewGroupIntoView(
        _ groupID: CullReviewGroupID?,
        using proxy: ScrollViewProxy
    ) async {
        guard let groupID, workspace == .cullBursts else { return }
        await Task.yield()
        guard !Task.isCancelled, cullModel.selectedReviewGroupID == groupID else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            proxy.scrollTo(sidebarDestination(for: groupID), anchor: .center)
        }
    }

    private func sidebarDestination(for groupID: CullReviewGroupID) -> FotocopySidebarDestination {
        switch groupID {
        case let .burst(burstID): .burst(burstID)
        case .singleFrames: .singleFrames
        }
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

private enum CullFolderNavigationDirection {
    case previous
    case next

    var symbolName: String {
        switch self {
        case .previous: "chevron.backward"
        case .next: "chevron.forward"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .previous: "Previous Cull Folder"
        case .next: "Next Cull Folder"
        }
    }

    var help: String {
        switch self {
        case .previous: "Previous Cull Folder (⌘[)"
        case .next: "Next Cull Folder (⌘])"
        }
    }
}

/// These are separate items for customization and accessibility, but macOS 26
/// is explicitly told not to paint its shared glass/background behind them.
private struct CullPrimaryToolbarContent: ToolbarContent {
    @Binding var layout: CullReviewLayout
    @Bindable var model: CullViewModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            CullReviewLayoutToolbarButton(layout: $layout, candidate: .browse)
        }
        ToolbarItem(placement: .primaryAction) {
            CullReviewLayoutToolbarButton(layout: $layout, candidate: .review)
        }
        ToolbarItem(placement: .primaryAction) {
            CullReviewLayoutToolbarButton(layout: $layout, candidate: .focus)
        }
        ToolbarItem(placement: .primaryAction) {
            CullFolderNavigationToolbarButton(model: model, direction: .previous)
        }
        ToolbarItem(placement: .primaryAction) {
            CullFolderNavigationToolbarButton(model: model, direction: .next)
        }
        ToolbarItem(placement: .primaryAction) {
            CullScanToolbarControl(model: model)
        }
    }
}

private struct CullScanToolbarControl: View {
    @Bindable var model: CullViewModel

    var body: some View {
        if model.isScanning {
            Button {
                model.cancel()
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .buttonStyle(CullToolbarActionButtonStyle())
            .help("Cancel the current photo scan")
        } else {
            Button {
                model.scan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(CullToolbarActionButtonStyle())
            .disabled(model.isMoving)
            .help("Scan this folder again for bursts and single frames, then refresh the whole-library summary")
        }
    }
}

/// Independent native toolbar items keep macOS from adding a group bezel around
/// the pair of arrows. Their names and shortcuts remain available in help.
private struct CullFolderNavigationToolbarButton: View {
    @Bindable var model: CullViewModel
    let direction: CullFolderNavigationDirection

    var body: some View {
        Button {
            model.moveCullFolder(by: direction == .previous ? -1 : 1)
        } label: {
            Image(systemName: direction.symbolName)
        }
        .buttonStyle(CullToolbarIconButtonStyle())
        .accessibilityLabel(direction.accessibilityLabel)
        .help(direction.help)
        .disabled(direction == .previous ? !model.canNavigatePreviousCullFolder : !model.canNavigateNextCullFolder)
    }
}

/// The picker uses individual items rather than a custom grouped view so the
/// system doesn't surround it with a second, much larger rounded bezel.
private struct CullReviewLayoutToolbarButton: View {
    @Binding var layout: CullReviewLayout
    let candidate: CullReviewLayout

    var body: some View {
        Button {
            layout = candidate
        } label: {
            Text(candidate.title)
                .font(.caption.weight(candidate == layout ? .semibold : .regular))
                .frame(width: 64, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(CullToolbarTextButtonStyle(isSelected: candidate == layout))
        .accessibilityLabel("\(candidate.title) review layout")
        .accessibilityAddTraits(candidate == layout ? .isSelected : [])
        .help("Choose how much surrounding UI is shown while reviewing bursts")
    }
}

private enum CullToolbarControlMetrics {
    static let cornerRadius: CGFloat = 8
}

private struct CullToolbarTextButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: CullToolbarControlMetrics.cornerRadius, style: .continuous)
                    .fill(isSelected || configuration.isPressed ? .tertiary : .quaternary)
            }
            .overlay {
                RoundedRectangle(cornerRadius: CullToolbarControlMetrics.cornerRadius, style: .continuous)
                    .stroke(.separator.opacity(0.55), lineWidth: 1)
            }
    }
}

private struct CullToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .contentShape(RoundedRectangle(cornerRadius: CullToolbarControlMetrics.cornerRadius, style: .continuous))
            .background {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: CullToolbarControlMetrics.cornerRadius, style: .continuous)
                        .fill(.tertiary)
                }
            }
    }
}

private struct CullToolbarActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(RoundedRectangle(cornerRadius: CullToolbarControlMetrics.cornerRadius, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: CullToolbarControlMetrics.cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? .tertiary : .quaternary)
            }
            .overlay {
                RoundedRectangle(cornerRadius: CullToolbarControlMetrics.cornerRadius, style: .continuous)
                    .stroke(.separator.opacity(0.55), lineWidth: 1)
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
