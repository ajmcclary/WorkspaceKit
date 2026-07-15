import Foundation

/// Pure string-based relative path computation (no filesystem I/O).
public enum RelativePath {
	@inline(__always)
	public static func from(absolutePath: String, rootPath: String, caseInsensitive: Bool = false) -> String {
		let abs = (absolutePath as NSString).standardizingPath
		let root = (rootPath as NSString).standardizingPath
		return fromStandardized(
			standardizedAbsolutePath: abs,
			standardizedRootPath: root,
			caseInsensitive: caseInsensitive
		)
	}

	@inline(__always)
	public static func fromStandardized(
		standardizedAbsolutePath abs: String,
		standardizedRootPath root: String,
		caseInsensitive: Bool = false
	) -> String {
		guard !root.isEmpty else { return abs }
		if abs == root { return "" }

		// Boundary-safe prefix match (prevents "/a/bc" being treated as inside "/a/b").
		let rootPrefix = root.hasSuffix("/") ? root : root + "/"
		if abs.hasPrefix(rootPrefix) {
			return String(abs.dropFirst(rootPrefix.count))
		}
		// Case-insensitive fallback (e.g. case-insensitive APFS, where a stored root's
		// case can differ from an enumerated child path). ASCII/Unicode lowercasing
		// preserves prefix length, so slice on the ORIGINAL-length prefix.
		if caseInsensitive {
			if abs.lowercased() == root.lowercased() { return "" }
			if abs.lowercased().hasPrefix(rootPrefix.lowercased()) {
				return String(abs.dropFirst(rootPrefix.count))
			}
		}
		// Outside root -> match previous behavior (return absolute).
		return abs
	}
}
