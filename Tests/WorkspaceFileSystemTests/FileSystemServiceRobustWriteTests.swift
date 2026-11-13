import XCTest
import Darwin
@testable import WorkspaceFileSystem

/// `writeFileRobust` is the single writer behind `createFile` and `editFile`.
/// A failed write must leave the original intact, and a successful one must
/// keep what an in-place save keeps: mode and extended attributes.
final class FileSystemServiceRobustWriteTests: XCTestCase {

	private var dirURL: URL!

	override func setUpWithError() throws {
		dirURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FSRobustWrite-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		chmod(dirURL.path, 0o755)
		try? FileManager.default.removeItem(at: dirURL)
	}

	/// A write that fails for a reason no fallback can fix (here: the
	/// process file-size limit, standing in for disk full / quota / EIO) must
	/// throw and leave the original bytes untouched.
	func testFailedWriteLeavesTheOriginalIntact() throws {
		let url = dirURL.appendingPathComponent("victim.txt")
		let original = Data("original contents\n".utf8)
		try original.write(to: url)

		var saved = rlimit()
		XCTAssertEqual(getrlimit(RLIMIT_FSIZE, &saved), 0)
		let previousHandler = signal(SIGXFSZ, SIG_IGN)
		var limited = saved
		limited.rlim_cur = 4_096
		XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &limited), 0)
		defer {
			_ = setrlimit(RLIMIT_FSIZE, &saved)
			_ = signal(SIGXFSZ, previousHandler)
		}

		XCTAssertThrowsError(try FileSystemService.writeFileRobust(to: url, data: Data(repeating: 0x61, count: 64 * 1_024)))

		_ = setrlimit(RLIMIT_FSIZE, &saved)
		XCTAssertEqual(try Data(contentsOf: url), original)
		let leftovers = try FileManager.default.contentsOfDirectory(atPath: dirURL.path).filter { $0 != "victim.txt" }
		XCTAssertEqual(leftovers, [], "temporary files must be cleaned up")
	}

	/// A file that is writable inside a directory that is not (no temp file
	/// can be created next to it) is still saved, in place.
	func testWritableFileInReadOnlyDirectoryIsRewrittenInPlace() throws {
		let url = dirURL.appendingPathComponent("inplace.txt")
		try Data("old old old old\n".utf8).write(to: url)
		XCTAssertEqual(chmod(dirURL.path, 0o555), 0)

		try FileSystemService.writeFileRobust(to: url, data: Data("new\n".utf8))

		XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new\n")
	}

	/// In a sticky directory a file owned by someone else cannot be replaced
	/// by rename (EPERM) even when the file itself is writable; it must still
	/// be saved, in place. Rename refusal is simulated (making another user's
	/// file needs root).
	func testFileThatCannotBeReplacedByRenameIsRewrittenInPlace() throws {
		let url = dirURL.appendingPathComponent("shared.txt")
		try Data("old contents\n".utf8).write(to: url)
		FileSystemService.simulatedReplaceRenameErrorForTesting.store(EPERM, ordering: .relaxed)
		defer { FileSystemService.simulatedReplaceRenameErrorForTesting.store(0, ordering: .relaxed) }

		try FileSystemService.writeFileRobust(to: url, data: Data("new\n".utf8))

		XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new\n")
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dirURL.path), ["shared.txt"], "temp, backup or recovery files left behind")
	}

	/// If the process dies during an in-place rewrite in a writable directory,
	/// a recovery copy of the original is on disk next to the file.
	func testInPlaceRewriteKeepsARecoveryCopyUntilItCompletes() throws {
		let url = dirURL.appendingPathComponent("shared.txt")
		let original = Data("the original, longer than the new contents\n".utf8)
		try original.write(to: url)
		FileSystemService.simulatedReplaceRenameErrorForTesting.store(EPERM, ordering: .relaxed)
		FileSystemService.simulatedCrashDuringInPlaceRewriteForTesting.store(true, ordering: .relaxed)
		defer {
			FileSystemService.simulatedReplaceRenameErrorForTesting.store(0, ordering: .relaxed)
			FileSystemService.simulatedCrashDuringInPlaceRewriteForTesting.store(false, ordering: .relaxed)
		}

		XCTAssertThrowsError(try FileSystemService.writeFileRobust(to: url, data: Data("new\n".utf8)))

		let others = try FileManager.default.contentsOfDirectory(atPath: dirURL.path).filter { $0 != "shared.txt" }
		XCTAssertEqual(others.count, 1, "expected one recovery copy, found \(others)")
		if let copy = others.first {
			XCTAssertTrue(copy.hasPrefix(".repoprompt.tmp."), copy)
			XCTAssertEqual(try Data(contentsOf: dirURL.appendingPathComponent(copy)), original)
		}
	}

	func testWriteKeepsModeAndExtendedAttributes() throws {
		let url = dirURL.appendingPathComponent("script.sh")
		try Data("#!/bin/sh\necho old\n".utf8).write(to: url)
		XCTAssertEqual(chmod(url.path, 0o755), 0)
		let tag = Array("finder-tag-value".utf8)
		XCTAssertEqual(setxattr(url.path, "com.example.workspacekit-test", tag, tag.count, 0, 0), 0)

		try FileSystemService.writeFileRobust(to: url, data: Data("#!/bin/sh\necho new\n".utf8))

		XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "#!/bin/sh\necho new\n")
		var info = stat()
		XCTAssertEqual(stat(url.path, &info), 0)
		XCTAssertEqual(info.st_mode & 0o7777, 0o755)
		var buffer = [UInt8](repeating: 0, count: 64)
		let length = getxattr(url.path, "com.example.workspacekit-test", &buffer, buffer.count, 0, 0)
		XCTAssertEqual(length, tag.count, "extended attribute dropped by the save")
		XCTAssertEqual(Array(buffer.prefix(max(0, length))), tag)
	}

	func testWriteToADirectoryPathIsRefusedAndTheDirectoryKept() throws {
		let folder = dirURL.appendingPathComponent("folder", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try Data("inside".utf8).write(to: folder.appendingPathComponent("child.txt"))

		XCTAssertThrowsError(try FileSystemService.writeFileRobust(to: folder, data: Data("x".utf8)))

		XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("child.txt"), encoding: .utf8), "inside")
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dirURL.path), ["folder"])
	}

	func testWriteCreatesANewFile() throws {
		let url = dirURL.appendingPathComponent("fresh.txt")
		try FileSystemService.writeFileRobust(to: url, data: Data("fresh".utf8))
		XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "fresh")
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dirURL.path), ["fresh.txt"])
	}
}
