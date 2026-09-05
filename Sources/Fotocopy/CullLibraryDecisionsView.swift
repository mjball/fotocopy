import SwiftUI

/// A library-wide review over ordinary Fotocopy folders. This view reads the
/// current Import destination every time it refreshes; it has no independent
/// catalog or sidecar database.
struct CullLibraryDecisionsView: View {
    @Bindable var model: CullViewModel
    @AppStorage(PreferenceKeys.destinationPath) private var configuredLibraryPath = ""
    @State private var filter: CullLibraryDecisionFilter = .all
    @State private var dateFilter: String?
    @State private var filenameQuery = ""

    private var scan: CullLibraryDecisionScan? { model.libraryDecisionScan }

    private var filteredDecisions: [CullLibraryDecision] {
        guard let scan else { return [] }
        let normalizedQuery = filenameQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return scan.decisions.filter { decision in
            filter.includes(decision)
                && (dateFilter == nil || decision.dateLabel == dateFilter)
                && (normalizedQuery.isEmpty || decision.filename.lowercased().contains(normalizedQuery))
        }
    }

    private var dateLabels: [String] {
        Array(Set(scan?.decisions.map(\.dateLabel) ?? [])).sorted(by: >)
    }

    private var groups: [(dateLabel: String, decisions: [CullLibraryDecision])] {
        let byDate = Dictionary(grouping: filteredDecisions, by: \.dateLabel)
        return byDate.keys.sorted(by: >).map { dateLabel in
            (dateLabel, byDate[dateLabel] ?? [])
        }
    }

    var body: some View {
        Group {
            if model.isScanningLibraryDecisions, scan == nil {
                VStack(spacing: 8) {
                    ProgressView("Reading Organize")
                    Text(model.libraryScanStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let scan {
                decisionsView(scan)
            } else {
                ContentUnavailableView(
                    "No Fotocopy library selected",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text(model.libraryDecisionError ?? "Set an Import destination, then Organize can review its Keeps and Rejects folders."))
            }
        }
        .task {
            model.refreshLibraryDecisionsIfNeeded()
            model.refreshLibraryImageStatisticsIfNeeded()
        }
        .onChange(of: configuredLibraryPath) { _, _ in
            model.refreshLibraryDecisions()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refreshLibraryDecisions()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
                .disabled(model.isScanningLibraryDecisions || model.isTrashingLibraryRejects)
            }
        }
        .sheet(item: $model.pendingLibraryTrashPlan) { plan in
            CullTrashConfirmationSheet(plan: plan) {
                model.trashLibraryRejects(using: plan)
            }
        }
    }

    private func decisionsView(_ scan: CullLibraryDecisionScan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(scan)
                filters

                if model.isScanningLibraryDecisions || model.isTrashingLibraryRejects {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.libraryScanStatus)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = model.libraryDecisionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                if let result = model.libraryTrashResult {
                    trashResultBanner(result)
                }

                if filter == .rejected, scan.rejectedCount > 0 {
                    Button(role: .destructive) {
                        model.prepareLibraryTrash()
                    } label: {
                        Label("Move all \(scan.rejectedCount) Reject\(scan.rejectedCount == 1 ? "" : "s") to Trash…", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.isScanningLibraryDecisions || model.isTrashingLibraryRejects)
                    .help("Rechecks the direct Rejects folders, then asks once before using Finder's Trash")
                }

                if groups.isEmpty {
                    ContentUnavailableView(
                        "No matching decisions",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Try another decision, date, or filename filter."))
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ForEach(groups, id: \.dateLabel) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(group.dateLabel)
                                    .font(.title3.weight(.semibold))
                                Text("\(group.decisions.count) decision\(group.decisions.count == 1 ? "" : "s")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(ByteCountFormatter.string(
                                    fromByteCount: Int64(group.decisions.reduce(0) { $0 + $1.byteCount }),
                                    countStyle: .file
                                ))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }

                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 176, maximum: 250), spacing: 14)],
                                alignment: .leading,
                                spacing: 14
                            ) {
                                ForEach(group.decisions) { decision in
                                    CullLibraryDecisionCard(
                                        decision: decision,
                                        reveal: { model.revealLibraryDecision(decision) },
                                        openDate: { model.openDecisionDate(decision) }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func header(_ scan: CullLibraryDecisionScan) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Organize")
                .font(.largeTitle.weight(.semibold))
            Text(scan.libraryRootURL.path)
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(scan.libraryRootURL.path)
            if let statistics = model.libraryImageStatistics {
                LibraryImageStatisticsHeader(statistics: statistics)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading whole library…")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Picker("Decisions", selection: $filter) {
                ForEach(CullLibraryDecisionFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 380)

            Menu {
                Button("All dates") { dateFilter = nil }
                Divider()
                ForEach(dateLabels, id: \.self) { dateLabel in
                    Button(dateLabel) { dateFilter = dateLabel }
                }
            } label: {
                Label(dateFilter ?? "All dates", systemImage: "calendar")
            }
            .menuStyle(.borderedButton)

            TextField("Filename", text: $filenameQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Spacer()
        }
    }

    private func trashResultBanner(_ result: CullLibraryTrashResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.trashedPrimaryPhotoCount > 0 {
                Label(
                    "Moved \(result.trashedPrimaryPhotoCount) rejected photo\(result.trashedPrimaryPhotoCount == 1 ? "" : "s") and \(result.trashedCompanionFileCount) companion file\(result.trashedCompanionFileCount == 1 ? "" : "s") to Finder’s Trash.",
                    systemImage: "trash.circle.fill"
                )
                .foregroundStyle(.secondary)
            }
            Text("Restore anything through Finder’s Trash. On an external library, Finder may use that volume’s Trash.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !result.failures.isEmpty {
                HStack {
                    Label("\(result.failures.count) package\(result.failures.count == 1 ? "" : "s") need attention.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Reveal failures") { model.revealLibraryTrashFailures() }
                        .buttonStyle(.link)
                }
                ForEach(result.failures.prefix(3)) { failure in
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let manifestError = result.manifestError {
                Label(manifestError, systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.subheadline)
        .padding(12)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CullLibraryDecisionCard: View {
    let decision: CullLibraryDecision
    let reveal: () -> Void
    let openDate: () -> Void

    private var isKept: Bool { decision.disposition == .select }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                CullPreviewView(url: decision.rawURL, size: .thumbnail)
                    .frame(height: 128)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(isKept ? "Kept" : "Rejected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(isKept ? .green : .red, in: Capsule())
                    .padding(7)
            }
            Text(decision.filename)
                .font(.caption.monospaced())
                .lineLimit(1)
            Text("\(decision.dateLabel) · \(decision.companionFileCount) sidecar\(decision.companionFileCount == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack {
                Button("Finder", action: reveal)
                Button("Open day", action: openDate)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Reveal in Finder", action: reveal)
            Button("Open date in Cull", action: openDate)
        }
    }
}

private struct CullTrashConfirmationSheet: View {
    let plan: CullLibraryTrashPlan
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Move Rejects to Finder’s Trash?", systemImage: "trash")
                .font(.title2.weight(.semibold))
            Text("Fotocopy just rechecked these direct Rejects folders. This sends the photo packages to Finder’s Trash; it never permanently deletes them.")
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow { Text("Photos").foregroundStyle(.secondary); Text("\(plan.primaryPhotoCount)") }
                GridRow { Text("Companion files").foregroundStyle(.secondary); Text("\(plan.companionFileCount)") }
                GridRow { Text("Total size").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount: Int64(plan.totalBytes), countStyle: .file)) }
                GridRow { Text("Dates").foregroundStyle(.secondary); Text(plan.affectedDateLabels.joined(separator: ", ")) }
            }
            Text("To restore anything, use Finder’s Trash. An external library may use the external volume’s Finder Trash.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Move to Trash", role: .destructive) {
                    dismiss()
                    confirm()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
