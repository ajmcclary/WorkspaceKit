import XCTest
@testable import WorkspaceFileSystem

/// The typed read decides "binary" from the same 8 KB prefix the legacy read
/// probed, and stops there; a text file is still read once.
final class FileSystemServiceTypedReadProbeTests: XCTestCase {

	private var rootURL: URL!

	override func setUpWithError() throws {
		rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FSTypedReadProbe-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: rootURL)
	}

	private func makeService() async throws -> FileSystemService {
		try await FileSystemService(path: rootURL.path, respectGitignore: false, respectRepoIgnore: false, respectCursorignore: false)
	}

	private func write(_ bytes: [UInt8], _ name: String) throws {
		try Data(bytes).write(to: rootURL.appendingPathComponent(name))
	}

	func testBinaryFileCostsOnlyThePrefix() async throws {
		var blob = [UInt8](repeating: 0x00, count: 5 * 1_024 * 1_024)
		for index in stride(from: 0, to: blob.count, by: 7) { blob[index] = 0x41 }
		try write(blob, "build-product.dat")
		let service = try await makeService()

		let result = try await service.readFileContent(atRelativePath: "build-product.dat")

		XCTAssertEqual(result, .binary)
		let bytesRead = await service.typedReadBytesReadForTesting()
		XCTAssertLessThanOrEqual(bytesRead, 8_192, "a binary file was read past the 8 KB probe")
	}

	func testTextFileIsReadOnce() async throws {
		let line = Array("let value = 42 // some source text\n".utf8)
		var text: [UInt8] = []
		while text.count < 5 * 1_024 * 1_024 { text += line }
		try write(text, "large.dat")
		let service = try await makeService()

		let result = try await service.readFileContent(atRelativePath: "large.dat")

		XCTAssertEqual(result.text?.utf8.count, text.count)
		let bytesRead = await service.typedReadBytesReadForTesting()
		XCTAssertEqual(bytesRead, text.count, "a text file must be read exactly once")
	}

	/// Classification table. Expected values are what 0.1.0-beta.11 returned
	/// (it read the whole file, then probed its first 8 KB); they were recorded
	/// by running this table against beta.11 before the prefix read landed.
	func testClassificationIsUnchangedByThePrefixProbe() async throws {
		let utf8Text = Array(String(repeating: "héllo wörld\n", count: 2_000).utf8)            // ~26 KB
		let utf16WithBOM: [UInt8] = [0xFF, 0xFE] + Array("hi there".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
		let nulAfterProbe = [UInt8](repeating: 0x61, count: 9_000) + [0x00] + Array("tail".utf8)
		let binaryAfterTextPrefix = [UInt8](repeating: 0x61, count: 8_192) + [0x00, 0x01, 0x02, 0xFF, 0xFE, 0x00]
		let shortText = Array("short file\n".utf8)
		let shortBinary: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01]
		let atLimit = [UInt8](repeating: 0x62, count: 64)
		let overLimit = [UInt8](repeating: 0x62, count: 65)

		try write(utf8Text, "utf8.dat")
		try write(utf16WithBOM, "utf16bom.dat")
		try write(nulAfterProbe, "nul-after-8k.dat")
		try write(binaryAfterTextPrefix, "binary-after-8k.dat")
		try write([], "empty.dat")
		try write(shortText, "short-text.dat")
		try write(shortBinary, "short-binary.dat")
		try write(atLimit, "at-limit.dat")
		try write(overLimit, "over-limit.dat")
		let service = try await makeService()

		func classify(_ name: String, limit: Int64 = FileSystemService.defaultTextReadSizeLimit) async throws -> String {
			switch try await service.readFileContent(atRelativePath: name, sizeLimit: limit) {
			case .text(let text, let encoding, let mark): return "text(\(text.utf8.count)B, \(encoding), bom=\(mark))"
			case .tooLarge(let count, let limit): return "tooLarge(\(count)/\(limit))"
			case .binary: return "binary"
			case .undecodable(let encoding): return "undecodable(\(encoding))"
			}
		}

		let expected: [(String, Int64?, String)] = [
			("utf8.dat", nil, "text(\(utf8Text.count)B, Unicode (UTF-8), bom=false)"),
			("utf16bom.dat", nil, "text(8B, Unicode (UTF-16LE), bom=true)"),
			("nul-after-8k.dat", nil, "text(\(nulAfterProbe.count)B, Unicode (UTF-8), bom=false)"),
			("binary-after-8k.dat", nil, Self.binaryAfterTextPrefixExpectation),
			("empty.dat", nil, "text(0B, Unicode (UTF-8), bom=false)"),
			("short-text.dat", nil, "text(\(shortText.count)B, Unicode (UTF-8), bom=false)"),
			("short-binary.dat", nil, "binary"),
			("at-limit.dat", 64, "text(64B, Unicode (UTF-8), bom=false)"),
			("over-limit.dat", 64, "tooLarge(65/64)")
		]
		for (name, limit, want) in expected {
			let got = try await classify(name, limit: limit ?? FileSystemService.defaultTextReadSizeLimit)
			XCTAssertEqual(got, want, name)
		}
	}

	/// beta.11 read on past the clean 8 KB prefix and decoded the rest.
	static let binaryAfterTextPrefixExpectation = "text(8200B, Cyrillic (Windows), bom=false)"
}
