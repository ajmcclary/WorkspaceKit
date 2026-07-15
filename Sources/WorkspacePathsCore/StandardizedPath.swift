import Foundation

private let standardizedPathSlashTrim = CharacterSet(charactersIn: "/")

public enum StandardizedPath {
	@inline(__always)
	public static func absolute(_ path: String) -> String {
		(path as NSString).standardizingPath
	}

	@inline(__always)
	public static func relative(_ path: String) -> String {
		let trimmed = path.trimmingCharacters(in: standardizedPathSlashTrim)
		guard !trimmed.isEmpty, trimmed != "." else { return "" }

		var components: [Substring] = []
		components.reserveCapacity(trimmed.split(separator: "/", omittingEmptySubsequences: true).count)
		for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
			switch component {
			case ".":
				continue
			case "..":
				if let last = components.last, last != ".." {
					components.removeLast()
				} else {
					components.append(component)
				}
			default:
				components.append(component)
			}
		}
		return components.map(String.init).joined(separator: "/")
	}

	@inline(__always)
	public static func join(standardizedRoot: String, standardizedRelativePath: String) -> String {
		guard !standardizedRelativePath.isEmpty else { return standardizedRoot }
		return standardizedRoot.hasSuffix("/")
			? standardizedRoot + standardizedRelativePath
			: standardizedRoot + "/" + standardizedRelativePath
	}

	@inline(__always)
	public static func containsNUL(_ path: String) -> Bool {
		path.unicodeScalars.contains { $0.value == 0 }
	}

	public static func diagnosticEscaped(_ path: String) -> String {
		var escaped = ""
		escaped.reserveCapacity(path.count)
		for scalar in path.unicodeScalars {
			switch scalar.value {
			case 0:
				escaped += "\\0"
			case 8:
				escaped += "\\b"
			case 9:
				escaped += "\\t"
			case 10:
				escaped += "\\n"
			case 12:
				escaped += "\\f"
			case 13:
				escaped += "\\r"
			case 0x1B:
				escaped += "\\e"
			default:
				if scalar.value < 0x20 || scalar.value == 0x7F {
					escaped += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
				} else {
					escaped.unicodeScalars.append(scalar)
				}
			}
		}
		return escaped
	}

	@inline(__always)
	public static func isDescendant(_ standardizedPath: String, of standardizedParent: String) -> Bool {
		if standardizedPath == standardizedParent { return true }
		let prefix = standardizedParent.hasSuffix("/") ? standardizedParent : standardizedParent + "/"
		return standardizedPath.hasPrefix(prefix)
	}
}

// NOTE: `StoredSelectionPathNormalization` and `GitDiffPathNormalization` were
// deliberately NOT moved into this package. They depend on `LineRange` /
// `SliceRangeMath` (workspace slice value types that remain in the app), so they
// stay in the app at Infrastructure/Utilities/StandardizedPathNormalization.swift
// and call into this pure `StandardizedPath` via `@_exported import WorkspacePaths`.
