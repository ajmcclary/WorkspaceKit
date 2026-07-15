import Foundation

// Charset-detection seam (adoption slice 4). FileSystemService moved into
// WorkspaceKit, but the Cuchardet/UniversalCharsetDetection backends are
// third-party dependencies that must stay out of this zero-dependency
// package — the app injects its detector at construction. The
// Foundation-only default keeps BOM/UTF-8/fallback-table behavior intact
// and simply skips the library-backed probes (package tests exercise
// UTF-8 content only).

/// Streaming charset detector consumed chunk-by-chunk while reading a file.
public protocol WorkspaceStreamingCharsetDetector {
	@discardableResult
	func analyzeNextChunk(_ data: Data) -> Bool
	func finish() -> String?
}

/// One-shot + streaming charset detection backends.
public protocol WorkspaceCharsetDetecting: Sendable {
	/// IANA charset label for the bytes, or nil when no library backend is
	/// available (callers then fall through to Foundation heuristics).
	func detectedCharacterEncodingLabel(for data: Data) -> String?
	func makeStreamingDetector() -> any WorkspaceStreamingCharsetDetector
}

/// Default backend: no library probes; Foundation heuristics only.
public struct FoundationOnlyCharsetDetector: WorkspaceCharsetDetecting {
	public init() {}

	public func detectedCharacterEncodingLabel(for data: Data) -> String? { nil }

	public func makeStreamingDetector() -> any WorkspaceStreamingCharsetDetector {
		NoopStreamingDetector()
	}

	private final class NoopStreamingDetector: WorkspaceStreamingCharsetDetector {
		func analyzeNextChunk(_ data: Data) -> Bool { false }
		func finish() -> String? { nil }
	}
}
