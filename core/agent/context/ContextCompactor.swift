import Foundation

public struct ContextCompactionConfig: Codable, Equatable, Sendable {
    public var contextWindowTokens: Int
    public var compactionThreshold: Double
    public var rawTailRatio: Double

    public static let defaultValue = ContextCompactionConfig(
        contextWindowTokens: 8_192,
        compactionThreshold: 0.8,
        rawTailRatio: 0.2
    )
}

public struct ContextCompactor: Sendable {
    public let config: ContextCompactionConfig

    public init(config: ContextCompactionConfig = .defaultValue) {
        self.config = config
    }

    public func shouldCompact(estimatedTokens: Int) -> Bool {
        Double(estimatedTokens) >= Double(config.contextWindowTokens) * config.compactionThreshold
    }
}
