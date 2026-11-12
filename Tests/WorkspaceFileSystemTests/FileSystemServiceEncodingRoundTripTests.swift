import XCTest
@testable import WorkspaceFileSystem

/// Reading a file and writing it back through `editFile` keeps its encoding
/// and its byte-order mark, however the caller spells the path.
final class FileSystemServiceEncodingRoundTripTests: XCTestCase {

	private var rootURL: URL!

	override func setUpWithError() throws {
		rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FSEncodingRoundTrip-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: rootURL)
	}

	private func makeService() async throws -> FileSystemService {
		try await FileSystemService(path: rootURL.path, respectGitignore: false, respectRepoIgnore: false, respectCursorignore: false)
	}

	private func bytes(_ name: String) throws -> [UInt8] {
		Array(try Data(contentsOf: rootURL.appendingPathComponent(name)))
	}

	func testUTF8ByteOrderMarkSurvivesAnEditAfterTheLegacyRead() async throws {
		let mark: [UInt8] = [0xEF, 0xBB, 0xBF]
		try Data(mark + Array("name,city\nZoë,Köln\n".utf8)).write(to: rootURL.appendingPathComponent("people.csv"))
		let service = try await makeService()

		let content = try await service.loadContent(ofRelativePath: "people.csv")
		XCTAssertEqual(content, "name,city\nZoë,Köln\n")
		try await service.editFile(atRelativePath: "people.csv", newContent: "name,city\nZoë,Köln\nAnaïs,Lyon\n")

		XCTAssertEqual(try bytes("people.csv"), mark + Array("name,city\nZoë,Köln\nAnaïs,Lyon\n".utf8))
	}

	func testLargeFileByteOrderMarkSurvivesAnEdit() async throws {
		let mark: [UInt8] = [0xEF, 0xBB, 0xBF]
		let body = String(repeating: "Write-Host 'ünïcode'\n", count: 120_000) // ~2.6 MB, streamed path
		try Data(mark + Array(body.utf8)).write(to: rootURL.appendingPathComponent("script.ps1"))
		let service = try await makeService()

		let content = try await service.loadContent(ofRelativePath: "script.ps1")
		XCTAssertEqual(content?.hasPrefix("Write-Host"), true)
		try await service.editFile(atRelativePath: "script.ps1", newContent: "Write-Host 'x'\n")

		XCTAssertEqual(try bytes("script.ps1"), mark + Array("Write-Host 'x'\n".utf8))
	}

	func testFileWithoutByteOrderMarkDoesNotGainOne() async throws {
		try Data("plain\n".utf8).write(to: rootURL.appendingPathComponent("plain.txt"))
		let service = try await makeService()
		_ = try await service.loadContent(ofRelativePath: "plain.txt")
		try await service.editFile(atRelativePath: "plain.txt", newContent: "still plain\n")
		XCTAssertEqual(try bytes("plain.txt"), Array("still plain\n".utf8))
	}

	func testEncodingIsFoundWhenThePathIsSpelledDifferentlyThanAtReadTime() async throws {
		// "café\n" in Windows-1252 / Latin-1: not valid UTF-8.
		let original: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x0A]
		try Data(original).write(to: rootURL.appendingPathComponent("latin.txt"))
		let service = try await makeService()

		let content = try await service.loadContent(ofRelativePath: "./latin.txt")
		XCTAssertEqual(content, "café\n")
		try await service.editFile(atRelativePath: "/latin.txt", newContent: content ?? "")

		XCTAssertEqual(try bytes("latin.txt"), original, "written back in a different encoding")
	}
}

/// A charset label the detector returns but CoreFoundation does not know
/// must not become an invalid encoding.
final class FileSystemServiceCharsetLabelTests: XCTestCase {

	private struct FixedLabelDetector: WorkspaceCharsetDetecting {
		let label: String
		func detectedCharacterEncodingLabel(for data: Data) -> String? { label }
		func makeStreamingDetector() -> any WorkspaceStreamingCharsetDetector { Streaming(label: label) }
		final class Streaming: WorkspaceStreamingCharsetDetector {
			let label: String
			init(label: String) { self.label = label }
			func analyzeNextChunk(_ data: Data) -> Bool { true }
			func finish() -> String? { label }
		}
	}

	private var rootURL: URL!

	override func setUpWithError() throws {
		rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FSCharsetLabel-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: rootURL)
	}

	private func makeService(label: String) async throws -> FileSystemService {
		try await FileSystemService(
			path: rootURL.path,
			respectGitignore: false,
			respectRepoIgnore: false,
			respectCursorignore: false,
			charsetDetector: FixedLabelDetector(label: label)
		)
	}

	private static let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
		CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
	))

	func testUHCLabelDecodesKoreanCodePage949() async throws {
		let text = "안녕하세요, 세계\n"
		let data = try XCTUnwrap(text.data(using: Self.cp949))
		try data.write(to: rootURL.appendingPathComponent("korean.txt"))
		let service = try await makeService(label: "UHC")

		let legacy = try await service.loadContent(ofRelativePath: "korean.txt")
		XCTAssertEqual(legacy, text)
		let typed = try await service.readFileContent(atRelativePath: "korean.txt")
		XCTAssertEqual(typed.text, text)
	}

	func testUHCLabelDecodesLargeKoreanFile() async throws {
		let line = "안녕하세요, 세계 - 0123456789\n"
		let text = String(repeating: line, count: 80_000) // > 2 MB in CP949, streamed path
		let data = try XCTUnwrap(text.data(using: Self.cp949))
		XCTAssertGreaterThan(data.count, 2_000_000)
		try data.write(to: rootURL.appendingPathComponent("korean-large.txt"))
		let service = try await makeService(label: "UHC")

		let legacy = try await service.loadContent(ofRelativePath: "korean-large.txt")
		XCTAssertEqual(legacy?.count, text.count)
	}

	func testUnknownLabelFallsBackInsteadOfFailing() async throws {
		let original: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x0A] // "café\n" in Latin-1
		try Data(original).write(to: rootURL.appendingPathComponent("latin.txt"))
		let service = try await makeService(label: "GEORGIAN-ACADEMY")

		let legacy = try await service.loadContent(ofRelativePath: "latin.txt")
		XCTAssertEqual(legacy, "café\n")
		let encoding = try await service.detectEncodingForInitialChunk(initialData: Data(original))
		XCTAssertNotNil(String(data: Data(original), encoding: encoding))
	}
}
