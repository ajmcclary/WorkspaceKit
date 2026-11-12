import XCTest
@testable import WorkspaceFileSystem

/// `readFileContent` reports "too large", "binary" and "undecodable" as
/// statuses, never as text, so a caller that writes content back cannot
/// replace a file with a placeholder string.
final class FileSystemServiceTypedReadTests: XCTestCase {

	private var rootURL: URL!

	override func setUpWithError() throws {
		rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FSTypedRead-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: rootURL)
	}

	private func makeService(detector: any WorkspaceCharsetDetecting = FoundationOnlyCharsetDetector()) async throws -> FileSystemService {
		try await FileSystemService(
			path: rootURL.path,
			respectGitignore: false,
			respectRepoIgnore: false,
			respectCursorignore: false,
			charsetDetector: detector
		)
	}

	private func write(_ bytes: [UInt8], to name: String) throws {
		try Data(bytes).write(to: rootURL.appendingPathComponent(name))
	}

	func testFileOverTheLimitIsReportedAsTooLargeNotAsText() async throws {
		try write(Array(repeating: 0x61, count: 100), to: "big.swift")
		let service = try await makeService()

		let result = try await service.readFileContent(atRelativePath: "big.swift", sizeLimit: 16)

		XCTAssertEqual(result, .tooLarge(byteCount: 100, limit: 16))
		XCTAssertNil(result.text)
	}

	func testFileOverTheDefaultLimitIsTooLarge() async throws {
		let url = rootURL.appendingPathComponent("huge.json")
		FileManager.default.createFile(atPath: url.path, contents: nil)
		let handle = try FileHandle(forWritingTo: url)
		try handle.truncate(atOffset: 12_345_678)
		try handle.close()
		let service = try await makeService()

		let result = try await service.readFileContent(atRelativePath: "huge.json")

		XCTAssertEqual(result, .tooLarge(byteCount: 12_345_678, limit: FileSystemService.defaultTextReadSizeLimit))
	}

	func testBinaryContentAndBinaryExtensionsAreReportedAsBinary() async throws {
		try write([0x00, 0x01, 0x02, 0xFF, 0x00, 0x10], to: "blob.dat")
		try write([0x89, 0x50, 0x4E, 0x47], to: "image.png")
		let service = try await makeService()

		let blob = try await service.readFileContent(atRelativePath: "blob.dat")
		XCTAssertEqual(blob, .binary)
		let image = try await service.readFileContent(atRelativePath: "image.png")
		XCTAssertEqual(image, .binary)
	}

	func testUndecodableBytesAreReportedAsUndecodable() async throws {
		// A UTF-8 byte-order mark followed by bytes that are not UTF-8.
		try write([0xEF, 0xBB, 0xBF, 0x61, 0xFF, 0xFE, 0xC0, 0x62], to: "broken.txt")
		let service = try await makeService()

		let result = try await service.readFileContent(atRelativePath: "broken.txt")

		XCTAssertEqual(result, .undecodable(encoding: .utf8))
	}

	func testTextIsDecodedWithItsEncodingAndByteOrderMark() async throws {
		try write(Array("let x = 1\n".utf8), to: "plain.swift")
		try write([0xEF, 0xBB, 0xBF] + Array("a,b\n".utf8), to: "bom.csv")
		try write([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00], to: "wide.txt")
		try write([], to: "empty.txt")
		let service = try await makeService()

		let plain = try await service.readFileContent(atRelativePath: "plain.swift")
		XCTAssertEqual(plain, .text("let x = 1\n", encoding: .utf8, hasByteOrderMark: false))
		let bom = try await service.readFileContent(atRelativePath: "bom.csv")
		XCTAssertEqual(bom, .text("a,b\n", encoding: .utf8, hasByteOrderMark: true))
		let wide = try await service.readFileContent(atRelativePath: "wide.txt")
		XCTAssertEqual(wide, .text("hi", encoding: .utf16LittleEndian, hasByteOrderMark: true))
		let empty = try await service.readFileContent(atRelativePath: "empty.txt")
		XCTAssertEqual(empty, .text("", encoding: .utf8, hasByteOrderMark: false))
	}

	func testFilesAboveTheStreamingThresholdAreStillText() async throws {
		let line = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde\n"
		let content = String(repeating: line, count: 50_000) // 3.2 MB
		try content.write(to: rootURL.appendingPathComponent("large.swift"), atomically: true, encoding: .utf8)
		let service = try await makeService()

		let result = try await service.readFileContent(atRelativePath: "large.swift")

		XCTAssertEqual(result.text?.count, content.count)
	}

	func testReadWithDateReturnsTheModificationDate() async throws {
		try write(Array("x".utf8), to: "dated.txt")
		let expected = try FileManager.default.attributesOfItem(atPath: rootURL.appendingPathComponent("dated.txt").path)[.modificationDate] as? Date
		let service = try await makeService()

		let (result, date) = try await service.readFileContentWithDate(atRelativePath: "dated.txt")

		XCTAssertEqual(result.text, "x")
		XCTAssertEqual(date, expected)
	}

	func testMissingFileAndEscapingPathThrow() async throws {
		let service = try await makeService()
		do {
			_ = try await service.readFileContent(atRelativePath: "nope.txt")
			XCTFail("expected fileNotFound")
		} catch FileSystemError.fileNotFound {}
		do {
			_ = try await service.readFileContent(atRelativePath: "../outside.txt")
			XCTFail("expected invalidRelativePath")
		} catch FileSystemError.invalidRelativePath {}
	}

	func testTextReadThenEditRoundTripsTheBytes() async throws {
		try write([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00], to: "wide.txt")
		let service = try await makeService()
		let result = try await service.readFileContent(atRelativePath: "wide.txt")
		guard let text = result.text else { return XCTFail("expected text, got \(result)") }

		try await service.editFile(atRelativePath: "wide.txt", newContent: text + "!")

		XCTAssertEqual(
			Array(try Data(contentsOf: rootURL.appendingPathComponent("wide.txt"))),
			[0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00, 0x21, 0x00]
		)
	}
}
