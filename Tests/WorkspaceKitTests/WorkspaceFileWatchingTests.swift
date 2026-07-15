import Foundation
import Testing
@testable import WorkspaceKit

#if canImport(AppKit)
/// The manager's watcher polls every 2 seconds, so these tests use generous
/// deadlines. They pin the created/modified/deleted event mapping and the
/// stream lifecycle. Events are drained into a recorder task so the test
/// never blocks unboundedly on `iterator.next()`.
@Suite("WorkspaceFileWatching", .serialized)
struct WorkspaceFileWatchingTests {
    private actor EventLog {
        private(set) var events: [WorkspaceFileEvent] = []
        func append(_ event: WorkspaceFileEvent) { events.append(event) }
    }

    @Test("events is an immediately-finished stream before startWatching")
    @MainActor
    func eventsBeforeStart() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = MacOSWorkspaceFileManager(rootURL: dir)
        var received = 0
        for await _ in manager.events { received += 1 }
        #expect(received == 0)
    }

    @Test("create, modify, and delete are observed as events", .timeLimit(.minutes(2)))
    @MainActor
    func watchLifecycle() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = dir.appendingPathComponent("seed.txt")
        try Data("v1".utf8).write(to: seed)

        let manager = MacOSWorkspaceFileManager(rootURL: dir)
        try await manager.startWatching(root: dir)
        let log = EventLog()
        let recorder = Task {
            for await event in manager.events {
                await log.append(event)
            }
        }
        defer {
            manager.stopWatching()
            recorder.cancel()
        }

        // The watcher's initial snapshot runs in a MainActor task queued by
        // startWatching; yield until it has run so our mutations land AFTER
        // the snapshot (they'd otherwise be baked into it and never reported).
        try await Task.sleep(nanoseconds: 500_000_000)

        // Mutate after the initial snapshot: one create, one modify.
        let created = dir.appendingPathComponent("new.txt")
        try Data("new".utf8).write(to: created)
        try Data("v2 longer".utf8).write(to: seed)
        // Ensure the mtime moves even on coarse filesystems.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: seed.path
        )

        func waitFor(_ predicate: @escaping ([WorkspaceFileEvent]) -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if predicate(await log.events) { return true }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return predicate(await log.events)
        }

        let sawCreateAndModify = await waitFor { events in
            events.contains {
                if case .created(let url) = $0 { return url.lastPathComponent == "new.txt" }
                return false
            } && events.contains {
                if case .modified(let url) = $0 { return url.lastPathComponent == "seed.txt" }
                return false
            }
        }
        #expect(sawCreateAndModify)

        try FileManager.default.removeItem(at: created)
        let sawDelete = await waitFor { events in
            events.contains {
                if case .deleted(let url) = $0 { return url.lastPathComponent == "new.txt" }
                return false
            }
        }
        #expect(sawDelete)
    }

    @Test("stopWatching finishes the event stream", .timeLimit(.minutes(1)))
    @MainActor
    func stopFinishesStream() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = MacOSWorkspaceFileManager(rootURL: dir)
        try await manager.startWatching(root: dir)
        let events = manager.events
        manager.stopWatching()
        // The drain below only returns if stopWatching finished the stream;
        // the .timeLimit trait converts a hang into a failure.
        for await _ in events {}
        // After stop, `events` falls back to an immediately-finished stream.
        var postStopEvents = 0
        for await _ in manager.events { postStopEvents += 1 }
        #expect(postStopEvents == 0)
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorkspaceKitWatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
#endif
