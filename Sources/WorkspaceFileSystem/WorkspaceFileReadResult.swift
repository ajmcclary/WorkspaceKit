import Foundation

/// Outcome of reading a workspace file as text with
/// `FileSystemService.readFileContent(atRelativePath:sizeLimit:)`.
///
/// Only `.text` carries file content. Every other case is a status and must
/// never be shown, edited or written back as if it were the file: the legacy
/// string API (`loadContent(ofRelativePath:)`) encodes these statuses as
/// placeholder strings such as `"[File too large: N bytes]"`, and a caller
/// that edits and saves such a string replaces the whole file with it.
public enum WorkspaceFileReadResult: Sendable, Equatable {
	/// The decoded text. `encoding` is what the bytes were decoded with and
	/// what `editFile` will encode with; `hasByteOrderMark` records that the
	/// file starts with a Unicode byte-order mark (not included in `text`),
	/// which `editFile` re-emits.
	case text(String, encoding: String.Encoding, hasByteOrderMark: Bool)
	/// The file is larger than the read limit; nothing was decoded.
	case tooLarge(byteCount: Int64, limit: Int64)
	/// The file is binary: a known binary extension, or the content probe
	/// found binary bytes.
	case binary
	/// The bytes are not valid in the detected encoding.
	case undecodable(encoding: String.Encoding)

	/// The decoded text, or nil for every non-text outcome.
	public var text: String? {
		if case .text(let text, _, _) = self { return text }
		return nil
	}

	/// Encodes an edit using the format of the file that was read for review.
	public func encodingReplacement(_ replacement: String) throws -> Data {
		guard case .text(_, let encoding, let hasByteOrderMark) = self else {
			throw FileSystemError.failedToEditFile(CocoaError(.fileWriteInapplicableStringEncoding))
		}
		return try Self.encode(replacement, using: encoding, hasByteOrderMark: hasByteOrderMark)
	}

	static func encode(_ text: String, using encoding: String.Encoding, hasByteOrderMark: Bool) throws -> Data {
		guard let data = text.data(using: encoding) else {
			throw FileSystemError.failedToEditFile(CocoaError(.fileWriteInapplicableStringEncoding))
		}
		if hasByteOrderMark, let mark = byteOrderMark(for: encoding), !data.starts(with: mark) {
			return mark + data
		}
		return data
	}

	static func byteOrderMark(for encoding: String.Encoding) -> Data? {
		switch encoding {
		case .utf8: return Data([0xEF, 0xBB, 0xBF])
		case .utf16LittleEndian: return Data([0xFF, 0xFE])
		case .utf16BigEndian: return Data([0xFE, 0xFF])
		case .utf32LittleEndian: return Data([0xFF, 0xFE, 0x00, 0x00])
		case .utf32BigEndian: return Data([0x00, 0x00, 0xFE, 0xFF])
		default: return nil
		}
	}
}
