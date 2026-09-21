import Foundation

enum CullFolderRecommendationReason: String, Sendable, Equatable {
    case current
    case highPayoff
    case quickWin
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
    let metrics: CullFolderReviewMetrics?

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

/// Builds a deliberately varied review queue. Expensive burst-aware metrics
/// improve payoff and effort ordering when available; otherwise those slots
/// retain their truthful count-only stage-one labels.
enum CullFolderRecommendationEngine {
    static let defaultLimit = 10

    private static let slotReasons: [CullFolderRecommendationReason] = [
        .resume,
        .highPayoff,
        .quickWin,
        .aging,
        .largestBacklog,
        .newest,
        .highPayoff,
        .quickWin,
        .aging,
        .highPayoff
    ]

    static func recommendations(
        from summaries: [CullFolderReviewSummary],
        currentFolderURL: URL?,
        lastOpenedAt: [String: TimeInterval],
        metricsByFolderURL: [URL: CullFolderReviewMetrics] = [:],
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

        for requestedReason in slotReasons.prefix(normalizedLimit) {
            var effectiveReason = requestedReason
            var ordered = orderedCandidates(
                for: requestedReason,
                from: candidates,
                lastOpenedAt: lastOpenedAt,
                metricsByFolderURL: metricsByFolderURL
            )
            var summary = ordered.first { !selectedURLs.contains($0.folderURL) }
            if summary == nil, requestedReason == .highPayoff {
                effectiveReason = .largeOpportunity
                ordered = orderedCandidates(
                    for: effectiveReason,
                    from: candidates,
                    lastOpenedAt: lastOpenedAt,
                    metricsByFolderURL: metricsByFolderURL
                )
                summary = ordered.first { !selectedURLs.contains($0.folderURL) }
            } else if summary == nil, requestedReason == .quickWin {
                effectiveReason = .closeToDone
                ordered = orderedCandidates(
                    for: effectiveReason,
                    from: candidates,
                    lastOpenedAt: lastOpenedAt,
                    metricsByFolderURL: metricsByFolderURL
                )
                summary = ordered.first { !selectedURLs.contains($0.folderURL) }
            }
            guard let summary else {
                continue
            }
            selected.append(CullFolderRecommendation(
                folderURL: summary.folderURL,
                reason: effectiveReason
            ))
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
        lastOpenedAt: [String: TimeInterval],
        metricsByFolderURL: [URL: CullFolderReviewMetrics]
    ) -> [CullFolderReviewSummary] {
        switch reason {
        case .current:
            return candidates
        case .highPayoff:
            return candidates
                .filter { metricsByFolderURL[$0.folderURL] != nil }
                .sorted {
                    guard let leftMetrics = metricsByFolderURL[$0.folderURL],
                          let rightMetrics = metricsByFolderURL[$1.folderURL] else {
                        return newestTieBreak($0, $1)
                    }
                    if leftMetrics.payoffPerEffort != rightMetrics.payoffPerEffort {
                        return leftMetrics.payoffPerEffort > rightMetrics.payoffPerEffort
                    }
                    if $0.unreviewedCount != $1.unreviewedCount {
                        return $0.unreviewedCount > $1.unreviewedCount
                    }
                    return newestTieBreak($0, $1)
                }
        case .quickWin:
            return candidates
                .filter { metricsByFolderURL[$0.folderURL] != nil }
                .sorted {
                    guard let leftMetrics = metricsByFolderURL[$0.folderURL],
                          let rightMetrics = metricsByFolderURL[$1.folderURL] else {
                        return oldestTieBreak($0, $1)
                    }
                    if leftMetrics.estimatedEffort != rightMetrics.estimatedEffort {
                        return leftMetrics.estimatedEffort < rightMetrics.estimatedEffort
                    }
                    let leftProgress = completionFraction($0)
                    let rightProgress = completionFraction($1)
                    if leftProgress != rightProgress { return leftProgress > rightProgress }
                    return oldestTieBreak($0, $1)
                }
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
                    let leftEffort = metricsByFolderURL[$0.folderURL]?.estimatedEffort
                    let rightEffort = metricsByFolderURL[$1.folderURL]?.estimatedEffort
                    if let leftEffort, let rightEffort, leftEffort != rightEffort {
                        return leftEffort < rightEffort
                    }
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
