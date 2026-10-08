import Foundation
import XCTest
@testable import WorkspaceFileSystem
import WorkspaceKit

/// Characterization of the FSEvents-backed WorkspaceFileWatching adapter
/// (adoption slice 5 — watcher unification). Mirrors the polling
/// MacOSWorkspaceFileManager suite's lifecycle expectations.
@MainActor
final class FileSystemServiceWorkspaceWatcherTests: XCTestCase {
	private var tempDir: URL!

	override func setUp() async throws {
		tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("WatcherUnificationTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: tempDir)
	}

	func testEventsBeforeStartIsFinishedStream() async throws {
		let watcher = FileSystemServiceWorkspaceWatcher()
		var count = 0
		for await _ in watcher.events { count += 1 }
		XCTAssertEqual(count, 0)
	}

	func testCreateAndModifyAreObserved() async throws {
		let seed = tempDir.appendingPathComponent("seed.txt")
		try Data("v1".utf8).write(to: seed)

		let watcher = FileSystemServiceWorkspaceWatcher()
		try await watcher.startWatching(root: tempDir)
		defer { watcher.stopWatching() }

		actor Log {
			var events: [WorkspaceFileEvent] = []
			func add(_ e: WorkspaceFileEvent) { events.append(e) }
		}
		let log = Log()
		let recorder = Task { [events = watcher.events] in
			for await event in events { await log.add(event) }
		}
		defer { recorder.cancel() }

		// Give FSEvents a beat to arm before mutating.
		try await Task.sleep(nanoseconds: 1_000_000_000)

		let created = tempDir.appendingPathComponent("new.txt")
		try Data("new".utf8).write(to: created)
		try Data("v2 longer".utf8).write(to: seed)

		func waitFor(_ predicate: @escaping ([WorkspaceFileEvent]) -> Bool) async -> Bool {
			let deadline = Date().addingTimeInterval(20)
			while Date() < deadline {
				if predicate(await log.events) { return true }
				try? await Task.sleep(nanoseconds: 250_000_000)
			}
			return predicate(await log.events)
		}

		let sawCreate = await waitFor { events in
			events.contains {
				if case .created(let url) = $0 { return url.lastPathComponent == "new.txt" }
				return false
			}
		}
		XCTAssertTrue(sawCreate, "expected a .created event for new.txt")

		let sawModify = await waitFor { events in
			events.contains {
				if case .modified(let url) = $0 { return url.lastPathComponent == "seed.txt" }
				return false
			}
		}
		XCTAssertTrue(sawModify, "expected a .modified event for seed.txt")
	}

	/// A file that existed before `startWatching` must report `.modified` on
	/// its first change. Unlike `testCreateAndModifyAreObserved`, nothing else
	/// changes, so no sibling-triggered rescan can register the file first —
	/// the watcher's own initial scan has to.
	func testFirstModificationOfPreexistingFileIsModified() async throws {
		let existing = tempDir.appendingPathComponent("existing.txt")
		try Data("v1".utf8).write(to: existing)

		let watcher = FileSystemServiceWorkspaceWatcher()
		try await watcher.startWatching(root: tempDir)
		defer { watcher.stopWatching() }

		actor Log {
			var events: [WorkspaceFileEvent] = []
			func add(_ e: WorkspaceFileEvent) { events.append(e) }
		}
		let log = Log()
		let recorder = Task { [events = watcher.events] in
			for await event in events { await log.add(event) }
		}
		defer { recorder.cancel() }

		// Give FSEvents a beat to arm before mutating.
		try await Task.sleep(nanoseconds: 1_000_000_000)
		try Data("v2 longer".utf8).write(to: existing)

		let deadline = Date().addingTimeInterval(20)
		var sawModify = false
		while Date() < deadline, !sawModify {
			sawModify = await log.events.contains {
				if case .modified(let url) = $0 { return url.lastPathComponent == "existing.txt" }
				return false
			}
			if !sawModify { try? await Task.sleep(nanoseconds: 250_000_000) }
		}
		let events = await log.events
		XCTAssertTrue(sawModify, "expected a .modified event for existing.txt; got \(events)")
	}

	func testDeletionsAreObserved() async throws {
		let watcher = FileSystemServiceWorkspaceWatcher()
		try await watcher.startWatching(root: tempDir)
		defer { watcher.stopWatching() }

		actor Log {
			var events: [WorkspaceFileEvent] = []
			func add(_ e: WorkspaceFileEvent) { events.append(e) }
		}
		let log = Log()
		let recorder = Task { [events = watcher.events] in
			for await event in events { await log.add(event) }
		}
		defer { recorder.cancel() }

		// Give FSEvents a beat to arm before mutating.
		try await Task.sleep(nanoseconds: 1_000_000_000)

		func waitFor(_ predicate: @escaping ([WorkspaceFileEvent]) -> Bool) async -> Bool {
			let deadline = Date().addingTimeInterval(20)
			while Date() < deadline {
				if predicate(await log.events) { return true }
				try? await Task.sleep(nanoseconds: 250_000_000)
			}
			return predicate(await log.events)
		}

		func sawDeleted(_ name: String, in events: [WorkspaceFileEvent]) -> Bool {
			events.contains {
				if case .deleted(let url) = $0 { return url.lastPathComponent == name }
				return false
			}
		}

		// Create the doomed items while watching so the engine tracks them
		// (deletion deltas are only emitted for known paths).
		let doomedFile = tempDir.appendingPathComponent("doomed.txt")
		try Data("bye".utf8).write(to: doomedFile)
		let doomedFolder = tempDir.appendingPathComponent("doomed-folder", isDirectory: true)
		try FileManager.default.createDirectory(at: doomedFolder, withIntermediateDirectories: true)
		let doomedChild = doomedFolder.appendingPathComponent("child.txt")
		try Data("child".utf8).write(to: doomedChild)

		let tracked = await waitFor { events in
			let created = Set(events.compactMap { event -> String? in
				if case .created(let url) = event { return url.lastPathComponent }
				return nil
			})
			return created.isSuperset(of: ["doomed.txt", "child.txt"])
		}
		XCTAssertTrue(tracked, "expected .created events for doomed.txt and child.txt before deleting")

		try FileManager.default.removeItem(at: doomedFile)
		try FileManager.default.removeItem(at: doomedFolder)

		let sawFileDelete = await waitFor { sawDeleted("doomed.txt", in: $0) }
		XCTAssertTrue(sawFileDelete, "expected a .deleted event for doomed.txt")

		let sawFolderDelete = await waitFor { sawDeleted("doomed-folder", in: $0) }
		XCTAssertTrue(sawFolderDelete, "expected a .deleted event for doomed-folder")

		let sawChildDelete = await waitFor { sawDeleted("child.txt", in: $0) }
		XCTAssertTrue(sawChildDelete, "expected a .deleted event for child.txt (subtree sweep must reach watcher consumers)")
	}

	// MARK: - changesStream() ownership boundary

	/// `FileSystemServiceWorkspaceWatcher` no longer pulls a Combine
	/// `AnyPublisher`/`AnyCancellable` out of the engine actor (neither is
	/// `Sendable`); it consumes `FileSystemService.changesStream()` instead.
	/// This pins the two halves of that boundary's contract:
	///
	/// - every published batch reaches the consumer, in publish order, and
	/// - when the consumer stops iterating, the engine-side Combine
	///   subscription is released rather than leaked.
	func testChangesStreamDeliversBatchesInOrderAndReleasesSubscription() async throws {
		let root = "/tmp/changes-stream-\(UUID().uuidString)"
		let fs = InMemoryFS()
		fs.addFolder(root)
		fs.addFolder("\(root)/src")

		let service = try await FileSystemService(
			path: root,
			respectGitignore: true,
			skipSymlinks: true,
			testVisitedPaths: [],
			testVisitedItems: [:],
			testIgnoreRules: nil,
			isTestMode: true,
			fileManagerOverride: fs
		)

		// Scoped so the consuming task is the ONLY owner of the stream, exactly
		// like `FileSystemServiceWorkspaceWatcher.forwardingTask`. Releasing
		// the last iterator is what tears the subscription down.
		let collector: Task<[[FileSystemDelta]], Never>
		do {
			let stream = await service.changesStream()
			let liveWhileSubscribed = await service.liveChangesStreamCount
			XCTAssertEqual(liveWhileSubscribed, 1, "changesStream() must retain its subscription on the engine actor")

			collector = Task {
				var batches: [[FileSystemDelta]] = []
				for await batch in stream {
					batches.append(batch)
					if batches.count == 2 { break }
				}
				return batches
			}
		}

		fs.addFile("\(root)/src/a.swift")
		_ = await service.simulateFSEvents([
			(
				absolutePath: "\(root)/src/a.swift",
				flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
				eventId: FSEventStreamEventId(1)
			)
		])
		fs.addFile("\(root)/src/b.swift")
		_ = await service.simulateFSEvents([
			(
				absolutePath: "\(root)/src/b.swift",
				flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
				eventId: FSEventStreamEventId(2)
			)
		])

		let batches = await collector.value
		XCTAssertEqual(batches.count, 2, "both published batches must reach the stream consumer")
		XCTAssertTrue(
			batches[0].contains(.fileAdded("src/a.swift")),
			"first batch must be the first publish, not a reordered one: \(batches)"
		)
		XCTAssertTrue(
			batches[1].contains(.fileAdded("src/b.swift")),
			"second batch must be the second publish: \(batches)"
		)

		// Termination hops back onto the actor, so poll (bounded) rather than
		// assuming the release is synchronous with the consumer exiting.
		var live = await service.liveChangesStreamCount
		for _ in 0..<200 where live != 0 {
			try await Task.sleep(nanoseconds: 5_000_000)
			live = await service.liveChangesStreamCount
		}
		XCTAssertEqual(live, 0, "the engine-side subscription must be released once the consumer stops iterating")
	}

	func testStopFinishesStream() async throws {
		let watcher = FileSystemServiceWorkspaceWatcher()
		try await watcher.startWatching(root: tempDir)
		let events = watcher.events
		watcher.stopWatching()
		for await _ in events {}
		var postStop = 0
		for await _ in watcher.events { postStop += 1 }
		XCTAssertEqual(postStop, 0)
	}
}
