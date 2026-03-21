import SwiftUI

struct SummaryView: View {
    let progress: ImportProgress
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Summary")
                .font(.title2)
                .fontWeight(.semibold)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Files imported:")
                        .foregroundStyle(.secondary)
                    Text("\(progress.processedFiles - progress.duplicatesSkipped - progress.errors.count)")
                        .fontWeight(.medium)
                }
                GridRow {
                    Text("Duplicates skipped:")
                        .foregroundStyle(.secondary)
                    Text("\(progress.duplicatesSkipped)")
                        .fontWeight(.medium)
                }
                if !progress.errors.isEmpty {
                    GridRow {
                        Text("Errors:")
                            .foregroundStyle(.secondary)
                        Text("\(progress.errors.count)")
                            .fontWeight(.medium)
                            .foregroundStyle(.red)
                    }
                }
            }

            if !progress.fallbackDateFiles.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(progress.fallbackDateFiles.count) file(s) used filesystem date (no EXIF data)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(progress.fallbackDateFiles, id: \.self) { file in
                                Text(file)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }

            if !progress.errors.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("Errors", systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                        .font(.callout)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(progress.errors.enumerated()), id: \.offset) { _, error in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(error.file)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text(error.message)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 400)
    }
}
