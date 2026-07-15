import Foundation

public struct RepoSearchQuery: Sendable, Equatable {
	public let raw: String
	public let lowered: String
	public let hasSlash: Bool
	public let isWildcard: Bool

	public var isEmpty: Bool {
		raw.isEmpty
	}
}

public enum RepoSearchQueryFactory {
	public static let defaultMaxLength = 1_000

	public static func make(
		_ input: String,
		maxLength: Int = defaultMaxLength,
		supportsWildcards: Bool = true
	) -> RepoSearchQuery {
		let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
		let bounded: String
		if trimmed.count > maxLength {
			bounded = String(trimmed.prefix(maxLength))
		} else {
			bounded = trimmed
		}

		let normalized: String
		if supportsWildcards {
			normalized = bounded
		} else {
			normalized = bounded
				.replacingOccurrences(of: "*", with: "")
				.replacingOccurrences(of: "?", with: "")
				.trimmingCharacters(in: .whitespacesAndNewlines)
		}

		let lowered = normalized.lowercased()
		return RepoSearchQuery(
			raw: normalized,
			lowered: lowered,
			hasSlash: normalized.contains("/"),
			isWildcard: supportsWildcards && (normalized.contains("*") || normalized.contains("?"))
		)
	}
}
