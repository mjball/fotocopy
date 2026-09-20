import Foundation

enum CullFolderRecommendationReason: String, Sendable, Equatable {
    case current
    case largeOpportunity
    case closeToDone
    case aging
    case resume
    case largestBacklog
    case newest
}

struct CullFolderRecommendation: Identifiable, Sendable, Equatable {
    let folderURL: URL
    let reason: CullFolderRecommendationReason

    var id: URL { folderURL }
}

struct CullFolderRecommendationRow: Identifiable, Sendable, Equatable {
    let summary: CullFolderReviewSummary
    let reason: CullFolderRecommendationReason

    var id: URL { summary.folderURL }
}

struct CullFolderRecommendationSet: Sendable, Equatable {
    var recommended: [CullFolderRecommendation]
    var remainingFolderURLs: [URL]

    static let empty = CullFolderRecommendationSet(
        recommended: [],
        remainingFolderURLs: []
    )
}

/// Builds a deliberately varied review queue from the shallow folder summary.
/// Stage-one reasons use only counts, dates, and local activity; no RAW file is
/// opened merely to decide which folders appear in the sidebar.
enum CullFolderRecommendationEngine {
    static let defaultLimit = 10

    private static let slotReasons: [CullFolderRecommendationReason] = [
        .resume,
        .largeOpportunity,
        .closeToDone,
        .aging,
        .largestBacklog,
        .newest,
        .largeOpportunity,
        .closeToDone,
        .aging,
        .largeOpportunity
    ]

    static func recommendations(
        from summaries: [CullFolderReviewSummary],
        currentFolderURL: URL?,
        lastOpenedAt: [String: TimeInterval],
        limit: Int = defaultLimit
    ) -> CullFolderRecommendationSet {
        let candidates = summaries.filter { !$0.isReviewed }
        guard !candidates.isEmpty else { return .empty }

        let normalizedLimit = min(max(0, limit), candidates.count)
        guard normalizedLimit > 0 else {
            return CullFolderRecommendationSet(
                recommended: [],
                remainingFolderURLs: newestFirst(candidates).map(\.folderURL)
            )
        }

        var selected: [CullFolderRecommendation] = []
        var selectedURLs: Set<URL> = []

        for reason in slotReasons.prefix(normalizedLimit) {
            guard let summary = orderedCandidates(
                for: reason,
                from: candidates,
                lastOpenedAt: lastOpenedAt
            ).first(where: { !selectedURLs.contains($0.folderURL) }) else {
                continue
            }
            selected.append(CullFolderRecommendation(folderURL: summary.folderURL, reason: reason))
            selectedURLs.insert(summary.folderURL)
        }

        if selected.count < normalizedLimit {
            for summary in newestFirst(candidates) where !selectedURLs.contains(summary.folderURL) {
                selected.append(CullFolderRecommendation(folderURL: summary.folderURL, reason: .newest))
                selectedURLs.insert(summary.folderURL)
                if selected.count == normalizedLimit { break }
            }
        }

        if let currentFolderURL = currentFolderURL?.standardizedFileURL,
           candidates.contains(where: { $0.folderURL == currentFolderURL }),
           !selectedURLs.contains(currentFolderURL) {
            if selected.count == normalizedLimit, let removed = selected.popLast() {
                selectedURLs.remove(removed.folderURL)
            }
            selected.insert(
                CullFolderRecommendation(folderURL: currentFolderURL, reason: .current),
                at: 0
            )
            selectedURLs.insert(currentFolderURL)
        }

        let remaining = newestFirst(candidates)
            .map(\.folderURL)
            .filter { !selectedURLs.contains($0) }
        return CullFolderRecommendationSet(
            recommended: selected,
            remainingFolderURLs: remaining
        )
    }

    private static func orderedCandidates(
        for reason: CullFolderRecommendationReason,
        from candidates: [CullFolderReviewSummary],
        lastOpenedAt: [String: TimeInterval]
    ) -> [CullFolderReviewSummary] {
        switch reason {
        case .current:
            return candidates
        case .largeOpportunity, .largestBacklog:
            return candidates.sorted {
                if $0.unreviewedCount != $1.unreviewedCount {
                    return $0.unreviewedCount > $1.unreviewedCount
                }
                return newestTieBreak($0, $1)
            }
        case .closeToDone:
            return candidates.sorted {
                if $0.unreviewedCount != $1.unreviewedCount {
                    return $0.unreviewedCount < $1.unreviewedCount
                }
                let leftProgress = completionFraction($0)
                let rightProgress = completionFraction($1)
                if leftProgress != rightProgress { return leftProgress > rightProgress }
                return oldestTieBreak($0, $1)
            }
        case .aging:
            return candidates.sorted(by: oldestTieBreak)
        case .resume:
            return candidates
                .filter { $0.unreviewedCount < $0.totalCount }
                .sorted {
                    let leftActivity = lastOpenedAt[$0.folderURL.path] ?? 0
                    let rightActivity = lastOpenedAt[$1.folderURL.path] ?? 0
                    if leftActivity != rightActivity { return leftActivity > rightActivity }
                    let leftProgress = completionFraction($0)
                    let rightProgress = completionFraction($1)
                    if leftProgress != rightProgress { return leftProgress > rightProgress }
                    return newestTieBreak($0, $1)
                }
        case .newest:
            return newestFirst(candidates)
        }
    }

    private static func newestFirst(
        _ candidates: [CullFolderReviewSummary]
    ) -> [CullFolderReviewSummary] {
        candidates.sorted(by: newestTieBreak)
    }

    private static func completionFraction(_ summary: CullFolderReviewSummary) -> Double {
        guard summary.totalCount > 0 else { return 0 }
        return Double(summary.totalCount - summary.unreviewedCount) / Double(summary.totalCount)
    }

    private static func newestTieBreak(
        _ lhs: CullFolderReviewSummary,
        _ rhs: CullFolderReviewSummary
    ) -> Bool {
        lhs.folderURL.path.localizedStandardCompare(rhs.folderURL.path) == .orderedDescending
    }

    private static func oldestTieBreak(
        _ lhs: CullFolderReviewSummary,
        _ rhs: CullFolderReviewSummary
    ) -> Bool {
        lhs.folderURL.path.localizedStandardCompare(rhs.folderURL.path) == .orderedAscending
    }
}
