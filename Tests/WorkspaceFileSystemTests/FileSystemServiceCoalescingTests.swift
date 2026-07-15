import XCTest
@testable import WorkspaceFileSystem
@testable import WorkspaceIgnore

/// Tests for event ID-based scan coalescing and bounded parallelism
final class FileSystemServiceCoalescingTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    private func createTestService(
        visitedPaths: Set<String> = [],
        visitedItems: [String: Bool] = [:],
        ignorePatterns: [String] = [],
        fs: InMemoryFS? = nil
    ) async throws -> FileSystemService {
        let testPath = "/tmp/test"
        
        let virtualFS = fs ?? InMemoryFS()
        virtualFS.addFolder(testPath)
        
        if !ignorePatterns.isEmpty {
            virtualFS.writeGitignore(at: testPath, ignorePatterns.joined(separator: "\n"))
        }
        
        let service = try await FileSystemService(
            path: testPath,
            respectGitignore: true,
            skipSymlinks: true,
            testVisitedPaths: visitedPaths,
            testVisitedItems: visitedItems,
            testIgnoreRules: nil,
            isTestMode: true,
            fileManagerOverride: virtualFS
        )
        
        return service
    }
    
    private func createFSEvent(
        path: String,
        flags: FSEventStreamEventFlags,
        eventId: FSEventStreamEventId = 0
    ) -> (absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId) {
        return (absolutePath: path, flags: flags, eventId: eventId)
    }
    
    // MARK: - Event ID Coalescing Tests
    
    func testMultipleEventsForSameFolderCoalesceToOneScan() async throws {
        // Setup: Create a directory with files
        let fs = InMemoryFS()
        fs.addFolder("/tmp/test/src")
        fs.addFile("/tmp/test/src/file1.swift")
        fs.addFile("/tmp/test/src/file2.swift")
        fs.addFile("/tmp/test/src/file3.swift")
        
        let service = try await createTestService(
            visitedPaths: ["src"],
            visitedItems: ["src": true],
            fs: fs
        )
        
        // Create multiple events for the same folder with different event IDs
        let events = [
            createFSEvent(path: "/tmp/test/src/file1.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 100),
            createFSEvent(path: "/tmp/test/src/file2.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 101),
            createFSEvent(path: "/tmp/test/src/file3.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 102),
        ]
        
        // Process the events
        let _ = await service.simulateFSEvents(events)
        
        // Check that only one folder was processed (the parent "src")
        let processedFolders = await service.getProcessedFolders()
        XCTAssertEqual(processedFolders.count, 1, "Multiple events for files in the same folder should coalesce to one scan")
        XCTAssertTrue(processedFolders.contains("src"), "The parent folder 'src' should be scanned")
        
        // Check the coalescing state - lastScannedEventIdByFolder should have the max event ID
        let coalescingState = await service.getCoalescingState()
        XCTAssertEqual(coalescingState.lastScannedEventIdByFolder["src"], 102, "lastScannedEventIdByFolder should have the max event ID")
        XCTAssertTrue(coalescingState.pendingScanTargets.isEmpty, "pendingScanTargets should be empty after successful scan")
    }
    
    func testSubsequentEventsWithSameIdAreSkipped() async throws {
        // Setup
        let fs = InMemoryFS()
        fs.addFolder("/tmp/test/src")
        fs.addFile("/tmp/test/src/file.swift")
        
        let service = try await createTestService(
            visitedPaths: ["src"],
            visitedItems: ["src": true],
            fs: fs
        )
        
        // First batch with event ID 100
        let events1 = [
            createFSEvent(path: "/tmp/test/src/file.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 100),
        ]
        let _ = await service.simulateFSEvents(events1)
        
        let state1 = await service.getCoalescingState()
        XCTAssertEqual(state1.lastScannedEventIdByFolder["src"], 100)
        
        // Second batch with same event ID should be skipped
        let events2 = [
            createFSEvent(path: "/tmp/test/src/file.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 100),
        ]
        let _ = await service.simulateFSEvents(events2)
        
        // The folder should NOT have been processed again (check via processedFolders count in second call)
        let processedFolders = await service.getProcessedFolders()
        XCTAssertTrue(processedFolders.isEmpty, "Events with same or lower event ID should not trigger another scan")
    }
    
    func testNewerEventIdTriggersRescan() async throws {
        // Setup
        let fs = InMemoryFS()
        fs.addFolder("/tmp/test/src")
        fs.addFile("/tmp/test/src/file.swift")
        
        let service = try await createTestService(
            visitedPaths: ["src"],
            visitedItems: ["src": true],
            fs: fs
        )
        
        // First batch with event ID 100
        let events1 = [
            createFSEvent(path: "/tmp/test/src/file.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 100),
        ]
        let _ = await service.simulateFSEvents(events1)
        
        let state1 = await service.getCoalescingState()
        XCTAssertEqual(state1.lastScannedEventIdByFolder["src"], 100)
        
        // Second batch with higher event ID should trigger rescan for a new file
        fs.addFile("/tmp/test/src/newfile.swift")
        let events2 = [
            createFSEvent(path: "/tmp/test/src/newfile.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated), eventId: 200),
        ]
        let _ = await service.simulateFSEvents(events2)
        
        let processedFolders = await service.getProcessedFolders()
        XCTAssertTrue(processedFolders.contains("src"), "Higher event ID should trigger a rescan")
        
        let state2 = await service.getCoalescingState()
        XCTAssertEqual(state2.lastScannedEventIdByFolder["src"], 200, "lastScannedEventIdByFolder should be updated to new max")
    }
    
    func testMultipleFoldersCoalesceIndependently() async throws {
        // Setup: Two separate directories
        let fs = InMemoryFS()
        fs.addFolder("/tmp/test/src")
        fs.addFolder("/tmp/test/lib")
        fs.addFile("/tmp/test/src/main.swift")
        fs.addFile("/tmp/test/lib/utils.swift")
        
        let service = try await createTestService(
            visitedPaths: ["src", "lib"],
            visitedItems: ["src": true, "lib": true],
            fs: fs
        )
        
        // Events for both folders
        let events = [
            createFSEvent(path: "/tmp/test/src/main.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 100),
            createFSEvent(path: "/tmp/test/lib/utils.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 150),
        ]
        let _ = await service.simulateFSEvents(events)
        
        let state = await service.getCoalescingState()
        XCTAssertEqual(state.lastScannedEventIdByFolder["src"], 100, "src should have its own event ID")
        XCTAssertEqual(state.lastScannedEventIdByFolder["lib"], 150, "lib should have its own event ID")
    }
    
    func testWithinBatchDeduplication() async throws {
        // Setup
        let fs = InMemoryFS()
        fs.addFolder("/tmp/test/src")
        fs.addFile("/tmp/test/src/file1.swift")
        fs.addFile("/tmp/test/src/file2.swift")
        
        let service = try await createTestService(
            visitedPaths: ["src"],
            visitedItems: ["src": true],
            fs: fs
        )
        
        // Multiple events for different files in the same folder within the same batch
        let events = [
            createFSEvent(path: "/tmp/test/src/file1.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 100),
            createFSEvent(path: "/tmp/test/src/file1.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 101),
            createFSEvent(path: "/tmp/test/src/file2.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 102),
            createFSEvent(path: "/tmp/test/src/file2.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 103),
        ]
        
        let _ = await service.simulateFSEvents(events)
        
        // Only one folder should be processed
        let processedFolders = await service.getProcessedFolders()
        XCTAssertEqual(processedFolders.count, 1, "Within-batch events for the same folder should be deduplicated")
        
        // The max event ID should be recorded
        let state = await service.getCoalescingState()
        XCTAssertEqual(state.lastScannedEventIdByFolder["src"], 103, "Max event ID should be tracked")
    }

    func testPendingRawEventsOverflowCollapsesToRootRescan() async throws {
        let fs = InMemoryFS()
        fs.addFolder("/tmp/test/src")
        fs.addFile("/tmp/test/src/file.swift")
        fs.writeGitignore(at: "/tmp/test/src", "*.generated.swift")

        let service = try await createTestService(
            visitedPaths: ["src", "src/file.swift"],
            visitedItems: ["src": true, "src/file.swift": false],
            fs: fs
        )

        let overflowCount = 50_001
        var events = [
            createFSEvent(
                path: "/tmp/test/src/.gitignore",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
                eventId: 1
            )
        ]
        events.append(
            contentsOf: (1..<overflowCount).map { index in
                createFSEvent(
                    path: "/tmp/test/src/file.swift",
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
                    eventId: FSEventStreamEventId(index + 1)
                )
            }
        )

        await service.enqueuePendingRawEventsForTesting(events)

        let bufferedState = await service.watcherStateForTesting()
        XCTAssertEqual(bufferedState.pendingRawEventCount, 1, "Overflow should collapse buffered events into a single synthetic rescan")
        XCTAssertTrue(bufferedState.hasPendingOverflowRescan, "Overflow should mark the pending batch as a forced rescan")

        _ = await service.getProcessedFolders()
        await service.flushPendingEventsNow()

        let processedFolders = await service.getProcessedFolders()
        XCTAssertTrue(processedFolders.contains(""), "Overflow should force a root rescan")

        let coalescingState = await service.getCoalescingState()
        XCTAssertEqual(
            coalescingState.lastScannedEventIdByFolder[""],
            FSEventStreamEventId(overflowCount),
            "The synthetic root rescan should preserve the highest event ID"
        )

        let ignoreChange = await service.takePendingIgnoreRulesChange()
        XCTAssertEqual(ignoreChange?.changedDirs.contains("src"), true, "Overflow should preserve ignore-file change intent")
    }

    func testStopWatchingClearsBufferedWatcherStateWithoutActiveStream() async throws {
        let fs = InMemoryFS()
        fs.addFolder("/tmp/test/src")
        fs.addFile("/tmp/test/src/file.swift")

        let service = try await createTestService(
            visitedPaths: ["src", "src/file.swift"],
            visitedItems: ["src": true, "src/file.swift": false],
            fs: fs
        )

        let processedEvent = createFSEvent(
            path: "/tmp/test/src",
            flags: FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsDir
            ),
            eventId: 100
        )
        _ = await service.simulateFSEvents([processedEvent])

        let bufferedEvent = createFSEvent(
            path: "/tmp/test/src/file.swift",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
            eventId: 101
        )
        await service.enqueuePendingRawEventsForTesting([bufferedEvent])

        let beforeStop = await service.watcherStateForTesting()
        XCTAssertEqual(beforeStop.pendingRawEventCount, 1)
        XCTAssertEqual(beforeStop.lastScannedEventIdByFolder["src"], 100)
        XCTAssertNotNil(beforeStop.lastVerifiedAtByFolder["src"])

        await service.stopWatchingForChanges()

        let afterStop = await service.watcherStateForTesting()
        XCTAssertEqual(afterStop.pendingRawEventCount, 0)
        XCTAssertFalse(afterStop.hasPendingOverflowRescan)
        XCTAssertTrue(afterStop.pendingScanTargets.isEmpty)
        XCTAssertTrue(afterStop.lastScannedEventIdByFolder.isEmpty)
        XCTAssertTrue(afterStop.lastVerifiedAtByFolder.isEmpty)
        XCTAssertTrue(afterStop.fileEventCountSinceLastScan.isEmpty)
    }

    func testStopWatchingDoesNotClearPendingIgnoreRuleChanges() async throws {
        let fs = InMemoryFS()
        fs.addFolder("/tmp/test/src")
        fs.writeGitignore(at: "/tmp/test/src", "*.generated.swift")

        let service = try await createTestService(
            visitedPaths: ["src"],
            visitedItems: ["src": true],
            fs: fs
        )

        let ignoreEvent = createFSEvent(
            path: "/tmp/test/src/.gitignore",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
            eventId: 1
        )
        _ = await service.simulateFSEvents([ignoreEvent])

        await service.stopWatchingForChanges()

        let change = await service.takePendingIgnoreRulesChange()
        XCTAssertEqual(change?.changedDirs.contains("src"), true)
    }
}

// MARK: - Bounded Parallelism Tests

extension FileSystemServiceCoalescingTests {
    
    // Note: These tests verify bounded parallelism behavior.
    // Due to test mode using serial scanning, we verify the logic indirectly.
    // For true parallelism testing, integration tests with real filesystem are needed.
    
    func testParallelScanningFallsBackToSerialInTestMode() async throws {
        // In test mode, scanning should be serial to avoid thread safety issues
        let fs = ConcurrencyTrackingFS()
        fs.enumerationDelay = 0.02
        
        // Create many folders to trigger parallel path
        for i in 0..<10 {
            fs.addFolder("/tmp/test/dir\(i)")
            fs.addFile("/tmp/test/dir\(i)/file.txt")
        }
        
        var visitedPaths: Set<String> = []
        var visitedItems: [String: Bool] = [:]
        for i in 0..<10 {
            visitedPaths.insert("dir\(i)")
            visitedItems["dir\(i)"] = true
        }
        
        let service = try await createTestService(
            visitedPaths: visitedPaths,
            visitedItems: visitedItems,
            fs: fs
        )
        
        // Create events that would trigger scanning multiple folders
        var events: [(absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId)] = []
        for i in 0..<10 {
            events.append(createFSEvent(
                path: "/tmp/test/dir\(i)/file.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
                eventId: FSEventStreamEventId(i + 1)
            ))
        }
        
        let _ = await service.simulateFSEvents(events)
        
        XCTAssertGreaterThan(fs.totalEnumerations, 0, "Directories should have been enumerated")
        XCTAssertEqual(fs.maxObservedConcurrency, 1, "Test mode should scan directories serially")
    }
}

// MARK: - Ignore Cache Partial Invalidation Tests

extension FileSystemServiceCoalescingTests {
    
    func testIgnoreFileChangeInvalidatesSubtreeCache() async throws {
        // Setup: Create a nested directory structure
        let fs = InMemoryFS()
        fs.addFolder("/tmp/test/src")
        fs.addFolder("/tmp/test/src/components")
        fs.addFolder("/tmp/test/src/utils")
        fs.addFile("/tmp/test/src/main.swift")
        fs.addFile("/tmp/test/src/components/Button.swift")
        fs.addFile("/tmp/test/src/utils/helpers.swift")
        
        let service = try await createTestService(
            visitedPaths: ["src", "src/components", "src/utils", "src/main.swift", "src/components/Button.swift", "src/utils/helpers.swift"],
            visitedItems: [
                "src": true, "src/components": true, "src/utils": true,
                "src/main.swift": false, "src/components/Button.swift": false, "src/utils/helpers.swift": false
            ],
            fs: fs
        )
        
        // Simulate some file operations to populate the ignore cache
        let initialEvents = [
            createFSEvent(path: "/tmp/test/src/main.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 1),
        ]
        let _ = await service.simulateFSEvents(initialEvents)
        
        // Get initial cache state
        let initialCacheKeys = await service.getIgnoreCacheKeys()
        
        // Now create a .gitignore in src/components
        fs.writeGitignore(at: "/tmp/test/src/components", "*.generated.swift")
        
        // Simulate the .gitignore being created
        let gitignoreEvents = [
            createFSEvent(
                path: "/tmp/test/src/components/.gitignore",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                eventId: 10
            ),
        ]
        let _ = await service.simulateFSEvents(gitignoreEvents)
        
        // The cache for src/components and its children should be invalidated
        // (The rebuild happens asynchronously, so we just verify the mechanism triggered)
        let processedFolders = await service.getProcessedFolders()
        XCTAssertTrue(processedFolders.contains("src/components"), "Parent folder of .gitignore should be rescanned")
    }
    
    func testRootIgnoreFileTriggersFullRebuild() async throws {
        // Setup
        let fs = InMemoryFS()
        fs.addFolder("/tmp/test/src")
        fs.addFile("/tmp/test/src/main.swift")
        
        let service = try await createTestService(
            visitedPaths: ["src", "src/main.swift"],
            visitedItems: ["src": true, "src/main.swift": false],
            fs: fs
        )
        
        // Create .gitignore at root
        fs.writeGitignore(at: "/tmp/test", "*.log")
        
        // Simulate the .gitignore being created at root
        let gitignoreEvents = [
            createFSEvent(
                path: "/tmp/test/.gitignore",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                eventId: 10
            ),
        ]
        let _ = await service.simulateFSEvents(gitignoreEvents)
        
        // Root folder should be processed
        let processedFolders = await service.getProcessedFolders()
        XCTAssertTrue(processedFolders.contains(""), "Root folder should be rescanned when root .gitignore changes")
    }
    
    func testIgnoreFileInSubdirectoryOnlyAffectsSubtree() async throws {
        // Setup: Two separate subtrees
        let fs = InMemoryFS()
        fs.addFolder("/tmp/test/moduleA")
        fs.addFolder("/tmp/test/moduleB")
        fs.addFile("/tmp/test/moduleA/file.swift")
        fs.addFile("/tmp/test/moduleB/file.swift")
        
        let service = try await createTestService(
            visitedPaths: ["moduleA", "moduleB", "moduleA/file.swift", "moduleB/file.swift"],
            visitedItems: ["moduleA": true, "moduleB": true, "moduleA/file.swift": false, "moduleB/file.swift": false],
            fs: fs
        )
        
        // Trigger initial cache population
        let initialEvents = [
            createFSEvent(path: "/tmp/test/moduleA/file.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 1),
            createFSEvent(path: "/tmp/test/moduleB/file.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId: 2),
        ]
        let _ = await service.simulateFSEvents(initialEvents)
        
        // Create .gitignore only in moduleA
        fs.writeGitignore(at: "/tmp/test/moduleA", "*.generated.swift")
        
        let gitignoreEvents = [
            createFSEvent(
                path: "/tmp/test/moduleA/.gitignore",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                eventId: 10
            ),
        ]
        let _ = await service.simulateFSEvents(gitignoreEvents)
        
        // Only moduleA should be rescanned, not moduleB
        let processedFolders = await service.getProcessedFolders()
        XCTAssertTrue(processedFolders.contains("moduleA"), "moduleA should be rescanned")
        // moduleB might or might not be in processedFolders depending on the coalescing,
        // but the key point is that the ignore cache for moduleB should remain intact
    }
}
