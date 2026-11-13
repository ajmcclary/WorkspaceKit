import XCTest
@testable import WorkspaceFileSystem

/// Every mutating entry point of `FileSystemService` must keep the bytes it
/// writes inside the workspace root, whatever relative path a caller passes:
/// `..` components are collapsed and rejected when they climb out, and a
/// symlinked directory (or file) inside the root that points elsewhere is not
/// written through.
final class FileSystemServiceWriteContainmentTests: XCTestCase {

	private var sandboxURL: URL!
	private var rootURL: URL!
	private var outsideURL: URL!

	override func setUpWithError() throws {
		// temporaryDirectory sits under /var → /private/var, so the root path
		// itself goes through a symlink: legitimate writes must still pass.
		sandboxURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FSWriteContainment-\(UUID().uuidString)", isDirectory: true)
		rootURL = sandboxURL.appendingPathComponent("work/app", isDirectory: true)
		outsideURL = sandboxURL.appendingPathComponent("outside", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("src"), withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: sandboxURL)
	}

	private func makeService() async throws -> FileSystemService {
		try await FileSystemService(path: rootURL.path, respectGitignore: false, respectRepoIgnore: false, respectCursorignore: false)
	}

	private func assertInvalidRelativePath(
		_ operation: () async throws -> Void,
		_ message: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) async {
		do {
			try await operation()
			XCTFail("expected invalidRelativePath: \(message)", file: file, line: line)
		} catch FileSystemError.invalidRelativePath {
			// expected
		} catch {
			XCTFail("expected invalidRelativePath, got \(error): \(message)", file: file, line: line)
		}
	}

	private func outsideTreeIsEmptyExcept(_ allowed: Set<String>) throws -> Bool {
		let names = try FileManager.default.contentsOfDirectory(atPath: sandboxURL.path)
		let workNames = try FileManager.default.contentsOfDirectory(atPath: sandboxURL.appendingPathComponent("work").path)
		return Set(names).subtracting(["work"]).subtracting(allowed).isEmpty && Set(workNames) == ["app"]
	}

	// MARK: - createFile

	func testCreateFileRejectsRelativePathsThatClimbOutOfTheRoot() async throws {
		let service = try await makeService()
		for path in ["../escaped/evil.txt", "../../escaped/evil.txt", "src/../../via-src.txt", "./../evil.txt", "src/../.."] {
			await assertInvalidRelativePath({ try await service.createFile(atRelativePath: path, content: "x") }, path)
		}
		XCTAssertTrue(try outsideTreeIsEmptyExcept(["outside"]), "something was created outside the root")
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outsideURL.path), [])
	}

	func testCreateFileRejectsTheRootItself() async throws {
		let service = try await makeService()
		for path in ["", ".", "src/..", "/"] {
			await assertInvalidRelativePath({ try await service.createFile(atRelativePath: path, content: "x") }, "'\(path)'")
		}
	}

	func testCreateFileThroughSymlinkedDirectoryPointingOutsideIsRejected() async throws {
		try FileManager.default.createSymbolicLink(at: rootURL.appendingPathComponent("la"), withDestinationURL: outsideURL)
		let service = try await makeService()
		await assertInvalidRelativePath({ try await service.createFile(atRelativePath: "la/x.plist", content: "x") }, "la/x.plist")
		await assertInvalidRelativePath({ try await service.createFile(atRelativePath: "la/deeper/x.plist", content: "x") }, "la/deeper/x.plist")
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outsideURL.path), [])
	}

	func testCreateFileThroughSymlinkedDirectoryInsideTheRootIsAllowed() async throws {
		try FileManager.default.createSymbolicLink(
			at: rootURL.appendingPathComponent("srclink"),
			withDestinationURL: rootURL.appendingPathComponent("src")
		)
		let service = try await makeService()
		try await service.createFile(atRelativePath: "srclink/linked.txt", content: "ok")
		XCTAssertEqual(try String(contentsOf: rootURL.appendingPathComponent("src/linked.txt"), encoding: .utf8), "ok")
	}

	func testInRootSymlinksWithRelativeAbsoluteAndChainedTargetsKeepWorking() async throws {
		let fm = FileManager.default
		try fm.createDirectory(at: rootURL.appendingPathComponent("lib/deep"), withIntermediateDirectories: true)
		try fm.createSymbolicLink(atPath: rootURL.appendingPathComponent("src/up").path, withDestinationPath: "../lib")
		try fm.createSymbolicLink(atPath: rootURL.appendingPathComponent("abs").path, withDestinationPath: rootURL.appendingPathComponent("lib").path)
		try fm.createSymbolicLink(atPath: rootURL.appendingPathComponent("chain").path, withDestinationPath: "src/up/deep")
		// Climbs above the root and comes back in by the root's own name.
		try fm.createSymbolicLink(atPath: rootURL.appendingPathComponent("around").path, withDestinationPath: "../app/lib")
		let service = try await makeService()

		try await service.createFile(atRelativePath: "src/up/a.txt", content: "a")
		try await service.createFile(atRelativePath: "abs/b.txt", content: "b")
		try await service.createFile(atRelativePath: "chain/c.txt", content: "c")
		try await service.createFile(atRelativePath: "around/d.txt", content: "d")
		try await service.editFile(atRelativePath: "chain/c.txt", newContent: "c2")

		XCTAssertEqual(try String(contentsOf: rootURL.appendingPathComponent("lib/a.txt"), encoding: .utf8), "a")
		XCTAssertEqual(try String(contentsOf: rootURL.appendingPathComponent("lib/b.txt"), encoding: .utf8), "b")
		XCTAssertEqual(try String(contentsOf: rootURL.appendingPathComponent("lib/deep/c.txt"), encoding: .utf8), "c2")
		XCTAssertEqual(try String(contentsOf: rootURL.appendingPathComponent("lib/d.txt"), encoding: .utf8), "d")
	}

	func testRootThatIsItselfASymlinkStillAcceptsWrites() async throws {
		let rootLink = sandboxURL.appendingPathComponent("root-link")
		try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: rootURL)
		let service = try await FileSystemService(path: rootLink.path, respectGitignore: false, respectRepoIgnore: false, respectCursorignore: false)
		try await service.createFile(atRelativePath: "src/via-root-link.txt", content: "ok")
		try await service.moveFile(atRelativePath: "src/via-root-link.txt", toRelativePath: "moved.txt")
		XCTAssertEqual(try String(contentsOf: rootURL.appendingPathComponent("moved.txt"), encoding: .utf8), "ok")
	}

	func testSymlinkLoopIsRejected() async throws {
		try FileManager.default.createSymbolicLink(atPath: rootURL.appendingPathComponent("loopA").path, withDestinationPath: "loopB")
		try FileManager.default.createSymbolicLink(atPath: rootURL.appendingPathComponent("loopB").path, withDestinationPath: "loopA")
		let service = try await makeService()
		await assertInvalidRelativePath({ try await service.createFile(atRelativePath: "loopA/x.txt", content: "x") }, "loop")
	}

	func testCreateFileCollapsesParentTraversalThatStaysInsideTheRoot() async throws {
		let service = try await makeService()
		try await service.createFile(atRelativePath: "src/../lib/new.txt", content: "hello")
		XCTAssertEqual(try String(contentsOf: rootURL.appendingPathComponent("lib/new.txt"), encoding: .utf8), "hello")
		try await service.createFile(atRelativePath: "/src/leading-slash.txt", content: "root-relative")
		XCTAssertEqual(
			try String(contentsOf: rootURL.appendingPathComponent("src/leading-slash.txt"), encoding: .utf8),
			"root-relative"
		)
	}

	// MARK: - editFile

	func testEditFileRejectsPathsOutsideTheRoot() async throws {
		let victim = outsideURL.appendingPathComponent("victim.txt")
		try "original".write(to: victim, atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(at: rootURL.appendingPathComponent("la"), withDestinationURL: outsideURL)
		try FileManager.default.createSymbolicLink(at: rootURL.appendingPathComponent("victim-link.txt"), withDestinationURL: victim)
		let service = try await makeService()

		for path in ["../../outside/victim.txt", "la/victim.txt", "victim-link.txt"] {
			await assertInvalidRelativePath({ try await service.editFile(atRelativePath: path, newContent: "pwned") }, path)
		}
		XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "original")
		let linkValues = try rootURL.appendingPathComponent("victim-link.txt").resourceValues(forKeys: [.isSymbolicLinkKey])
		XCTAssertEqual(linkValues.isSymbolicLink, true, "the in-root symlink must not be replaced")
	}

	func testEditFileThroughInRootSymlinkWritesTheTargetAndKeepsTheLink() async throws {
		let target = rootURL.appendingPathComponent("src/target.txt")
		try "before".write(to: target, atomically: true, encoding: .utf8)
		let link = rootURL.appendingPathComponent("alias.txt")
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
		let service = try await makeService()

		try await service.editFile(atRelativePath: "alias.txt", newContent: "after")

		XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "after")
		XCTAssertEqual(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
	}

	// MARK: - moveFile

	func testMoveFileRejectsDestinationsAndSourcesOutsideTheRoot() async throws {
		let source = rootURL.appendingPathComponent("src/keep.txt")
		try "keep".write(to: source, atomically: true, encoding: .utf8)
		let victim = outsideURL.appendingPathComponent("victim.txt")
		try "outside".write(to: victim, atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(at: rootURL.appendingPathComponent("la"), withDestinationURL: outsideURL)
		let service = try await makeService()

		for destination in ["../moved-out.txt", "src/../../moved-out.txt", "la/moved.txt"] {
			await assertInvalidRelativePath(
				{ try await service.moveFile(atRelativePath: "src/keep.txt", toRelativePath: destination) },
				"destination \(destination)"
			)
		}
		await assertInvalidRelativePath(
			{ try await service.moveFile(atRelativePath: "../../outside/victim.txt", toRelativePath: "stolen.txt") },
			"source outside"
		)
		await assertInvalidRelativePath(
			{ try await service.moveFile(atRelativePath: "la/victim.txt", toRelativePath: "stolen.txt") },
			"source through symlink"
		)

		XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: sandboxURL.appendingPathComponent("work/moved-out.txt").path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("stolen.txt").path))
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outsideURL.path), ["victim.txt"])
	}

	func testMoveFileInsideTheRootStillWorks() async throws {
		try "keep".write(to: rootURL.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
		let service = try await makeService()
		try await service.moveFile(atRelativePath: "src/a.txt", toRelativePath: "src/../moved/b.txt")
		XCTAssertEqual(try String(contentsOf: rootURL.appendingPathComponent("moved/b.txt"), encoding: .utf8), "keep")
	}

	func testCreateThroughARegularFileComponentIsAnInvalidPath() async throws {
		try "x".write(to: rootURL.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
		let service = try await makeService()
		await assertInvalidRelativePath({ try await service.createFile(atRelativePath: "file.txt/x", content: "y") }, "file.txt/x")
		await assertInvalidRelativePath({ try await service.createFile(atRelativePath: "file.txt/a/x", content: "y") }, "file.txt/a/x")
	}

	// MARK: - delete / trash

	func testDeleteThroughSymlinkedDirectoryPointingOutsideIsRejected() async throws {
		let victim = outsideURL.appendingPathComponent("delvictim.txt")
		try "keep me".write(to: victim, atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(at: rootURL.appendingPathComponent("la"), withDestinationURL: outsideURL)
		let service = try await makeService()

		await assertInvalidRelativePath({ _ = try await service.deleteFile(atRelativePath: "la/delvictim.txt") }, "delete la/delvictim.txt")
		await assertInvalidRelativePath({ _ = try await service.moveItemToTrash(atRelativePath: "la/delvictim.txt") }, "trash la/delvictim.txt")
		XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
	}

	func testDeleteOfASymlinkRemovesTheLinkNotItsTarget() async throws {
		let victim = outsideURL.appendingPathComponent("target.txt")
		try "keep me".write(to: victim, atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(at: rootURL.appendingPathComponent("file-link"), withDestinationURL: victim)
		try FileManager.default.createSymbolicLink(at: rootURL.appendingPathComponent("dir-link"), withDestinationURL: outsideURL)
		let service = try await makeService()

		_ = try await service.deleteFile(atRelativePath: "file-link")
		_ = try await service.deleteFile(atRelativePath: "dir-link")

		XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: rootURL.appendingPathComponent("file-link").path))
		XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: rootURL.appendingPathComponent("dir-link").path))
		XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "keep me")
	}

	func testDeleteOfADirectoryRemovesItsTreeWithoutFollowingLinksInside() async throws {
		let victim = outsideURL.appendingPathComponent("deep.txt")
		try "keep me".write(to: victim, atomically: true, encoding: .utf8)
		let tree = rootURL.appendingPathComponent("tree/sub", isDirectory: true)
		try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
		try "a".write(to: tree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("out"), withDestinationURL: outsideURL)
		let service = try await makeService()

		_ = try await service.deleteFile(atRelativePath: "tree")

		XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("tree").path))
		XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "keep me")
	}

	func testDeleteThroughSymlinkedDirectoryInsideTheRootStillWorks() async throws {
		try "x".write(to: rootURL.appendingPathComponent("src/gone.txt"), atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(
			at: rootURL.appendingPathComponent("srclink"),
			withDestinationURL: rootURL.appendingPathComponent("src")
		)
		let service = try await makeService()
		_ = try await service.deleteFile(atRelativePath: "srclink/gone.txt")
		XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("src/gone.txt").path))
	}

	// MARK: - reads

	func testLoadContentRejectsParentTraversalOutOfTheRoot() async throws {
		try "secret".write(to: outsideURL.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
		let service = try await makeService()
		await assertInvalidRelativePath({ _ = try await service.loadContent(ofRelativePath: "../../outside/secret.txt") }, "loadContent")
	}

	func testReadsOpenTheCollapsedPathTheyChecked() async throws {
		try FileManager.default.createDirectory(at: outsideURL.appendingPathComponent("sub"), withIntermediateDirectories: true)
		try "secret".write(to: outsideURL.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(
			at: rootURL.appendingPathComponent("lsub"),
			withDestinationURL: outsideURL.appendingPathComponent("sub")
		)
		let service = try await makeService()

		for read in [
			{ _ = try await service.loadContent(ofRelativePath: "lsub/../secret.txt") },
			{ _ = try await service.loadEntireFileContentOptimized(ofRelativePath: "lsub/../secret.txt") },
			{ _ = try await service.readFileContent(atRelativePath: "lsub/../secret.txt") }
		] as [() async throws -> Void] {
			do {
				try await read()
				XCTFail("read the file outside the root")
			} catch FileSystemError.fileNotFound {
				// expected: the collapsed path, root/secret.txt, does not exist
			} catch {
				XCTFail("unexpected \(error)")
			}
		}
	}
}
