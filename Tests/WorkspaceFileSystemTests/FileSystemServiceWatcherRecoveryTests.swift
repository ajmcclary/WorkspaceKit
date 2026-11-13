import XCTest
import CoreServices
@testable import WorkspaceFileSystem

/// Recovery paths of the FSEvents watcher on a real temp-dir tree: folders
/// beyond the per-batch scan cap, dropped-event flags, the gap between the
/// initial walk and the stream start, and events that arrive after stop.
final class FileSystemServiceWatcherRecoveryTests: XCTestCase {

	private var rootURL: URL!

	override func setUpWithError() throws {
		rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FSWatcherRecovery-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: rootURL)
	}

	private func path(_ relative: String) -> String {
		rootURL.appendingPathComponent(relative).path
	}

	private func touch(_ relative: String, _ text: String = "x") throws {
		let url = rootURL.appendingPathComponent(relative)
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data(text.utf8).write(to: url)
	}

	/// Runs the service's initial walk so `visitedPaths` reflects the tree.
	private func walk(_ service: FileSystemService) async throws {
		for try await _ in await service.loadContentsInChunks(of: rootURL) {}
	}

	private func visited(_ service: FileSystemService) async -> Set<String> {
		await service.getTestState().visitedPaths
	}

	private func waitUntil(timeout: TimeInterval = 8, _ condition: () async -> Bool) async -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if await condition() { return true }
			try? await Task.sleep(nanoseconds: 50_000_000)
		}
		return await condition()
	}

	private static let fileCreated = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)

	// MARK: - Batch cap

	func testFoldersBeyondThePerBatchCapAreStillScanned() async throws {
		let folders = (0..<10).map { "dir\($0)" }
		for folder in folders { try FileManager.default.createDirectory(atPath: path(folder), withIntermediateDirectories: true) }
		let service = try await FileSystemService(
			path: rootURL.path,
			respectGitignore: false,
			respectRepoIgnore: false,
			respectCursorignore: false,
			maxFoldersPerBatchOverride: 3
		)
		try await walk(service)

		for folder in folders { try touch("\(folder)/new.txt") }
		let events = folders.enumerated().map { index, folder in
			(absolutePath: path("\(folder)/new.txt"), flags: Self.fileCreated, eventId: FSEventStreamEventId(100 + index))
		}
		_ = await service.simulateFSEvents(events)

		let expected = Set(folders.map { "\($0)/new.txt" })
		let allSeen = await waitUntil { expected.isSubset(of: await self.visited(service)) }
		let missing = expected.subtracting(await visited(service))
		XCTAssertTrue(allSeen, "never scanned: \(missing.sorted())")
		let state = await service.getCoalescingState()
		XCTAssertTrue(state.pendingScanTargets.isEmpty, "unscanned folders left pending: \(state.pendingScanTargets)")
	}

	// MARK: - Dropped events

	func testMustScanSubDirsOnTheRootReconcilesTheWholeTree() async throws {
		try touch("a/b/old.txt")
		try touch("a/keep.txt")
		let service = try await FileSystemService(path: rootURL.path, respectGitignore: false, respectRepoIgnore: false, respectCursorignore: false)
		try await walk(service)
		let initial = await visited(service)
		XCTAssertTrue(initial.contains("a/b/old.txt"))

		// Changes whose events were lost: only the recovery flag arrives.
		try touch("a/b/new.txt")
		try touch("a/b/c/deep.txt")
		try FileManager.default.removeItem(atPath: path("a/b/old.txt"))
		let deltas = await service.simulateFSEvents([
			(absolutePath: rootURL.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), eventId: 500)
		])

		XCTAssertTrue(deltas.contains(.fileAdded("a/b/new.txt")), "\(deltas)")
		XCTAssertTrue(deltas.contains(.fileAdded("a/b/c/deep.txt")), "\(deltas)")
		XCTAssertTrue(deltas.contains(.fileRemoved("a/b/old.txt")), "\(deltas)")
		let paths = await visited(service)
		XCTAssertTrue(paths.isSuperset(of: ["a/b/new.txt", "a/b/c", "a/b/c/deep.txt", "a/keep.txt"]))
		XCTAssertFalse(paths.contains("a/b/old.txt"))
	}

	func testDroppedEventsFlagReconcilesTheWholeTree() async throws {
		try touch("x/y/z/one.txt")
		let service = try await FileSystemService(path: rootURL.path, respectGitignore: false, respectRepoIgnore: false, respectCursorignore: false)
		try await walk(service)

		try touch("x/y/z/two.txt")
		let deltas = await service.simulateFSEvents([
			(absolutePath: path("x/y"), flags: FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped), eventId: 600)
		])

		XCTAssertTrue(deltas.contains(.fileAdded("x/y/z/two.txt")), "\(deltas)")
	}

	func testMustScanSubDirsOnASubdirectoryReconcilesThatSubtree() async throws {
		try touch("pkg/src/a.swift")
		try touch("other/b.swift")
		let service = try await FileSystemService(path: rootURL.path, respectGitignore: false, respectRepoIgnore: false, respectCursorignore: false)
		try await walk(service)

		try touch("pkg/src/deeper/c.swift")
		let deltas = await service.simulateFSEvents([
			(
				absolutePath: path("pkg"),
				flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemIsDir),
				eventId: 700
			)
		])

		XCTAssertTrue(deltas.contains(.fileAdded("pkg/src/deeper/c.swift")), "\(deltas)")
	}

	func testReconcileDoesNotReAddAFileDeletedWhileItsWalkWasSuspended() async throws {
		try touch("a/doomed.txt")
		try touch("a/keep.txt")
		let service = try await FileSystemService(path: rootURL.path, respectGitignore: false, respectRepoIgnore: false, respectCursorignore: false)
		try await walk(service)
		try touch("a/new.txt")
		await service.setReconcileWalkFinishedHookForTesting {
			_ = try? await service.deleteFile(atRelativePath: "a/doomed.txt")
		}

		let deltas = await service.simulateFSEvents([
			(absolutePath: rootURL.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), eventId: 800)
		])

		XCTAssertTrue(deltas.contains(.fileAdded("a/new.txt")), "\(deltas)")
		XCTAssertFalse(deltas.contains(.fileAdded("a/doomed.txt")), "re-added a deleted file: \(deltas)")
		let paths = await visited(service)
		XCTAssertFalse(paths.contains("a/doomed.txt"))
	}

	// MARK: - Initial walk gap

	func testChangeBetweenTheInitialWalkAndTheStreamStartIsReported() async throws {
		try touch("src/existing.swift")
		let service = try await FileSystemService(path: rootURL.path, respectGitignore: false, respectRepoIgnore: false, respectCursorignore: false)
		try await walk(service)

		// The app starts the stream only after a successful load; anything that
		// happens in between (or during the walk) must still be reported.
		try touch("src/created-during-load.swift")
		try await Task.sleep(nanoseconds: 300_000_000)
		await service.startWatchingForChanges()
		defer { Task { await service.stopWatchingForChanges() } }

		let seen = await waitUntil { await self.visited(service).contains("src/created-during-load.swift") }
		XCTAssertTrue(seen, "a file created before the stream started was never reported")
	}

	// MARK: - Stop

	func testStreamPayloadArrivingAfterStopIsDropped() async throws {
		let service = try await FileSystemService(path: rootURL.path, respectGitignore: false, respectRepoIgnore: false, respectCursorignore: false)
		await service.startWatchingForChanges()
		await service.stopWatchingForChanges()

		await service.ingestStreamPayloadForTesting([
			(absolutePath: path("late.txt"), flags: Self.fileCreated, eventId: 900)
		])

		let state = await service.watcherStateForTesting()
		XCTAssertEqual(state.pendingRawEventCount, 0, "a callback that fired before stop re-armed the watcher")
	}

	// MARK: - Missing root

	func testWritesDoNotRecreateARootThatWasRemoved() async throws {
		let service = try await FileSystemService(path: rootURL.path, respectGitignore: false, respectRepoIgnore: false, respectCursorignore: false)
		try FileManager.default.removeItem(at: rootURL)

		do {
			try await service.createFile(atRelativePath: "a/new.txt", content: "x")
			XCTFail("expected the create to fail")
		} catch {}
		XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path), "the old root path was re-created")
	}

	// MARK: - Temp-save names

	func testDotfilesContainingSwAreNotEditorTempFiles() {
		for name in [".swiftlint.yml", ".swiftformat", ".swift-version", ".swcrc", "src/.swiftpm"] {
			XCTAssertFalse(FileSystemService.isTempSaveName(name), name)
		}
		for name in [".main.swift.swp", ".notes.md.swo", ".x.swa", "dir/.y.swp", "file.swx", "a.tmp", "b~"] {
			XCTAssertTrue(FileSystemService.isTempSaveName(name), name)
		}
	}
}
