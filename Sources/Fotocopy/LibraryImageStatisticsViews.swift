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
/// remain available while the preview keeps its existing vertical room. A
/// distribution bar makes the state of a large library immediately scannable
/// without repeating a tall, chart-like list beside the photo.
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
                    distributionBar(statistics: statistics)
                    HStack(alignment: .top, spacing: 7) {
                        ForEach(LibraryImageReviewState.allCases, id: \.self) { state in
                            bucketSummary(for: state, statistics: statistics)
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

    private func distributionBar(statistics: LibraryImageStatistics) -> some View {
        GeometryReader { proxy in
            let statesWithImages = LibraryImageReviewState.allCases.filter {
                statistics.bucket(for: $0).imageCount > 0
            }
            let spacing = CGFloat(max(statesWithImages.count - 1, 0))
            let availableWidth = max(proxy.size.width - spacing, 0)

            HStack(spacing: 1) {
                ForEach(statesWithImages, id: \.self) { state in
                    let proportion = Double(statistics.bucket(for: state).imageCount) / Double(max(statistics.totalImageCount, 1))
                    Capsule()
                        .fill(color(for: state))
                        .frame(width: availableWidth * proportion)
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Library decision distribution")
        .accessibilityValue(
            LibraryImageReviewState.allCases.map {
                "\($0.title) \(statistics.percentage(for: $0)) percent"
            }.joined(separator: ", ")
        )
    }

    private func bucketSummary(for state: LibraryImageReviewState, statistics: LibraryImageStatistics) -> some View {
        let bucket = statistics.bucket(for: state)
        return VStack(alignment: .leading, spacing: 2) {
            Label(state.title, systemImage: symbolName(for: state))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color(for: state))
                .lineLimit(1)
            Text("\(bucket.imageCount.formatted()) · \(statistics.percentage(for: state))%")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(ByteCountFormatter.string(fromByteCount: Int64(bucket.byteCount), countStyle: .file))")
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
