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
}
