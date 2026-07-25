import XCTest
@testable import WorkspaceFileSystem
@testable import WorkspaceIgnore

final class FileSystemServiceVFSMigrationTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    private func createTestService(
        visitedPaths: Set<String> = [],
        visitedItems: [String: Bool] = [:],
        ignorePatterns: [String] = [],
        fs: InMemoryFS? = nil
    ) async throws -> FileSystemService {
        let testPath = "/tmp/test"
        
        // Create virtual filesystem if not provided
        let virtualFS = fs ?? InMemoryFS()
        
        // Ensure test directory exists
        virtualFS.addFolder(testPath)
        
        // Create .gitignore with provided patterns
        if !ignorePatterns.isEmpty {
            virtualFS.writeGitignore(at: testPath, ignorePatterns.joined(separator: "\n"))
        }
        
        let service = try await FileSystemService(
            path: testPath,
            respectGitignore: true,
            skipSymlinks: true,
            testVisitedPaths: visitedPaths,
            testVisitedItems: visitedItems,
            testIgnoreRules: nil, // Let it load from virtual FS
            isTestMode: true,
            fileManagerOverride: virtualFS
        )
        
        return service
    }
    
    private func createFSEvent(
        path: String,
        flags: FSEventStreamEventFlags
    ) -> (absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId) {
        return (absolutePath: path, flags: flags, eventId: 0)
    }
    
    // MARK: - Migrated Tests
    
    func testRenameWithinIgnoredTreeIsDiscarded() async throws {
        // Setup: Rename within an ignored directory
        let renamedFile = "node_modules/package/old.js"
        let fs = InMemoryFS()
        
        // Create node_modules structure
        fs.addFolder("/tmp/test/node_modules")
        fs.addFolder("/tmp/test/node_modules/package")
        fs.addFile("/tmp/test/node_modules/package/old.js")
        
        let service = try await createTestService(
            visitedPaths: [],
            visitedItems: [:],
            ignorePatterns: ["node_modules/"],
            fs: fs
        )
        
        // Create a rename event for a file in ignored directory
        let event = createFSEvent(
            path: "/tmp/test/\(renamedFile)",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        )
        
        // Process the event
        let deltas = await service.simulateFSEvents([event])
        
        // Verify: Rename within ignored tree should be discarded
        XCTAssertTrue(deltas.isEmpty, "Rename within ignored tree should be discarded")
    }
    
    func testAtomicSaveRenameProcessed() async throws {
        // Setup: Temp file being renamed to a tracked file
        let trackedFile = "src/main.swift"
        let tempFile = "src/.main.swift.tmp"
        let fs = InMemoryFS()
        
        // Create file structure
        fs.addFolder("/tmp/test/src")
        fs.addFile("/tmp/test/src/main.swift")
        fs.addFile("/tmp/test/src/.main.swift.tmp")
        
        let service = try await createTestService(
            visitedPaths: [trackedFile],
            visitedItems: [trackedFile: false],
            ignorePatterns: ["*.tmp"],
            fs: fs
        )
        
        // For atomic saves, we need both source (removed) and destination (created) events
        // as real FSEvents would emit
        let events = [
            createFSEvent(
                path: "/tmp/test/\(tempFile)",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved)
            ),
            createFSEvent(
                path: "/tmp/test/\(trackedFile)",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCreated)
            )
        ]
        
        // Process the events
        let deltas = await service.simulateFSEvents(events)
        
        // Verify: Rename to tracked file should be processed
        XCTAssertFalse(deltas.isEmpty, "Rename to tracked file should be processed")
    }
    
    func testIgnoreFileEventsAreAlwaysProcessed() async throws {
        // Setup: .gitignore file in an ignored directory
        let ignoreFile = "build/.gitignore"
        let fs = InMemoryFS()

        // Create structure and add the gitignore file to filesystem
        fs.addFolder("/tmp/test/build")
        fs.addFile("/tmp/test/build/.gitignore")  // File must exist when event fires

        let service = try await createTestService(
            visitedPaths: [],
            visitedItems: [:],
            ignorePatterns: ["build/"],
            fs: fs
        )

        // Create event for .gitignore in ignored directory
        let event = createFSEvent(
            path: "/tmp/test/\(ignoreFile)",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )

        // Process the event
        let deltas = await service.simulateFSEvents([event])

        // Verify: Ignore files are control metadata - they update caches/filters
        // but do not emit FileSystemDelta entries, even in ignored directories.
        XCTAssertTrue(deltas.isEmpty, "Ignore files are control metadata and should not emit deltas")

        // The event IS processed (triggers parent folder scan), just doesn't produce visible deltas
        let processedFolders = await service.getProcessedFolders()
        XCTAssertTrue(processedFolders.contains("build"), "Ignore file event should trigger parent folder processing")
    }
    
    func testMultipleEventsWithMixedConditions() async throws {
        let fs = InMemoryFS()
        
        // Create file structure
        fs.addFolder("/tmp/test/src")
        fs.addFolder("/tmp/test/node_modules")
        fs.addFolder("/tmp/test/build")
        fs.addFile("/tmp/test/src/tracked.swift")
        fs.addFile("/tmp/test/src/new.swift")
        
        let service = try await createTestService(
            visitedPaths: ["src/tracked.swift"],
            visitedItems: ["src/tracked.swift": false],
            ignorePatterns: ["node_modules/", "build/", "*.tmp"],
            fs: fs
        )
        
        // Create various events
        let events = [
            createFSEvent(path: "/tmp/test/src/tracked.swift", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)),
            createFSEvent(path: "/tmp/test/src/new.swift", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)),
            createFSEvent(path: "/tmp/test/node_modules/package/index.js", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)),
            createFSEvent(path: "/tmp/test/build/output.js", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)),
            createFSEvent(path: "/tmp/test/src/temp.tmp", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))
        ]
        
        // Process events
        let deltas = await service.simulateFSEvents(events)
        
        // Verify: Only tracked and non-ignored new files should be processed
        // We expect: tracked.swift (modified) and new.swift (added)
        XCTAssertEqual(deltas.count, 2, "Should process 2 events (tracked + non-ignored new)")
        
        // Check that we got the right files
        let processedPaths = deltas.compactMap { delta -> String? in
            switch delta {
            case .fileModified(let path, _):
                return path
            case .fileAdded(let path):
                return path
            default:
                return nil
            }
        }
        
        XCTAssertTrue(processedPaths.contains("src/tracked.swift"))
        XCTAssertTrue(processedPaths.contains("src/new.swift"))
    }
    
    func testIgnoreRuleTransitions() async throws {
        let fs = InMemoryFS()
        
        // Initial setup without ignore rules
        fs.addFolder("/tmp/test/temp")
        fs.addFile("/tmp/test/temp/file.txt")
        
        var service = try await createTestService(
            visitedPaths: [],
            visitedItems: [:],
            ignorePatterns: [],
            fs: fs
        )
        
        // First event - should be processed (no ignore rules)
        let event1 = createFSEvent(
            path: "/tmp/test/temp/file.txt",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        )
        
        let deltas1 = await service.simulateFSEvents([event1])
        XCTAssertFalse(deltas1.isEmpty, "Without ignore rules, file should be processed")
        
        // Now add ignore rule
        fs.writeGitignore(at: "/tmp/test", "temp/")
        
        // Recreate service to pick up new ignore rules
        service = try await createTestService(
            visitedPaths: Set(await service.getTrackedPaths()),
            visitedItems: await service.getTestState().visitedItems,
            fs: fs
        )
        
        // Trigger ignore file change event
        let ignoreChangeEvent = createFSEvent(
            path: "/tmp/test/.gitignore",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        )
        _ = await service.simulateFSEvents([ignoreChangeEvent])
        
        // Second event - new file in now-ignored directory
        let event2 = createFSEvent(
            path: "/tmp/test/temp/newfile.txt",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )
        
        let deltas2 = await service.simulateFSEvents([event2])
        XCTAssertTrue(deltas2.isEmpty, "With new ignore rules, new files in temp/ should be filtered")
    }

    // MARK: - Cross-isolation ownership of the TestFS seam

    /// Regression coverage for `TestFSTransfer` (the one `@unchecked Sendable`
    /// box in WorkspaceIgnore). One `InMemoryFS` double is deliberately shared
    /// by three isolation domains at once:
    ///
    /// 1. the `FileSystemService` actor (directory enumeration / attributes),
    /// 2. the `IgnoreRulesManager` actor — which only sees the virtual
    ///    `.gitignore` if the double actually crossed the boundary during
    ///    `FileSystemService.init`, and
    /// 3. plain concurrent tasks mutating and querying the double directly.
    ///
    /// The ignore assertion is the proof that (2) happened: `vendor/` is only
    /// ignorable if `IgnoreRulesManager` read the `.gitignore` out of the same
    /// virtual tree. The positive control rules out "empty because nothing was
    /// processed".
    func testVirtualFSOverrideIsSharedSafelyAcrossIsolationDomains() async throws {
        let fs = InMemoryFS()
        fs.addFolder("/tmp/test/vendor")
        fs.addFile("/tmp/test/vendor/lib.js")
        fs.addFolder("/tmp/test/src")
        fs.addFile("/tmp/test/src/app.swift")

        let service = try await createTestService(
            visitedPaths: [],
            visitedItems: [:],
            ignorePatterns: ["vendor/"],
            fs: fs
        )

        // Hammer the same double from 64 unstructured tasks while the two
        // actors above are also reading it.
        let hammer = Task.detached {
            await withTaskGroup(of: Bool.self) { group in
                for i in 0..<64 {
                    group.addTask {
                        let path = "/tmp/test/src/gen\(i).swift"
                        fs.addFile(path)
                        var isDir: ObjCBool = false
                        return fs.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
                    }
                }
                var allPresent = true
                for await present in group where !present {
                    allPresent = false
                }
                return allPresent
            }
        }

        let ignoredDeltas = await service.simulateFSEvents([
            createFSEvent(
                path: "/tmp/test/vendor/lib.js",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            )
        ])
        let trackedDeltas = await service.simulateFSEvents([
            createFSEvent(
                path: "/tmp/test/src/app.swift",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            )
        ])

        let allPresent = await hammer.value
        XCTAssertTrue(allPresent, "every concurrently written path must be visible in the shared double")
        XCTAssertTrue(
            ignoredDeltas.isEmpty,
            "vendor/ must be ignored — proves the virtual .gitignore reached the IgnoreRulesManager actor"
        )
        XCTAssertFalse(
            trackedDeltas.isEmpty,
            "positive control: a non-ignored file under the same virtual root must still produce a delta"
        )
    }
}