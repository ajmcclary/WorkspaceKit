import XCTest
@testable import WorkspaceFileSystem
@testable import WorkspaceIgnore

final class FileSystemServiceNestedIgnoreTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    private func createTestService(
        fs: SpyFS,
        visitedPaths: Set<String> = [],
        visitedItems: [String: Bool] = [:],
        enableHierarchicalIgnores: Bool = true,
        respectGitignore: Bool = true
    ) async throws -> FileSystemService {
        let testPath = "/tmp/test"
        
        // Ensure root directory exists
        fs.addFolder("/tmp")
        fs.addFolder("/tmp/test")
        
        let service = try await FileSystemService(
            path: testPath,
            respectGitignore: respectGitignore,
            skipSymlinks: true,
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
        flags: FSEventStreamEventFlags,
        eventId: FSEventStreamEventId = 1
    ) -> (absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId) {
        return (absolutePath: path, flags: flags, eventId: eventId)
    }
    
    // MARK: - Nested .gitignore Tests with Delta Events
    
    func testNestedGitignoreRespectedForNewFiles() async throws {
        // Setup: Simulate the bombsquad test scenario
        // Root .gitignore ignores *.log
        // nested_ignore_test/child_test/.gitignore ignores *.cache, *.bak, temp_*, debug_logs/
        
        let fs = SpyFS()
        
        // Create directory structure
        fs.addFolder("/tmp/test")
        fs.addFolder("/tmp/test/nested_ignore_test")
        fs.addFolder("/tmp/test/nested_ignore_test/child_test")
        fs.addFolder("/tmp/test/nested_ignore_test/child_test/debug_logs")
        
        // Root .gitignore
        fs.writeGitignore(at: "/tmp/test", """
            *.log
            """)
        
        // Nested .gitignore with additional patterns
        fs.writeGitignore(at: "/tmp/test/nested_ignore_test/child_test", """
            *.cache
            *.bak
            temp_*
            debug_logs/
            """)
        
        // Create test files that should be ignored by nested .gitignore
        fs.addFile("/tmp/test/nested_ignore_test/child_test/should_be_ignored.cache")
        fs.addFile("/tmp/test/nested_ignore_test/child_test/temp_working_file.txt")
        fs.addFile("/tmp/test/nested_ignore_test/child_test/backup_file.bak")
        fs.addFile("/tmp/test/nested_ignore_test/child_test/debug_logs/debug.log")
        
        // Create test files that should NOT be ignored
        fs.addFile("/tmp/test/nested_ignore_test/child_test/regular_file.txt")
        fs.addFile("/tmp/test/nested_ignore_test/child_test/important.data")
        
        let service = try await createTestService(fs: fs, enableHierarchicalIgnores: true)
        
        // Simulate FSEvents for all the new files
        let events = [
            createFSEvent(path: "/tmp/test/nested_ignore_test/child_test/should_be_ignored.cache", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/nested_ignore_test/child_test/temp_working_file.txt", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/nested_ignore_test/child_test/backup_file.bak", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/nested_ignore_test/child_test/debug_logs/debug.log", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/nested_ignore_test/child_test/regular_file.txt", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/nested_ignore_test/child_test/important.data", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile))
        ]
        
        let deltas = await service.simulateFSEvents(events)
        
        // Files that match nested .gitignore patterns should be filtered out
        let addedPaths = deltas.compactMap { delta -> String? in
            switch delta {
            case .fileAdded(let path):
                return path
            default:
                return nil
            }
        }
        
        // Only non-ignored files should be added
        XCTAssertTrue(addedPaths.contains("nested_ignore_test/child_test/regular_file.txt"), 
                     "Regular file should be added")
        XCTAssertTrue(addedPaths.contains("nested_ignore_test/child_test/important.data"), 
                     "Important data file should be added")
        
        // These files should be filtered by nested .gitignore
        XCTAssertFalse(addedPaths.contains("nested_ignore_test/child_test/should_be_ignored.cache"), 
                      "*.cache files should be ignored by nested .gitignore")
        XCTAssertFalse(addedPaths.contains("nested_ignore_test/child_test/temp_working_file.txt"), 
                      "temp_* files should be ignored by nested .gitignore")
        XCTAssertFalse(addedPaths.contains("nested_ignore_test/child_test/backup_file.bak"), 
                      "*.bak files should be ignored by nested .gitignore")
        XCTAssertFalse(addedPaths.contains("nested_ignore_test/child_test/debug_logs/debug.log"), 
                      "Files in debug_logs/ should be ignored by nested .gitignore")
    }
    
    func testNestedGitignoreInIgnoredDirectory() async throws {
        // Test that .gitignore files in already-ignored directories are themselves ignored
        // This matches Git's behavior
        
        let fs = SpyFS()
        
        // Create directory structure
        fs.addFolder("/tmp/test")
        fs.addFolder("/tmp/test/ignored_dir")
        fs.addFolder("/tmp/test/ignored_dir/subdir")
        
        // Root .gitignore ignores the entire directory
        fs.writeGitignore(at: "/tmp/test", """
            ignored_dir/
            """)
        
        // This nested .gitignore should NOT be processed because it's in an ignored directory
        fs.writeGitignore(at: "/tmp/test/ignored_dir/subdir", """
            !important.txt
            """)
        
        // Add files
        fs.addFile("/tmp/test/ignored_dir/subdir/important.txt")
        fs.addFile("/tmp/test/ignored_dir/subdir/.gitignore")
        
        let service = try await createTestService(fs: fs, enableHierarchicalIgnores: true)
        
        // Simulate FSEvents
        let events = [
            createFSEvent(path: "/tmp/test/ignored_dir/subdir/.gitignore", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/ignored_dir/subdir/important.txt", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile))
        ]
        
        let deltas = await service.simulateFSEvents(events)
        
        // Both files should be filtered because the parent directory is ignored
        XCTAssertTrue(deltas.isEmpty, 
                     "Files in ignored directories should not be processed, even with nested .gitignore")
    }
    
    func testMultiLevelNestedGitignores() async throws {
        // Test multiple levels of nested .gitignore files
        
        let fs = SpyFS()
        
        // Create directory structure
        fs.addFolder("/tmp/test")
        fs.addFolder("/tmp/test/src")
        fs.addFolder("/tmp/test/src/components")
        fs.addFolder("/tmp/test/src/components/ui")
        
        // Root .gitignore
        fs.writeGitignore(at: "/tmp/test", """
            *.log
            node_modules/
            """)
        
        // src/.gitignore adds more patterns
        fs.writeGitignore(at: "/tmp/test/src", """
            *.tmp
            *.cache
            """)
        
        // src/components/.gitignore adds even more
        fs.writeGitignore(at: "/tmp/test/src/components", """
            *.test.js
            __snapshots__/
            """)
        
        // Create test files at different levels
        fs.addFile("/tmp/test/debug.log")  // Ignored by root
        fs.addFile("/tmp/test/app.js")     // Not ignored
        
        fs.addFile("/tmp/test/src/temp.tmp")     // Ignored by src/.gitignore
        fs.addFile("/tmp/test/src/data.cache")   // Ignored by src/.gitignore
        fs.addFile("/tmp/test/src/main.js")      // Not ignored
        
        fs.addFile("/tmp/test/src/components/Button.test.js")  // Ignored by components/.gitignore
        fs.addFile("/tmp/test/src/components/Button.js")       // Not ignored
        
        let service = try await createTestService(fs: fs, enableHierarchicalIgnores: true)
        
        // Simulate FSEvents for all files
        let events = [
            createFSEvent(path: "/tmp/test/debug.log", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/app.js", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/src/temp.tmp", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/src/data.cache", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/src/main.js", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/src/components/Button.test.js", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/src/components/Button.js", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile))
        ]
        
        let deltas = await service.simulateFSEvents(events)
        let addedPaths = deltas.compactMap { delta -> String? in
            switch delta {
            case .fileAdded(let path):
                return path
            default:
                return nil
            }
        }
        
        // Verify correct files are added
        XCTAssertTrue(addedPaths.contains("app.js"), "Root level JS file should be added")
        XCTAssertTrue(addedPaths.contains("src/main.js"), "src level JS file should be added")
        XCTAssertTrue(addedPaths.contains("src/components/Button.js"), "Component file should be added")
        
        // Verify ignored files are filtered
        XCTAssertFalse(addedPaths.contains("debug.log"), "*.log should be ignored by root .gitignore")
        XCTAssertFalse(addedPaths.contains("src/temp.tmp"), "*.tmp should be ignored by src/.gitignore")
        XCTAssertFalse(addedPaths.contains("src/data.cache"), "*.cache should be ignored by src/.gitignore")
        XCTAssertFalse(addedPaths.contains("src/components/Button.test.js"), "*.test.js should be ignored by components/.gitignore")
    }
    
    func testTrackedFileRemainsTrackedDespiteNestedIgnore() async throws {
        // Test that already-tracked files continue to be tracked even if a nested .gitignore would ignore them
        
        let fs = SpyFS()
        
        // Create directory structure
        fs.addFolder("/tmp/test")
        fs.addFolder("/tmp/test/src")
        
        // Create a file that will be tracked
        fs.addFile("/tmp/test/src/data.cache")
        
        // Start with the file already tracked
        let service = try await createTestService(
            fs: fs,
            visitedPaths: ["src/data.cache"],
            visitedItems: ["src/data.cache": false],
            enableHierarchicalIgnores: true
        )
        
        // Now add a nested .gitignore that would ignore this file
        fs.writeGitignore(at: "/tmp/test/src", """
            *.cache
            """)
        
        // Simulate modification of the tracked file
        let events = [
            createFSEvent(path: "/tmp/test/src/data.cache", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile))
        ]
        
        let deltas = await service.simulateFSEvents(events)
        
        // The file should still be tracked and the modification should be processed
        XCTAssertEqual(deltas.count, 1)
        if case .fileModified(let path, _) = deltas[0] {
            XCTAssertEqual(path, "src/data.cache", "Tracked file should remain tracked despite nested ignore")
        } else {
            XCTFail("Expected file modification delta")
        }
    }
    
    func testNestedGitignoreWithDirectoryPatterns() async throws {
        // Test directory-specific patterns in nested .gitignore files
        
        let fs = SpyFS()
        
        // Create directory structure
        fs.addFolder("/tmp/test")
        fs.addFolder("/tmp/test/project")
        fs.addFolder("/tmp/test/project/build")
        fs.addFolder("/tmp/test/project/dist")
        fs.addFolder("/tmp/test/project/src")
        fs.addFolder("/tmp/test/project/src/build")  // Different build directory
        
        // Root .gitignore
        fs.writeGitignore(at: "/tmp/test", """
            # Nothing at root
            """)
        
        // Project-level .gitignore ignores top-level build/ and dist/
        fs.writeGitignore(at: "/tmp/test/project", """
            /build/
            /dist/
            """)
        
        // Create files
        fs.addFile("/tmp/test/project/build/output.js")      // Should be ignored
        fs.addFile("/tmp/test/project/dist/bundle.js")       // Should be ignored
        fs.addFile("/tmp/test/project/src/build/config.js")  // Should NOT be ignored (different build dir)
        
        let service = try await createTestService(fs: fs, enableHierarchicalIgnores: true)
        
        // Simulate FSEvents
        let events = [
            createFSEvent(path: "/tmp/test/project/build/output.js", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/project/dist/bundle.js", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/project/src/build/config.js", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile))
        ]
        
        let deltas = await service.simulateFSEvents(events)
        let addedPaths = deltas.compactMap { delta -> String? in
            switch delta {
            case .fileAdded(let path):
                return path
            default:
                return nil
            }
        }
        
        // Only the nested build directory file should be added
        XCTAssertEqual(addedPaths.count, 1)
        XCTAssertTrue(addedPaths.contains("project/src/build/config.js"), 
                     "File in nested build/ directory should not be ignored by parent's /build/ pattern")
    }

    func testNestedSlashPatternScopedToIgnoreFileDirectory() async throws {
        let fs = SpyFS()

        fs.addFolder("/tmp/test/project/cache")
        fs.addFolder("/tmp/test/project/src/cache")
        fs.addFolder("/tmp/test/other/project/cache")
        fs.writeGitignore(at: "/tmp/test/project", """
        cache/*.dat
        !cache/keep.dat
        """)

        fs.addFile("/tmp/test/project/cache/drop.dat")
        fs.addFile("/tmp/test/project/cache/keep.dat")
        fs.addFile("/tmp/test/project/src/cache/drop.dat")
        fs.addFile("/tmp/test/other/project/cache/drop.dat")

        let service = try await createTestService(fs: fs, enableHierarchicalIgnores: true)
        let events = [
            createFSEvent(path: "/tmp/test/project/cache/drop.dat",
                        flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/project/cache/keep.dat",
                        flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/project/src/cache/drop.dat",
                        flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/other/project/cache/drop.dat",
                        flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile))
        ]

        let deltas = await service.simulateFSEvents(events)
        let addedPaths = deltas.compactMap { delta -> String? in
            if case .fileAdded(let path) = delta { return path }
            return nil
        }

        XCTAssertFalse(addedPaths.contains("project/cache/drop.dat"))
        XCTAssertTrue(addedPaths.contains("project/cache/keep.dat"))
        XCTAssertTrue(addedPaths.contains("project/src/cache/drop.dat"))
        XCTAssertTrue(addedPaths.contains("other/project/cache/drop.dat"))
    }
    
    func testDisabledHierarchicalIgnoresOnlyUsesRoot() async throws {
        // Test that when hierarchical ignores are disabled, only root .gitignore is used
        // Note: Global defaults always apply and include **/*.tmp and **/*.bak
        
        let fs = SpyFS()
        
        // Create directory structure
        fs.addFolder("/tmp/test")
        fs.addFolder("/tmp/test/src")
        
        // Root .gitignore
        fs.writeGitignore(at: "/tmp/test", """
            *.log
            """)
        
        // Nested .gitignore that would normally apply
        fs.writeGitignore(at: "/tmp/test/src", """
            *.cache
            *.xyz
            """)
        
        // Create files
        fs.addFile("/tmp/test/src/debug.log")    // Ignored by root
        fs.addFile("/tmp/test/src/data.cache")   // Would be ignored by nested, but hierarchical disabled
        fs.addFile("/tmp/test/src/test.xyz")     // Would be ignored by nested, but hierarchical disabled
        fs.addFile("/tmp/test/src/temp.tmp")     // Ignored by global defaults (always applied)
        
        let service = try await createTestService(
            fs: fs,
            enableHierarchicalIgnores: false  // Disable hierarchical ignores
        )
        
        // Simulate FSEvents
        let events = [
            createFSEvent(path: "/tmp/test/src/debug.log", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/src/data.cache", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/src/test.xyz", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            createFSEvent(path: "/tmp/test/src/temp.tmp", 
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile))
        ]
        
        let deltas = await service.simulateFSEvents(events)
        let addedPaths = deltas.compactMap { delta -> String? in
            switch delta {
            case .fileAdded(let path):
                return path
            default:
                return nil
            }
        }
        
        // Root .gitignore patterns apply
        XCTAssertFalse(addedPaths.contains("src/debug.log"), "*.log should be ignored by root .gitignore")
        
        // Nested .gitignore patterns should NOT apply when hierarchical disabled
        XCTAssertTrue(addedPaths.contains("src/data.cache"), "*.cache should NOT be ignored when hierarchical disabled")
        XCTAssertTrue(addedPaths.contains("src/test.xyz"), "*.xyz should NOT be ignored when hierarchical disabled")
        
        // Global defaults always apply
        XCTAssertFalse(addedPaths.contains("src/temp.tmp"), "*.tmp should be ignored by global defaults")
    }
}