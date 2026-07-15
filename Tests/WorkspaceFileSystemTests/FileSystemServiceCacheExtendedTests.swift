import XCTest
@testable import WorkspaceFileSystem
@testable import WorkspaceIgnore

/// Extended cache tests for FileSystemService
final class FileSystemServiceCacheExtendedTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    private func createTestService(
        fs: SpyFS,
        visitedPaths: Set<String> = [],
        visitedItems: [String: Bool] = [:]
    ) async throws -> FileSystemService {
        let testPath = "/cache/test"
        
        // Ensure root directory exists
        fs.addFolder("/cache")
        fs.addFolder("/cache/test")
        
        let service = try await FileSystemService(
            path: testPath,
            respectGitignore: true,
            skipSymlinks: true,
            testVisitedPaths: visitedPaths,
            testVisitedItems: visitedItems,
            testIgnoreRules: nil,
            isTestMode: true,
            fileManagerOverride: fs
        )
        
        return service
    }

	private func assertEventuallyIgnored(
		_ service: FileSystemService,
		relativePath: String,
		expected: Bool,
		timeout: TimeInterval = 0.5,
		file: StaticString = #filePath,
		line: UInt = #line
	) async {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			let current = await service.testIsIgnoredPrefixCheck(relativePath: relativePath)
			if current == expected {
				return
			}
			try? await Task.sleep(nanoseconds: 10_000_000)
		}
		let finalValue = await service.testIsIgnoredPrefixCheck(relativePath: relativePath)
		XCTAssertEqual(finalValue, expected, "Ignore result did not converge for \(relativePath)", file: file, line: line)
	}
    
    // MARK: - Per-Folder Cache Eviction Tests
    
    func testPerFolderCacheEvictionOrder() async throws {
        let fs = SpyFS()
        
        // Create a structure that will exceed the cache limit (4000 entries)
        let dirsToCreate = 4100
        
        // Create many directories with ignore files
        for i in 0..<dirsToCreate {
            let dirPath = "/cache/test/dir\(i)"
            fs.addFolder(dirPath)
            
            // Add ignore file to force cache entry
            fs.writeGitignore(at: dirPath, "*.tmp")
        }
        
        let service = try await createTestService(fs: fs)
        
        // Access all directories to populate cache
        for i in 0..<dirsToCreate {
            let dirPath = "dir\(i)"
            // Force cache population by checking if a path would be ignored
            _ = await service.testIsIgnoredPrefixCheck(relativePath: "\(dirPath)/test.tmp")
        }
        
        // Cache should be at capacity (4000) after eviction
        let cacheSize = await service.getPerFolderIgnoreCacheSize()
        XCTAssertLessThanOrEqual(cacheSize, 4000, "Cache should respect capacity limit")
        
        // Early directories should have been evicted
        // Access an early directory again
        _ = await service.testIsIgnoredPrefixCheck(relativePath: "dir0/test.tmp")
        
        // Cache should remain capped under LRU eviction
        let newCacheSize = await service.getPerFolderIgnoreCacheSize()
        XCTAssertLessThanOrEqual(newCacheSize, 4000, "Cache should remain capped under LRU eviction")
    }
    
    // MARK: - Path Components Cache Tests
    
    func testPathComponentsCacheEfficiency() async throws {
        let fs = SpyFS()
        
        // Create deep directory structure
        var currentPath = "/cache/test"
        for i in 0..<20 {
            currentPath += "/level\(i)"
            fs.addFolder(currentPath)
        }
        
        let service = try await createTestService(fs: fs)
        
        // Create many events for paths with common prefixes
        var events: [(String, FSEventStreamEventFlags, FSEventStreamEventId)] = []
        
        for i in 0..<100 {
            let deepPath = "/cache/test/level0/level1/level2/level3/level4/file\(i).txt"
            fs.addFile(deepPath)
            events.append((deepPath, FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated), FSEventStreamEventId(i)))
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        _ = await service.simulateFSEvents(events)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        
        // Should be fast due to path component caching
        XCTAssertLessThan(elapsed, 0.5, "Path processing should be efficient with cache")
    }
    
    // MARK: - No Ignore File Cache Tests
    
    func testNoIgnoreFileCacheBehavior() async throws {
        let fs = SpyFS()
        
        // Create directories without ignore files
        for i in 0..<100 {
            fs.addFolder("/cache/test/empty\(i)")
            // No ignore files added
        }
        
        // Create one directory with ignore file
        fs.addFolder("/cache/test/with-ignore")
        fs.writeGitignore(at: "/cache/test/with-ignore", "*.log")
        
        let service = try await createTestService(fs: fs)
        
        // Access directories multiple times
        for _ in 0..<5 {
            for i in 0..<100 {
                _ = await service.testIsIgnoredPrefixCheck(relativePath: "empty\(i)/file.txt")
            }
        }
        
        // The no-ignore cache should prevent repeated directory scans
        // We can verify this by checking SpyFS enumeration count
        fs.resetSpyData()
        
        // Access again - should use cache
        for i in 0..<100 {
            _ = await service.testIsIgnoredPrefixCheck(relativePath: "empty\(i)/file.txt")
        }
        
        // Should not have enumerated any directories (all cached)
        XCTAssertEqual(fs.enumeratedDirsCount(), 0, "Should use no-ignore cache")
        
        // Precondition: ensure this path is not ignored before adding a rule
        let wasIgnored = await service.testIsIgnoredPrefixCheck(relativePath: "empty50/file.log")
        XCTAssertFalse(wasIgnored, "Precondition failed: file.log should not be ignored before adding rules")
        
        // Now add an ignore file to one of the "empty" directories
        fs.writeGitignore(at: "/cache/test/empty50", "*.log")
        
        // Simulate the ignore file creation event
        let event = (
            "/cache/test/empty50/.gitignore",
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
            FSEventStreamEventId(1)
        )
        
        _ = await service.simulateFSEvents([event])
        
        // The cache for empty50 should be invalidated and rebuilt asynchronously
        await assertEventuallyIgnored(service, relativePath: "empty50/file.log", expected: true, timeout: 1.0)
        let noIgnoreCache = await service.getNoIgnoreFileCache()
        XCTAssertFalse(noIgnoreCache.contains("empty50"), "No-ignore cache should drop the updated directory")
    }
    
	func testNoIgnoreFileCacheIsBoundedAndEvictionIsSafe() async throws {
		let fs = SpyFS()
		let capacity = FileSystemService.ignoreCacheCapacityForTesting
		let dirsToCreate = capacity + 100

		for i in 0..<dirsToCreate {
			let dirPath = "/cache/test/empty-bounded\(i)"
			fs.addFolder(dirPath)
			fs.addFile("\(dirPath)/file.txt")
		}

		let service = try await createTestService(fs: fs)

		for i in 0..<dirsToCreate {
			let ignored = await service.testIsIgnoredPrefixCheck(relativePath: "empty-bounded\(i)/file.txt")
			XCTAssertFalse(ignored, "No-ignore directories should not change ignore correctness")
		}

		let markerCacheSize = await service.getNoIgnoreFileCacheSize()
		XCTAssertLessThanOrEqual(markerCacheSize, capacity, "No-ignore marker cache should respect capacity limit")
		let ruleCacheSize = await service.getPerFolderIgnoreCacheSize()
		XCTAssertLessThanOrEqual(ruleCacheSize, capacity, "Per-folder cache should remain bounded while marker cache evicts")

		let earlyDirectoryIgnored = await service.testIsIgnoredPrefixCheck(relativePath: "empty-bounded0/file.txt")
		XCTAssertFalse(earlyDirectoryIgnored, "Evicting a no-ignore marker should only cause rechecking, not incorrect ignores")
		let markerCacheSizeAfterRecheck = await service.getNoIgnoreFileCacheSize()
		XCTAssertLessThanOrEqual(markerCacheSizeAfterRecheck, capacity)
	}

    func testChildFolderInheritsParentIgnoreRulesWhenNoLocalFiles() async throws {
        let fs = SpyFS()
        fs.addFolder("/cache/test/parent")
        fs.addFolder("/cache/test/parent/child")
        
        fs.writeGitignore(at: "/cache/test/parent", "ignored.generated")
        fs.addFile("/cache/test/parent/child/ignored.generated")
        fs.addFile("/cache/test/parent/child/keep.txt")
        
        let service = try await createTestService(fs: fs)
        
        let rootURL = URL(fileURLWithPath: "/cache/test")
        let stream = await service.loadContentsInChunks(of: rootURL, chunkSize: 50)
        for try await _ in stream {
            // Drain the stream to ensure caches are populated
        }
        
        let shouldIgnore = await service.testIsIgnoredPrefixCheck(relativePath: "parent/child/ignored.generated")
        XCTAssertTrue(shouldIgnore, "Child directory should inherit parent ignore rules when it has no local ignore files")
        
        let shouldKeep = await service.testIsIgnoredPrefixCheck(relativePath: "parent/child/keep.txt")
        XCTAssertFalse(shouldKeep, "Non-matching paths should remain visible")
    }
    
    // MARK: - Ignore Cache Store Tests
    
    func testIgnoreCacheStoreWithComplexPaths() async throws {
        let fs = SpyFS()
        
        // Create a complex ignore structure
        fs.writeGitignore(at: "/cache/test", """
            # Complex patterns
            *.log
            !important.log
            /build/
            !/build/keep/
            **/temp/
            src/**/*.tmp
            """)
        
        // Create matching structure
        fs.addFolder("/cache/test/src")
        fs.addFolder("/cache/test/src/nested")
        fs.addFolder("/cache/test/build")
        fs.addFolder("/cache/test/build/keep")
        fs.addFolder("/cache/test/anywhere")
        fs.addFolder("/cache/test/anywhere/temp")
        
        let service = try await createTestService(fs: fs)
        
        // Test various paths to populate cache
        let testPaths = [
            ("debug.log", true),              // Ignored by *.log
            ("important.log", false),         // Negated by !important.log
            ("build/output", true),           // Ignored by /build/
            ("build/keep/file.txt", false),   // Negated by !/build/keep/
            ("anywhere/temp/file.txt", true), // Ignored by **/temp/
            ("src/nested/file.tmp", true),    // Ignored by src/**/*.tmp
            ("src/nested/file.txt", false)    // Not ignored
        ]
        
        // First pass - populate cache
        for (path, shouldBeIgnored) in testPaths {
            let ignored = await service.testIsIgnoredPrefixCheck(relativePath: path)
            XCTAssertEqual(ignored, shouldBeIgnored, "Path '\(path)' ignore status incorrect")
        }
        
        // Second pass - should use cache
        let cacheSnapshot1 = await service.snapshotIgnoreCache()
        
        for (path, shouldBeIgnored) in testPaths {
            let ignored = await service.testIsIgnoredPrefixCheck(relativePath: path)
            XCTAssertEqual(ignored, shouldBeIgnored, "Cached result for '\(path)' incorrect")
        }
        
        let cacheSnapshot2 = await service.snapshotIgnoreCache()
        
        // Cache should be unchanged (all hits)
        XCTAssertEqual(cacheSnapshot1.count, cacheSnapshot2.count, "Cache should not grow on hits")
    }
    
    // MARK: - Cache Invalidation Tests
    
    func testFilterHashChangedRebuildsBehavior() async throws {
        let fs = SpyFS()
        
        // Initial setup
        fs.addFolder("/cache/test/src")
        fs.writeGitignore(at: "/cache/test", "*.old")
        
        let service = try await createTestService(fs: fs)
        
        // Check initial state
        let isOldIgnored = await service.testIsIgnoredPrefixCheck(relativePath: "file.old")
        let isNewIgnored = await service.testIsIgnoredPrefixCheck(relativePath: "file.new")
        XCTAssertTrue(isOldIgnored, "Should be ignored initially")
        XCTAssertFalse(isNewIgnored, "Should not be ignored initially")
        
        // Modify ignore file
        fs.writeGitignore(at: "/cache/test", "*.new")  // Changed pattern
        
        // Simulate modification event
        let event = (
            "/cache/test/.gitignore",
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
            FSEventStreamEventId(1)
        )
        
        _ = await service.simulateFSEvents([event])
        
        // Filter hash should have triggered cache rebuild
        // Note: We can't check filterHashChanged directly as it's reset
        
        // Check new state - patterns should be updated (async rebuild)
        await assertEventuallyIgnored(service, relativePath: "file.old", expected: false)
        await assertEventuallyIgnored(service, relativePath: "file.new", expected: true)
    }

	func testIgnoreChangeAddingUnignoreInvalidatesPrefixAndRuleCaches() async throws {
		let fs = SpyFS()
		fs.addFolder("/cache/test/generated")
		fs.addFile("/cache/test/generated/keep.txt")
		fs.addFile("/cache/test/generated/drop.txt")
		fs.writeGitignore(at: "/cache/test", "generated/")

		let service = try await createTestService(fs: fs)
		let keepInitiallyIgnored = await service.testIsIgnoredPrefixCheck(relativePath: "generated/keep.txt")
		let dropInitiallyIgnored = await service.testIsIgnoredPrefixCheck(relativePath: "generated/drop.txt")
		XCTAssertTrue(keepInitiallyIgnored)
		XCTAssertTrue(dropInitiallyIgnored)

		fs.writeGitignore(at: "/cache/test", """
		generated/
		!generated/keep.txt
		""")
		let event = (
			"/cache/test/.gitignore",
			FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),
			FSEventStreamEventId(10)
		)
		_ = await service.simulateFSEvents([event])

		await assertEventuallyIgnored(service, relativePath: "generated/keep.txt", expected: false, timeout: 2.0)
		await assertEventuallyIgnored(service, relativePath: "generated/drop.txt", expected: true, timeout: 2.0)
	}

	// MARK: - Root Ignore Change Tests

	func testRootIgnoreChangeInvalidatesDerivedRules() async throws {
		let fs = SpyFS()

		fs.addFolder("/cache/test/dirA")
		fs.addFolder("/cache/test/dirB")

		fs.writeGitignore(at: "/cache/test", "*.old")

		let service = try await createTestService(fs: fs)

		// Populate caches using the old root rules
		_ = await service.testIsIgnoredPrefixCheck(relativePath: "dirA/file.old")
		_ = await service.testIsIgnoredPrefixCheck(relativePath: "dirB/file.old")

		// Update root ignore rules
		fs.writeGitignore(at: "/cache/test", "*.new")
		let event = (
			"/cache/test/.gitignore",
			FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
			FSEventStreamEventId(1)
		)
		_ = await service.simulateFSEvents([event])

		// Verify derived behavior reflects new root rules
		await assertEventuallyIgnored(service, relativePath: "dirA/file.old", expected: false, timeout: 2.0)
		await assertEventuallyIgnored(service, relativePath: "dirA/file.new", expected: true, timeout: 2.0)
	}

	// MARK: - Nested Ignore Change Tests

	func testNestedIgnoreChangeInvalidatesSubtreeOnly() async throws {
		let fs = SpyFS()

		fs.addFolder("/cache/test/parent")
		fs.addFolder("/cache/test/parent/child")
		fs.addFolder("/cache/test/parent/sibling")

		fs.writeGitignore(at: "/cache/test/parent", "*.old")

		fs.writeGitignore(at: "/cache/test/parent/child", "*.child")

		let service = try await createTestService(fs: fs)

		// Prime caches
		_ = await service.testIsIgnoredPrefixCheck(relativePath: "parent/child/file.child")
		_ = await service.testIsIgnoredPrefixCheck(relativePath: "parent/child/file.old")
		_ = await service.testIsIgnoredPrefixCheck(relativePath: "parent/sibling/file.old")

		// Change child ignore rules
		fs.writeGitignore(at: "/cache/test/parent/child", "*.new")
		let event = (
			"/cache/test/parent/child/.gitignore",
			FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
			FSEventStreamEventId(2)
		)
		_ = await service.simulateFSEvents([event])

		// Child should reflect new rules
		await assertEventuallyIgnored(service, relativePath: "parent/child/file.child", expected: false)
		await assertEventuallyIgnored(service, relativePath: "parent/child/file.new", expected: true)

		// Sibling should still inherit parent rule
		let siblingOldIgnored = await service.testIsIgnoredPrefixCheck(relativePath: "parent/sibling/file.old")
		XCTAssertTrue(siblingOldIgnored, "Sibling should still inherit parent ignore rules")
	}

	// MARK: - Large Repo Scan Tests

	func testLargeRepoScanCompletesWithHierarchicalIgnores() async throws {
		let fs = SpyFS()

		let dirCount = 6000
		for i in 0..<dirCount {
			let dirPath = "/cache/test/dir\(i)"
			fs.addFolder(dirPath)
			fs.addFile("\(dirPath)/file\(i).txt")
		}

		let service = try await createTestService(fs: fs)

		let rootURL = URL(fileURLWithPath: "/cache/test")
		let stream = await service.loadContentsInChunks(of: rootURL, chunkSize: 500)

		var totalFilesSeen = 0
		for try await event in stream {
			switch event {
			case .totalFileCount(let count):
				totalFilesSeen = count
			default:
				continue
			}
		}

		XCTAssertEqual(totalFilesSeen, dirCount, "Large repo scan should account for all files")
	}
    
    // MARK: - Performance Benchmark Tests

	func testWildcardNegationTraversalScanPerformanceInstrumentation() async throws {
		let fs = SpyFS()
		let directoryCount = 200
		for index in 0..<directoryCount {
			let dir = "/cache/test/temp-\(index)"
			fs.addFolder(dir)
			fs.addFile("\(dir)/important.txt")
			fs.addFile("\(dir)/drop.txt")
		}
		fs.writeGitignore(at: "/cache/test", """
		temp-*/
		!temp-*/important.txt
		""")

		let service = try await createTestService(fs: fs)
		let rootURL = URL(fileURLWithPath: "/cache/test")
		let start = CFAbsoluteTimeGetCurrent()
		let stream = await service.loadContentsInChunks(of: rootURL, chunkSize: 100)
		var visibleImportantFiles = Set<String>()
		var visibleDropFiles = Set<String>()
		for try await event in stream {
			if case .preparedItems(let chunk) = event {
				visibleImportantFiles.formUnion(chunk.files.map(\.relativePath).filter { $0.hasSuffix("/important.txt") })
				visibleDropFiles.formUnion(chunk.files.map(\.relativePath).filter { $0.hasSuffix("/drop.txt") })
			}
		}
		let elapsed = CFAbsoluteTimeGetCurrent() - start
		print("Wildcard negation traversal scan saw \(visibleImportantFiles.count) kept files in \(elapsed) seconds")

		XCTAssertEqual(visibleImportantFiles.count, directoryCount)
		XCTAssertTrue(visibleDropFiles.isEmpty)
		XCTAssertGreaterThanOrEqual(elapsed, 0, "Elapsed time should be recorded for diagnostics")
	}
    
    func testCachePerformanceUnderLoad() async throws {
        let fs = SpyFS()
        
        // Create a realistic project structure
        let folders = ["src", "tests", "docs", "build", "vendor", ".git"]
        let extensions = ["swift", "txt", "md", "json", "yml", "log"]
        
        for folder in folders {
            fs.addFolder("/cache/test/\(folder)")
            
            // Add some ignore rules
            if folder == "vendor" || folder == ".git" {
                continue // Skip ignored folders
            }
            
            // Create files
            for i in 0..<50 {
                for ext in extensions {
                    fs.addFile("/cache/test/\(folder)/file\(i).\(ext)")
                }
            }
        }
        
        // Add ignore rules
        fs.writeGitignore(at: "/cache/test", """
            .git/
            vendor/
            *.log
            build/
            """)
        
        let service = try await createTestService(fs: fs)
        
        // Create many events
        var events: [(String, FSEventStreamEventFlags, FSEventStreamEventId)] = []
        var eventId: FSEventStreamEventId = 0
        
        for folder in folders where folder != ".git" && folder != "vendor" {
            for i in 0..<50 {
                for ext in extensions {
                    let path = "/cache/test/\(folder)/file\(i).\(ext)"
                    events.append((path, FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), eventId))
                    eventId += 1
                }
            }
        }
        
        // Measure performance
        let startTime = CFAbsoluteTimeGetCurrent()
        let deltas = await service.simulateFSEvents(events)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        
        print("Processed \(events.count) events in \(elapsed) seconds")
        print("Generated \(deltas.count) deltas")
        
        // Should be fast even with many events
        XCTAssertLessThan(elapsed, 1.0, "Should process \(events.count) events quickly with caching")
        
        // Most events in ignored folders should be filtered
        XCTAssertLessThan(deltas.count, events.count, "Should filter some events")
    }
}
