import Foundation

public struct ContextCompactionConfig: Codable, Equatable, Sendable {
    public var contextWindowTokens: Int
    public var compactionThreshold: Double
    public var rawTailRatio: Double

    public static let defaultValue = ContextCompactionConfig(
        contextWindowTokens: 131_072,
        compactionThreshold: 0.8,
        rawTailRatio: 0.2
    )

    public init(contextWindowTokens: Int, compactionThreshold: Double, rawTailRatio: Double) {
        self.contextWindowTokens = contextWindowTokens
        self.compactionThreshold = compactionThreshold
        self.rawTailRatio = rawTailRatio
    }
}

/// Keeps the model context fresh, short, and free of stale history.
///
/// The budget can be large (see `AppSettings.maximumContextWindowSize`), but
/// the compactor guarantees the actual payload stays small: old steps collapse
/// into a one-line rolling summary and only the newest steps are kept raw.
/// Image/screenshot payloads are never retained here — only the latest
/// observation summary is ever surfaced to the model (see `AgentContextBuilder`).
public struct ContextCompactor: Sendable {
    public let config: ContextCompactionConfig

    public init(config: ContextCompactionConfig = .defaultValue) {
        self.config = config
    }

    public func shouldCompact(estimatedTokens: Int) -> Bool {
        Double(estimatedTokens) >= Double(config.contextWindowTokens) * config.compactionThreshold
    }

    /// Cheap, dependency-free token estimate (~4 chars per token).
    public func estimateTokens(_ text: String) -> Int {
        max(0, text.count / 4)
    }

    /// Collapse all but the newest `maxKeep` step strings into a single short
    /// summary line, returning the rolling summary plus the raw tail to keep.
    ///
    /// `existingSummary` is folded in so summaries compound rather than reset.
    public func compact(
        recentSteps: [String],
        maxKeep: Int,
        existingSummary: String = ""
    ) -> (summary: String, kept: [String]) {
        guard recentSteps.count > maxKeep else {
            return (existingSummary, recentSteps)
        }

        let overflow = Array(recentSteps.dropLast(maxKeep))
        let kept = Array(recentSteps.suffix(maxKeep))
        let condensed = overflow
            .map { Self.condense($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")

        var parts: [String] = []
        if !existingSummary.isEmpty { parts.append(existingSummary) }
        if !condensed.isEmpty {
            parts.append("Earlier: \(condensed) (\(overflow.count) earlier steps summarized)")
        }
        return (parts.joined(separator: " "), kept)
    }

    private static func condense(_ step: String) -> String {
        let trimmed = step.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")
        if oneLine.count <= 120 {
            return oneLine
        }
        return String(oneLine.prefix(120)) + "…"
    }
}
