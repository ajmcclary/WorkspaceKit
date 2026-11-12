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
