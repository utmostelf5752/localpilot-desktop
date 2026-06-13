import Foundation

/// Rolling, bounded record of what the agent has done so far.
///
/// This is the source of truth the planner sees instead of the full chat log.
/// It deliberately stays short and fresh: only the newest `maxRecent` step
/// results are kept raw, older steps collapse into a single rolling summary,
/// and image/base64 payloads are never stored here.
public struct AgentHistory: Sendable, Equatable {
    /// Short rolling summary of older steps. Never authoritative on its own.
    public var compactedSummary: String
    /// Capped raw tail of recent step result strings (no base64/image data).
    public var recentSteps: [String]

    /// Hard cap on a single stored step string, so an oversized result (e.g. a
    /// pasted screenshot summary) can never bloat the history.
    private static let maxStepLength = 2_000

    public init(compactedSummary: String = "", recentSteps: [String] = []) {
        self.compactedSummary = compactedSummary
        self.recentSteps = recentSteps
    }

    /// Append a step result, then compact any overflow beyond `maxRecent` into
    /// the rolling summary. Long step strings are truncated before storage.
    public mutating func record(_ step: String, compactor: ContextCompactor, maxRecent: Int) {
        let trimmed = step.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let bounded = trimmed.count > Self.maxStepLength
            ? String(trimmed.prefix(Self.maxStepLength)) + "…"
            : trimmed
        recentSteps.append(bounded)

        let result = compactor.compact(
            recentSteps: recentSteps,
            maxKeep: maxRecent,
            existingSummary: compactedSummary
        )
        compactedSummary = result.summary
        recentSteps = result.kept
    }

    /// True when the history carries no recorded work yet.
    public var isEmpty: Bool {
        compactedSummary.isEmpty && recentSteps.isEmpty
    }
}
