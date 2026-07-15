import XCTest
@testable import WorkspaceFileSystem
@testable import WorkspaceIgnore

/// Extended test coverage for FileSystemService covering gaps identified in test review
final class FileSystemServiceExtendedTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    private func createTestService(
        fs: SpyFS,
        visitedPaths: Set<String> = [],
        visitedItems: [String: Bool] = [:],
        enableHierarchicalIgnores: Bool = true,
        respectGitignore: Bool = true,
        respectRepoIgnore: Bool = true,
        respectCursorignore: Bool = true
    ) async throws -> FileSystemService {
        let testPath = "/test/repo"
        
        // Ensure root directory exists
        fs.addFolder("/test")
        fs.addFolder("/test/repo")
        
        let service = try await FileSystemService(
            path: testPath,
            respectGitignore: respectGitignore,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            skipSymlinks: true,
            enableHierarchicalIgnores: enableHierarchicalIgnores,
            testVisitedPaths: visitedPaths,
            testVisitedItems: visitedItems,
            testIgnoreRules: nil,
            isTestMode: true,
            fileManagerOverride: fs
        )
        
        // Set configuration
        await service.updateEnableHierarchicalIgnores(enableHierarchicalIgnores)
        
        return service
    }
    
    private func createFSEvent(
        path: String,
        flags: FSEventStreamEventFlags
    ) -> (absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId) {
        return (path, flags, 1)
    }
    
    // MARK: - Deletion Event Tests
    
    func testFileAndFolderDeletionEvents() async throws {
        let fs = SpyFS()
        
        // Create initial structure
        fs.addFolder("/test/repo/src")
        fs.addFolder("/test/repo/docs")
        fs.addFile("/test/repo/src/main.swift")
        fs.addFile("/test/repo/docs/readme.md")
        
        // Track all files
        let service = try await createTestService(
            fs: fs,
            visitedPaths: ["src", "docs", "src/main.swift", "docs/readme.md"],
            visitedItems: ["src": true, "docs": true, "src/main.swift": false, "docs/readme.md": false]
        )
        
        // Simulate deletion of a file
        fs.remove("/test/repo/src/main.swift")
        let fileDeleteEvent = createFSEvent(
            path: "/test/repo/src/main.swift",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
        )
        
        let deltas1 = await service.simulateFSEvents([fileDeleteEvent])
        
        // Verify file removal delta
        XCTAssertTrue(deltas1.contains { delta in
            if case .fileRemoved("src/main.swift") = delta { return true }
            return false
        }, "Should generate fileRemoved delta for deleted file")
        
        // Simulate deletion of entire folder
        fs.remove("/test/repo/docs")
        let folderDeleteEvent = createFSEvent(
            path: "/test/repo/docs",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir)
        )
        
        let deltas2 = await service.simulateFSEvents([folderDeleteEvent])
        
        // Verify folder and its contents are removed
        let removedPaths = deltas2.compactMap { delta -> String? in
            switch delta {
            case .fileRemoved(let path), .folderRemoved(let path):
                return path
            default:
                return nil
            }
        }
        
        XCTAssertTrue(removedPaths.contains("docs"), "Should remove the folder")
        XCTAssertTrue(removedPaths.contains("docs/readme.md"), "Should remove files in deleted folder")

        // Pin visited-state transitions: deletion sweeps the subtree out of
        // visitedPaths/visitedItems and leaves siblings untouched.
        let state = await service.getTestState()
        XCTAssertFalse(state.visitedPaths.contains("src/main.swift"), "Deleted file should leave visitedPaths")
        XCTAssertFalse(state.visitedPaths.contains("docs"), "Deleted folder should leave visitedPaths")
        XCTAssertFalse(state.visitedPaths.contains("docs/readme.md"), "Deleted folder's children should leave visitedPaths")
        XCTAssertNil(state.visitedItems["docs"], "Deleted folder should leave visitedItems")
        XCTAssertNil(state.visitedItems["docs/readme.md"], "Deleted folder's children should leave visitedItems")
        XCTAssertTrue(state.visitedPaths.contains("src"), "Sibling folder must stay tracked")
    }
    
    // MARK: - Folder Rename Tests
    
    func testFolderRenameUpdatesAllChildren() async throws {
        let fs = SpyFS()
        
        // Create folder structure
        fs.addFolder("/test/repo/old-name")
        fs.addFolder("/test/repo/old-name/sub")
        fs.addFile("/test/repo/old-name/file1.txt")
        fs.addFile("/test/repo/old-name/sub/file2.txt")
        
        // Track the structure
        let service = try await createTestService(
            fs: fs,
            visitedPaths: ["old-name", "old-name/sub", "old-name/file1.txt", "old-name/sub/file2.txt"],
            visitedItems: ["old-name": true, "old-name/sub": true, "old-name/file1.txt": false, "old-name/sub/file2.txt": false]
        )
        
        // Simulate folder rename
        fs.remove("/test/repo/old-name")
        fs.addFolder("/test/repo/new-name")
        fs.addFolder("/test/repo/new-name/sub")
        fs.addFile("/test/repo/new-name/file1.txt")
        fs.addFile("/test/repo/new-name/sub/file2.txt")
        
        let renameEvents = [
            createFSEvent(
                path: "/test/repo/old-name",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir)
            ),
            createFSEvent(
                path: "/test/repo/new-name",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)
            )
        ]
        
        let deltas = await service.simulateFSEvents(renameEvents)
        
        // Verify all old paths are removed
        let removedPaths = deltas.compactMap { delta -> String? in
            switch delta {
            case .fileRemoved(let path), .folderRemoved(let path):
                return path
            default:
                return nil
            }
        }
        
        let addedPaths = deltas.compactMap { delta -> String? in
            switch delta {
            case .fileAdded(let path), .folderAdded(let path):
                return path
            default:
                return nil
            }
        }
        
        XCTAssertTrue(removedPaths.contains("old-name"), "Old folder should be removed")
        XCTAssertTrue(removedPaths.contains("old-name/file1.txt"), "Files in old folder should be removed")
        XCTAssertTrue(addedPaths.contains("new-name"), "New folder should be added")
        XCTAssertTrue(addedPaths.contains("new-name/file1.txt"), "Files in new folder should be added")

        // Pin visited-state transitions: the paired rename sweeps the old
        // subtree and tracks the new folder plus its scanned first level.
        let state = await service.getTestState()
        for stale in ["old-name", "old-name/sub", "old-name/file1.txt", "old-name/sub/file2.txt"] {
            XCTAssertFalse(state.visitedPaths.contains(stale), "\(stale) should leave visitedPaths after rename")
            XCTAssertNil(state.visitedItems[stale], "\(stale) should leave visitedItems after rename")
        }
        XCTAssertTrue(state.visitedPaths.contains("new-name"), "Renamed folder should be tracked")
        XCTAssertEqual(state.visitedItems["new-name"], true)
        XCTAssertTrue(state.visitedPaths.contains("new-name/file1.txt"), "Scan of renamed folder should track its files")
    }

    // MARK: - Paired Rename / Move / Atomic Save Pinning

    func testPairedFileRenameEmitsRemoveAndAdd() async throws {
        let fs = SpyFS()
        fs.addFile("/test/repo/before.txt")

        let service = try await createTestService(
            fs: fs,
            visitedPaths: ["before.txt"],
            visitedItems: ["before.txt": false]
        )

        fs.remove("/test/repo/before.txt")
        fs.addFile("/test/repo/after.txt")

        let deltas = await service.simulateFSEvents([
            createFSEvent(
                path: "/test/repo/before.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved)
            ),
            createFSEvent(
                path: "/test/repo/after.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCreated)
            )
        ])

        XCTAssertTrue(deltas.contains { delta in
            if case .fileRemoved("before.txt") = delta { return true }
            return false
        }, "Rename source should be removed")
        XCTAssertTrue(deltas.contains { delta in
            if case .fileAdded("after.txt") = delta { return true }
            return false
        }, "Rename destination should be added")

        let state = await service.getTestState()
        XCTAssertFalse(state.visitedPaths.contains("before.txt"))
        XCTAssertTrue(state.visitedPaths.contains("after.txt"))
        XCTAssertEqual(state.visitedItems["after.txt"], false)
    }

    func testRenameOnlyEventForMissingKnownFolderRemovesSubtree() async throws {
        let fs = SpyFS()
        fs.addFolder("/test/repo/stale")
        fs.addFile("/test/repo/stale/file.txt")

        let service = try await createTestService(
            fs: fs,
            visitedPaths: ["stale", "stale/file.txt"],
            visitedItems: ["stale": true, "stale/file.txt": false]
        )

        // Finder trash / cross-directory moves deliver Renamed WITHOUT
        // Created or Removed; the path no longer exists at this location.
        fs.remove("/test/repo/stale")
        fs.remove("/test/repo/stale/file.txt")

        let deltas = await service.simulateFSEvents([
            createFSEvent(
                path: "/test/repo/stale",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir)
            )
        ])

        let removedPaths = deltas.compactMap { delta -> String? in
            switch delta {
            case .fileRemoved(let path), .folderRemoved(let path):
                return path
            default:
                return nil
            }
        }
        XCTAssertTrue(removedPaths.contains("stale"), "Moved-away folder should be removed")
        XCTAssertTrue(removedPaths.contains("stale/file.txt"), "Moved-away folder's children should be removed")

        let state = await service.getTestState()
        XCTAssertFalse(state.visitedPaths.contains("stale"))
        XCTAssertFalse(state.visitedPaths.contains("stale/file.txt"))
    }

    func testRenameOnlyEventForExistingUnknownFileAddsIt() async throws {
        let fs = SpyFS()
        let service = try await createTestService(fs: fs)

        fs.addFile("/test/repo/arrived.txt")

        let deltas = await service.simulateFSEvents([
            createFSEvent(
                path: "/test/repo/arrived.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
            )
        ])

        XCTAssertTrue(deltas.contains { delta in
            if case .fileAdded("arrived.txt") = delta { return true }
            return false
        }, "File moved into the root should be added")

        let state = await service.getTestState()
        XCTAssertTrue(state.visitedPaths.contains("arrived.txt"))
        XCTAssertEqual(state.visitedItems["arrived.txt"], false)
    }

    func testAtomicSaveOnKnownFileEmitsModification() async throws {
        let fs = SpyFS()
        fs.addFile("/test/repo/notes.txt")

        let service = try await createTestService(
            fs: fs,
            visitedPaths: ["notes.txt"],
            visitedItems: ["notes.txt": false]
        )

        // Editor atomic save: temp file renamed over the real path, so the
        // known path gets Renamed+Created and still exists on disk.
        let deltas = await service.simulateFSEvents([
            createFSEvent(
                path: "/test/repo/notes.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCreated)
            )
        ])

        XCTAssertTrue(deltas.contains { delta in
            if case .fileModified("notes.txt", _) = delta { return true }
            return false
        }, "Atomic save should surface as a modification")
        XCTAssertFalse(deltas.contains { delta in
            if case .fileAdded = delta { return true }
            return false
        }, "Atomic save must not re-add the file")
        XCTAssertFalse(deltas.contains { delta in
            if case .fileRemoved = delta { return true }
            return false
        }, "Atomic save must not remove the file")

        let state = await service.getTestState()
        XCTAssertTrue(state.visitedPaths.contains("notes.txt"))
    }

    func testMoveAwayOfKnownFileEmitsRemoval() async throws {
        let fs = SpyFS()
        fs.addFile("/test/repo/leaving.txt")

        let service = try await createTestService(
            fs: fs,
            visitedPaths: ["leaving.txt"],
            visitedItems: ["leaving.txt": false]
        )

        // Trash / mv-out delivers the same Renamed+Created pair as an atomic
        // save, but the file is gone — the disk check disambiguates.
        fs.remove("/test/repo/leaving.txt")

        let deltas = await service.simulateFSEvents([
            createFSEvent(
                path: "/test/repo/leaving.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCreated)
            )
        ])

        XCTAssertTrue(deltas.contains { delta in
            if case .fileRemoved("leaving.txt") = delta { return true }
            return false
        }, "Move-away should surface as a removal")
        XCTAssertFalse(deltas.contains { delta in
            if case .fileModified("leaving.txt", _) = delta { return true }
            return false
        }, "Move-away must not surface as a modification (coalescer drops the transient modify)")

        let state = await service.getTestState()
        XCTAssertFalse(state.visitedPaths.contains("leaving.txt"))
    }
    
    // MARK: - Concurrent Event Processing
    
    func testConcurrentEventProcessing() async throws {
        let fs = SpyFS()
        
        // Create many files
        for i in 0..<10 {
            fs.addFolder("/test/repo/folder\(i)")
            for j in 0..<10 {
                fs.addFile("/test/repo/folder\(i)/file\(j).txt")
            }
        }
        
        let service = try await createTestService(fs: fs)
        
        // Create many events
        var events: [(String, FSEventStreamEventFlags, FSEventStreamEventId)] = []
        for i in 0..<10 {
            for j in 0..<10 {
                events.append(createFSEvent(
                    path: "/test/repo/folder\(i)/file\(j).txt",
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
                ))
            }
        }
        
        // Create arrays before async let to avoid capturing mutable reference
        let events1 = Array(events[0..<25])
        let events2 = Array(events[25..<50])
        let events3 = Array(events[50..<75])
        let events4 = Array(events[75..<100])
        
        // Run multiple concurrent simulations
        async let deltas1 = service.simulateFSEvents(events1)
        async let deltas2 = service.simulateFSEvents(events2)
        async let deltas3 = service.simulateFSEvents(events3)
        async let deltas4 = service.simulateFSEvents(events4)
        
        let allDeltas = await [deltas1, deltas2, deltas3, deltas4].flatMap { $0 }
        
        // Verify we got all files (some may be duplicates due to folder scanning)
        let addedFiles = allDeltas.compactMap { delta -> String? in
            if case .fileAdded(let path) = delta { return path }
            return nil
        }
        
        // Should have at least 100 file additions (may have more due to folder scans)
        XCTAssertGreaterThanOrEqual(addedFiles.count, 100, "Should process all concurrent events")
    }
    
    // MARK: - Configuration Mode Tests
    
    func testDisabledHierarchicalIgnores() async throws {
        let fs = SpyFS()
        
        // Create nested structure with ignore files
        fs.addFolder("/test/repo")
        fs.addFolder("/test/repo/src")
        fs.addFolder("/test/repo/src/vendor")
        
        fs.writeGitignore(at: "/test/repo", "temp/")
        fs.addFile("/test/repo/.gitignore")
        
        fs.writeGitignore(at: "/test/repo/src", "!vendor/")  // Try to negate parent
        fs.addFile("/test/repo/src/.gitignore")
        
        fs.addFile("/test/repo/src/vendor/lib.js")
        
        // Test with hierarchical ignores disabled
        let service = try await createTestService(
            fs: fs,
            enableHierarchicalIgnores: false  // Disabled
        )
        
        let event = createFSEvent(
            path: "/test/repo/src/vendor/lib.js",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )
        
        let deltas = await service.simulateFSEvents([event])
        
        // With hierarchical disabled, only root rules apply
        XCTAssertFalse(deltas.isEmpty, "File should be processed when hierarchical ignores are disabled")
    }
    
    func testRespectGitignoreFalse() async throws {
        let fs = SpyFS()
        
        fs.addFolder("/test/repo")
        fs.writeGitignore(at: "/test/repo", "*.log")
        fs.addFile("/test/repo/.gitignore")
        fs.addFile("/test/repo/debug.log")
        
        // Also add a .repo_ignore to verify it still works
        fs.writeRepoIgnore(at: "/test/repo", "*.tmp")
        fs.addFile("/test/repo/.repo_ignore")
        fs.addFile("/test/repo/test.tmp")
        
        let service = try await createTestService(
            fs: fs,
            visitedPaths: [],
            visitedItems: [:],
            enableHierarchicalIgnores: false,  // Also disable hierarchical to ensure .gitignore is fully ignored
            respectGitignore: false  // Disabled - .gitignore should be ignored
        )
        
        // Test that .gitignore patterns are NOT applied
        let logEvent = createFSEvent(
            path: "/test/repo/debug.log",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )
        
        let logDeltas = await service.simulateFSEvents([logEvent])
        
        // debug.log should NOT be filtered even though .gitignore has *.log
        XCTAssertFalse(logDeltas.isEmpty, "Files matching .gitignore patterns should NOT be filtered when respectGitignore is false")
        
        // Test that .repo_ignore patterns ARE still applied
        let tmpEvent = createFSEvent(
            path: "/test/repo/test.tmp",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )
        
        let tmpDeltas = await service.simulateFSEvents([tmpEvent])
        
        // test.tmp should be filtered because .repo_ignore is still active
        XCTAssertTrue(tmpDeltas.isEmpty, ".repo_ignore patterns should still be applied when respectGitignore is false")
    }

    func testRespectRepoIgnoreToggleControlsRootRepoIgnore() async throws {
        let fs = SpyFS()

        fs.addFolder("/test/repo")
        fs.writeRepoIgnore(at: "/test/repo", "*.repoonly")
        fs.addFile("/test/repo/secret.repoonly")

        let service = try await createTestService(
            fs: fs,
            enableHierarchicalIgnores: false,
            respectRepoIgnore: true
        )

        let ignoredEvent = createFSEvent(
            path: "/test/repo/secret.repoonly",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )
        let ignoredDeltas = await service.simulateFSEvents([ignoredEvent])
        XCTAssertTrue(ignoredDeltas.isEmpty, ".repo_ignore should filter matching files while respectRepoIgnore is enabled")

        try await service.updateRespectRepoIgnore(false)

        let visibleEvent = (
            absolutePath: "/test/repo/secret.repoonly",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
            eventId: FSEventStreamEventId(2)
        )
        let visibleDeltas = await service.simulateFSEvents([visibleEvent])
        XCTAssertTrue(visibleDeltas.contains { delta in
            if case .fileAdded("secret.repoonly") = delta { return true }
            return false
        }, "Files matching .repo_ignore should be visible after respectRepoIgnore is disabled")
    }

    func testRespectCursorignoreToggleControlsRootCursorignoreWhenHierarchicalDisabled() async throws {
        let fs = SpyFS()

        fs.addFolder("/test/repo")
        fs.writeCursorignore(at: "/test/repo", "*.rootcursor")
        fs.addFile("/test/repo/output.rootcursor")

        let service = try await createTestService(
            fs: fs,
            enableHierarchicalIgnores: false,
            respectCursorignore: true
        )

        let ignoredEvent = createFSEvent(
            path: "/test/repo/output.rootcursor",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )
        let ignoredDeltas = await service.simulateFSEvents([ignoredEvent])
        XCTAssertTrue(ignoredDeltas.isEmpty, "Root .cursorignore should filter matching files while respectCursorignore is enabled")

        try await service.updateRespectCursorignore(false)

        let visibleEvent = (
            absolutePath: "/test/repo/output.rootcursor",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
            eventId: FSEventStreamEventId(2)
        )
        let visibleDeltas = await service.simulateFSEvents([visibleEvent])
        XCTAssertTrue(visibleDeltas.contains { delta in
            if case .fileAdded("output.rootcursor") = delta { return true }
            return false
        }, "Root .cursorignore should stop applying when respectCursorignore is disabled")
    }

    func testRespectCursorignoreToggleControlsNestedCursorignore() async throws {
        let fs = SpyFS()

        fs.addFolder("/test/repo")
        fs.addFolder("/test/repo/src")
        fs.writeCursorignore(at: "/test/repo/src", "*.cursoronly")
        fs.addFile("/test/repo/src/output.cursoronly")

        let service = try await createTestService(
            fs: fs,
            enableHierarchicalIgnores: true,
            respectCursorignore: true
        )

        let ignoredEvent = createFSEvent(
            path: "/test/repo/src/output.cursoronly",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )
        let ignoredDeltas = await service.simulateFSEvents([ignoredEvent])
        XCTAssertTrue(ignoredDeltas.isEmpty, ".cursorignore should filter matching files while respectCursorignore is enabled")

        try await service.updateRespectCursorignore(false)

        let visibleEvent = (
            absolutePath: "/test/repo/src/output.cursoronly",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
            eventId: FSEventStreamEventId(2)
        )
        let visibleDeltas = await service.simulateFSEvents([visibleEvent])
        XCTAssertTrue(visibleDeltas.contains { delta in
            if case .fileAdded("src/output.cursoronly") = delta { return true }
            return false
        }, "Files matching .cursorignore should be visible after respectCursorignore is disabled")
    }

    func testDisablingHierarchicalIgnoresStopsNestedCursorignore() async throws {
        let fs = SpyFS()

        fs.addFolder("/test/repo")
        fs.addFolder("/test/repo/src")
        fs.writeCursorignore(at: "/test/repo/src", "*.nestedonly")
        fs.addFile("/test/repo/src/output.nestedonly")

        let service = try await createTestService(
            fs: fs,
            enableHierarchicalIgnores: true,
            respectCursorignore: true
        )

        let ignoredEvent = createFSEvent(
            path: "/test/repo/src/output.nestedonly",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )
        let ignoredDeltas = await service.simulateFSEvents([ignoredEvent])
        XCTAssertTrue(ignoredDeltas.isEmpty, "Nested .cursorignore should apply while hierarchical ignores are enabled")

        await service.updateEnableHierarchicalIgnores(false)

        let visibleEvent = (
            absolutePath: "/test/repo/src/output.nestedonly",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
            eventId: FSEventStreamEventId(2)
        )
        let visibleDeltas = await service.simulateFSEvents([visibleEvent])
        XCTAssertTrue(visibleDeltas.contains { delta in
            if case .fileAdded("src/output.nestedonly") = delta { return true }
            return false
        }, "Nested .cursorignore should stop applying when hierarchical ignores are disabled")
    }
    
    // MARK: - Error Handling Tests
    
    func testFileSystemErrorHandling() async throws {
        // Create a SpyFS that can simulate errors
        class ErrorSimulatingFS: SpyFS {
            var shouldThrowOnDirectory: String?
            
            override func contentsOfDirectory(
                at url: URL,
                includingPropertiesForKeys keys: [URLResourceKey]?,
                options mask: FileManager.DirectoryEnumerationOptions
            ) throws -> [URL] {
                if let errorPath = shouldThrowOnDirectory,
                   url.path == errorPath {
                    throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated error"])
                }
                return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
            }
        }
        
        let fs = ErrorSimulatingFS()
        
        // Create structure
        fs.addFolder("/test/repo/good")
        fs.addFolder("/test/repo/bad")
        fs.addFile("/test/repo/good/file1.txt")
        fs.addFile("/test/repo/bad/file2.txt")
        
        let service = try await createTestService(
            fs: fs,
            visitedPaths: ["good", "bad"],
            visitedItems: ["good": true, "bad": true]
        )
        
        // Make one directory throw an error
        fs.shouldThrowOnDirectory = "/test/repo/bad"
        
        // Send events for both directories
        let events = [
            createFSEvent(
                path: "/test/repo/good",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
            ),
            createFSEvent(
                path: "/test/repo/bad",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
            )
        ]
        
        let deltas = await service.simulateFSEvents(events)
        
        // Should still get deltas for the good directory
        XCTAssertTrue(deltas.contains { delta in
            if case .folderModified("good", let date) = delta { return date != nil }
            return false
        }, "Should process folders that don't error")
        
        // The bad directory should fail silently (error is printed but processing continues)
        XCTAssertTrue(deltas.contains { delta in
            if case .folderModified("bad", let date) = delta { return date != nil }
            return false
        }, "Should still emit modification for errored folder")
    }
    
    func testKnownDirectoryModificationCarriesFolderModificationDate() async throws {
        let tempParent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootURL = tempParent.appendingPathComponent("repo", isDirectory: true)
        let dataURL = rootURL.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempParent) }

        let expectedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: expectedDate], ofItemAtPath: dataURL.path)
        let service = try await FileSystemService(
            path: rootURL.path,
            respectGitignore: false,
            skipSymlinks: true,
            testVisitedPaths: ["data"],
            testVisitedItems: ["data": true],
            isTestMode: true
        )

        let deltas = await service.simulateFSEvents([
            (
                absolutePath: dataURL.path,
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsDir),
                eventId: 1
            )
        ])

        let carriedDates = deltas.compactMap { delta -> Date? in
            guard case .folderModified("data", let date) = delta else { return nil }
            return date
        }
        XCTAssertEqual(carriedDates.count, 1)
        XCTAssertEqual(try XCTUnwrap(carriedDates.first).timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 1.0)
    }

    func testRenameExistingDirectoryCarriesFolderModificationDate() async throws {
        let tempParent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootURL = tempParent.appendingPathComponent("repo", isDirectory: true)
        let dataURL = rootURL.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempParent) }

        let expectedDate = Date(timeIntervalSince1970: 1_700_000_123)
        try FileManager.default.setAttributes([.modificationDate: expectedDate], ofItemAtPath: dataURL.path)
        let service = try await FileSystemService(
            path: rootURL.path,
            respectGitignore: false,
            skipSymlinks: true,
            testVisitedPaths: ["data"],
            testVisitedItems: ["data": true],
            isTestMode: true
        )

        let deltas = await service.simulateFSEvents([
            (
                absolutePath: dataURL.path,
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir),
                eventId: 1
            )
        ])

        let carriedDates = deltas.compactMap { delta -> Date? in
            guard case .folderModified("data", let date) = delta else { return nil }
            return date
        }
        XCTAssertEqual(carriedDates.count, 1)
        XCTAssertEqual(try XCTUnwrap(carriedDates.first).timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 1.0)
    }
    
    // MARK: - Complex Rename Chain Tests
    
    func testRenameChainInSingleBatch() async throws {
        let fs = SpyFS()
        
        // Create files for chain: A -> B -> C
        fs.addFile("/test/repo/fileA.txt")
        fs.addFile("/test/repo/fileB.txt")
        fs.addFile("/test/repo/fileC.txt")
        
        let service = try await createTestService(
            fs: fs,
            visitedPaths: ["fileA.txt", "fileB.txt"],
            visitedItems: ["fileA.txt": false, "fileB.txt": false]
        )
        
        // Simulate the chain rename
        fs.remove("/test/repo/fileA.txt")
        fs.remove("/test/repo/fileB.txt")
        
        let events = [
            // A -> B
            createFSEvent(
                path: "/test/repo/fileA.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved)
            ),
            createFSEvent(
                path: "/test/repo/fileB.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCreated)
            ),
            // B -> C
            createFSEvent(
                path: "/test/repo/fileB.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved)
            ),
            createFSEvent(
                path: "/test/repo/fileC.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCreated)
            )
        ]
        
        let deltas = await service.simulateFSEvents(events)
        
        // Should detect fileA removed and fileC added
        XCTAssertTrue(deltas.contains { delta in
            if case .fileRemoved("fileA.txt") = delta { return true }
            return false
        }, "Original file should be removed")
        
        XCTAssertTrue(deltas.contains { delta in
            if case .fileAdded("fileC.txt") = delta { return true }
            return false
        }, "Final file should be added")
    }
    
    // MARK: - Non-content Modification Flags
    
    func testNonContentModificationFlags() async throws {
        let fs = SpyFS()
        
        fs.addFile("/test/repo/file.txt")
        
        // Test various non-content modification flags
        let flagsToTest: [FSEventStreamEventFlags] = [
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemInodeMetaMod),
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemFinderInfoMod),
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemChangeOwner),
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemXattrMod)
        ]
        
        // Test each flag individually to ensure they all work
        for flags in flagsToTest {
            // Reset visitedPaths state for each test
            let service = try await createTestService(
                fs: fs,
                visitedPaths: ["file.txt"],
                visitedItems: ["file.txt": false]
            )
            
            let event = createFSEvent(
                path: "/test/repo/file.txt",
                flags: flags
            )
            
            let deltas = await service.simulateFSEvents([event])
            
            XCTAssertTrue(deltas.contains { delta in
                if case .fileModified(let path, _) = delta, path == "file.txt" { return true }
                return false
            }, "Flag \(flags) should trigger modification")
        }
    }
}
