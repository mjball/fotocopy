import SwiftUI

/// Compact whole-library totals for Organize. The per-date grid remains about
/// CR3 decisions; this line covers every recognized image in every date folder.
struct LibraryImageStatisticsHeader: View {
    let statistics: LibraryImageStatistics

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                summaryLabel
                Divider().frame(height: 15)
                ForEach(LibraryImageReviewState.allCases, id: \.self) { state in
                    bucketLabel(for: state)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                summaryLabel
                HStack(spacing: 10) {
                    ForEach(LibraryImageReviewState.allCases, id: \.self) { state in
                        bucketLabel(for: state)
                    }
                }
            }
        }
        .font(.subheadline)
    }

    private var summaryLabel: some View {
        HStack(spacing: 5) {
            Text("Library")
                .fontWeight(.semibold)
            Text("\(statistics.totalImageCount.formatted()) images")
            Text(ByteCountFormatter.string(fromByteCount: Int64(statistics.totalByteCount), countStyle: .file))
                .foregroundStyle(.secondary)
        }
    }

    private func bucketLabel(for state: LibraryImageReviewState) -> some View {
        let bucket = statistics.bucket(for: state)
        return HStack(spacing: 4) {
            Image(systemName: symbolName(for: state))
            Text("\(bucket.imageCount.formatted()) \(state.title.lowercased()) · \(statistics.percentage(for: state))%")
            Text(ByteCountFormatter.string(fromByteCount: Int64(bucket.byteCount), countStyle: .file))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(color(for: state))
    }
}

/// Uses the blank lower section of the Full Cull inspector so the live totals
/// remain available while the preview keeps its existing vertical room.
struct CullLibraryStatisticsInspector: View {
    @Bindable var model: CullViewModel

    var body: some View {
        Group {
            if let statistics = model.libraryImageStatistics {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    Text("Library")
                        .font(.caption.weight(.semibold))
                    Text("\(statistics.totalImageCount.formatted()) images · \(ByteCountFormatter.string(fromByteCount: Int64(statistics.totalByteCount), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(LibraryImageReviewState.allCases, id: \.self) { state in
                            bucket(for: state, statistics: statistics)
                        }
                    }
                }
            } else if model.isScanningLibraryImageStatistics {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading library…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let error = model.libraryImageStatisticsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bucket(for state: LibraryImageReviewState, statistics: LibraryImageStatistics) -> some View {
        let bucket = statistics.bucket(for: state)
        return VStack(alignment: .leading, spacing: 2) {
            Text(state.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color(for: state))
            Text("\(bucket.imageCount.formatted()) · \(statistics.percentage(for: state))%")
                .font(.caption.weight(.semibold))
            Text(ByteCountFormatter.string(fromByteCount: Int64(bucket.byteCount), countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 7)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(color(for: state))
                .frame(width: 2)
        }
    }
}

private func color(for state: LibraryImageReviewState) -> Color {
    switch state {
    case .unrated: return .orange
    case .kept: return .green
    case .rejected: return .red
    }
}

private func symbolName(for state: LibraryImageReviewState) -> String {
    switch state {
    case .unrated: return "circle"
    case .kept: return "checkmark.circle.fill"
    case .rejected: return "xmark.circle.fill"
    }
}
