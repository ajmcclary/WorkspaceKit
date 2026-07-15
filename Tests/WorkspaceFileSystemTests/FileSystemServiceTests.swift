import XCTest
@testable import WorkspaceFileSystem
@testable import WorkspaceIgnore

final class FileSystemServiceTests: XCTestCase {
    
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
        flags: FSEventStreamEventFlags,
        eventId: FSEventStreamEventId = 0
    ) -> (absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId) {
        return (absolutePath: path, flags: flags, eventId: eventId)
    }

	private static func catalogEligibilityBatchKey(_ rawRelativePath: String) -> String {
		(rawRelativePath as NSString).standardizingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
	}

	// MARK: - Catalog Eligibility Tests

	func testCatalogRegularFileEligibilityBatchMatchesSingleFileSemantics() async throws {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FileSystemServiceEligibilityBatch-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: rootURL) }

		try "ignored.txt\n".write(to: rootURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		XCTAssertTrue(FileManager.default.createFile(atPath: rootURL.appendingPathComponent("eligible.swift").path, contents: Data()))
		XCTAssertTrue(FileManager.default.createFile(atPath: rootURL.appendingPathComponent("ignored.txt").path, contents: Data()))
		let nestedURL = rootURL.appendingPathComponent("Nested", isDirectory: true)
		try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
		try "hidden.md\n".write(to: nestedURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		XCTAssertTrue(FileManager.default.createFile(atPath: nestedURL.appendingPathComponent("file.md").path, contents: Data()))
		XCTAssertTrue(FileManager.default.createFile(atPath: nestedURL.appendingPathComponent("hidden.md").path, contents: Data()))
		try FileManager.default.createSymbolicLink(
			at: rootURL.appendingPathComponent("link.swift"),
			withDestinationURL: rootURL.appendingPathComponent("eligible.swift")
		)
		try FileManager.default.createSymbolicLink(
			at: rootURL.appendingPathComponent("NestedLink"),
			withDestinationURL: nestedURL
		)

		let service = try await FileSystemService(
			path: rootURL.path,
			respectGitignore: true,
			respectRepoIgnore: false,
			respectCursorignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
		let rawRelativePaths = [
			"eligible.swift",
			"ignored.txt",
			"missing.txt",
			"Nested/file.md",
			"Nested/hidden.md",
			"Nested",
			"link.swift",
			"NestedLink/file.md",
			"NestedLink/missing.md",
			"eligible.swift",
			"./eligible.swift",
			"/Nested/file.md",
			"../outside.txt"
		]

		try await assertBatchEligibilityMatchesSingleFileSemantics(service: service, rawRelativePaths: rawRelativePaths)
		let batch = await service.catalogRegularFileEligibilityBatch(relativePaths: rawRelativePaths)
		XCTAssertLessThan(batch.count, rawRelativePaths.count, "Duplicate relative paths should coalesce safely in the batch result")
	}

	func testCatalogRegularFileEligibilityBatchMatchesSingleFileSemanticsForNestedIgnoreNegationCases() async throws {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FileSystemServiceEligibilityBatchNegation-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: rootURL) }

		try "*.log\n!keep.log\nignored-dir/\n!ignored-dir/reallowed.txt\n".write(
			to: rootURL.appendingPathComponent(".gitignore"),
			atomically: true,
			encoding: .utf8
		)
		XCTAssertTrue(FileManager.default.createFile(atPath: rootURL.appendingPathComponent("drop.log").path, contents: Data()))
		XCTAssertTrue(FileManager.default.createFile(atPath: rootURL.appendingPathComponent("keep.log").path, contents: Data()))

		let nestedURL = rootURL.appendingPathComponent("Nested", isDirectory: true)
		let deepURL = nestedURL.appendingPathComponent("Deep", isDirectory: true)
		let ignoredDirURL = rootURL.appendingPathComponent("ignored-dir", isDirectory: true)
		try FileManager.default.createDirectory(at: deepURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: ignoredDirURL, withIntermediateDirectories: true)
		try "hidden.md\n!visible.md\n*.tmp\n!allowed.tmp\n".write(
			to: nestedURL.appendingPathComponent(".gitignore"),
			atomically: true,
			encoding: .utf8
		)
		try "secret.txt\n!open.txt\n".write(
			to: deepURL.appendingPathComponent(".gitignore"),
			atomically: true,
			encoding: .utf8
		)
		for relativePath in [
			"Nested/hidden.md",
			"Nested/visible.md",
			"Nested/drop.tmp",
			"Nested/allowed.tmp",
			"Nested/Deep/secret.txt",
			"Nested/Deep/open.txt",
			"ignored-dir/file.txt",
			"ignored-dir/reallowed.txt"
		] {
			XCTAssertTrue(FileManager.default.createFile(atPath: rootURL.appendingPathComponent(relativePath).path, contents: Data()))
		}
		try FileManager.default.createSymbolicLink(
			at: rootURL.appendingPathComponent("NestedLink"),
			withDestinationURL: nestedURL
		)

		let service = try await FileSystemService(
			path: rootURL.path,
			respectGitignore: true,
			respectRepoIgnore: false,
			respectCursorignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
		let rawRelativePaths = [
			"drop.log",
			"keep.log",
			"Nested/hidden.md",
			"Nested/visible.md",
			"Nested/drop.tmp",
			"Nested/allowed.tmp",
			"Nested/Deep/secret.txt",
			"Nested/Deep/open.txt",
			"ignored-dir/file.txt",
			"ignored-dir/reallowed.txt",
			"ignored-dir/missing.txt",
			"NestedLink/visible.md",
			"Nested/visible.md",
			"./Nested/visible.md",
			"/Nested/hidden.md"
		]

		try await assertBatchEligibilityMatchesSingleFileSemantics(service: service, rawRelativePaths: rawRelativePaths)
	}

	func testCatalogRegularFileEligibilityPreparedBatchMatchesRawBatchForStandardizedPaths() async throws {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FileSystemServicePreparedEligibilityBatch-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: rootURL) }

		try "*.tmp\n".write(to: rootURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		XCTAssertTrue(FileManager.default.createFile(atPath: rootURL.appendingPathComponent("eligible.swift").path, contents: Data()))
		let parentAURL = rootURL.appendingPathComponent("ParentA", isDirectory: true)
		let parentBURL = rootURL.appendingPathComponent("ParentB", isDirectory: true)
		try FileManager.default.createDirectory(at: parentAURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: parentBURL, withIntermediateDirectories: true)
		XCTAssertTrue(FileManager.default.createFile(atPath: parentAURL.appendingPathComponent("file.md").path, contents: Data()))
		XCTAssertTrue(FileManager.default.createFile(atPath: parentAURL.appendingPathComponent("hidden.tmp").path, contents: Data()))
		XCTAssertTrue(FileManager.default.createFile(atPath: parentBURL.appendingPathComponent("other.swift").path, contents: Data()))

		let service = try await FileSystemService(
			path: rootURL.path,
			respectGitignore: true,
			respectRepoIgnore: false,
			respectCursorignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
		let preparedRelativePaths = [
			"eligible.swift",
			"ParentA/file.md",
			"ParentA/hidden.tmp",
			"ParentA/file.md",
			"ParentB/other.swift"
		]

		let raw = await service.catalogRegularFileEligibilityBatch(relativePaths: preparedRelativePaths)
		let prepared = await service.catalogRegularFileEligibilityBatchForPreparedRelativePaths(preparedRelativePaths)
		XCTAssertEqual(prepared, raw)

		let diagnosticBatch = await service.catalogRegularFileEligibilityPreparedBatchWithDiagnosticsForTesting(
			preparedRelativePaths: preparedRelativePaths
		)
		XCTAssertEqual(diagnosticBatch.results, raw)
		XCTAssertEqual(diagnosticBatch.diagnostics.preparedRelativePathFastPathAttemptCount, 1)
		XCTAssertEqual(diagnosticBatch.diagnostics.preparedRelativePathFastPathUsedCount, 1)
		XCTAssertEqual(diagnosticBatch.diagnostics.preparedRelativePathFastPathFallbackCount, 0)
		XCTAssertEqual(diagnosticBatch.diagnostics.preparedRelativePathFastPathInputCount, preparedRelativePaths.count)
		XCTAssertEqual(diagnosticBatch.diagnostics.preparedRelativePathFastPathGroupedEntryCount, raw.count)
		XCTAssertEqual(diagnosticBatch.diagnostics.preparedRelativePathFastPathParentReuseHitCount, 1)
		XCTAssertEqual(diagnosticBatch.diagnostics.preparedRelativePathFastPathParentReuseMissCount, 3)
	}

	func testCatalogRegularFileEligibilityPreparedBatchNoIgnoreParentSkipsHierarchicalLeafChecks() async throws {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FileSystemServicePreparedEligibilityNoIgnoreParent-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: rootURL) }

		let parentAURL = rootURL.appendingPathComponent("ParentA", isDirectory: true)
		let parentBURL = rootURL.appendingPathComponent("ParentB", isDirectory: true)
		try FileManager.default.createDirectory(at: parentAURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: parentBURL, withIntermediateDirectories: true)
		XCTAssertTrue(FileManager.default.createFile(atPath: parentAURL.appendingPathComponent("file.md").path, contents: Data()))
		XCTAssertTrue(FileManager.default.createFile(atPath: parentAURL.appendingPathComponent(".DS_Store").path, contents: Data()))
		XCTAssertTrue(FileManager.default.createFile(atPath: parentBURL.appendingPathComponent("other.swift").path, contents: Data()))

		let service = try await FileSystemService(
			path: rootURL.path,
			respectGitignore: true,
			respectRepoIgnore: false,
			respectCursorignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
		let preparedRelativePaths = [
			"ParentA/file.md",
			"ParentA/.DS_Store",
			"ParentB/other.swift"
		]

		let raw = await service.catalogRegularFileEligibilityBatch(relativePaths: preparedRelativePaths)
		let diagnosticBatch = await service.catalogRegularFileEligibilityPreparedBatchWithDiagnosticsForTesting(
			preparedRelativePaths: preparedRelativePaths
		)

		XCTAssertEqual(diagnosticBatch.results, raw)
		XCTAssertEqual(raw["ParentA/.DS_Store"], .ineligible(.ignored))
		XCTAssertEqual(diagnosticBatch.diagnostics.hierarchicalIgnoreNoOpParentGroupCount, 2)
		XCTAssertEqual(diagnosticBatch.diagnostics.hierarchicalIgnoreSkippedLeafCheckCount, preparedRelativePaths.count)
		XCTAssertEqual(diagnosticBatch.diagnostics.hierarchicalIgnoreCheckCount, 0)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixIgnoreNoOpParentGroupCount, 0)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixIgnoreSkippedLeafCheckCount, 0)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixIgnoreCheckCount, 0)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixDirectLeafFastPathParentGroupCount, 2)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixDirectLeafFastPathUnsupportedParentGroupCount, 0)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixDirectLeafFastPathLeafCheckCount, preparedRelativePaths.count)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixDirectLeafFastPathIgnoredLeafCount, 1)
		XCTAssertEqual(diagnosticBatch.diagnostics.singleFileFallbackUniquePathCount, 0)
	}

	func testCatalogRegularFileEligibilityPreparedBatchPrefixDirectLeafFastPathPreservesDefaultIgnoredLeaves() async throws {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FileSystemServicePreparedEligibilityDirectLeaf-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: rootURL) }

		let parentURL = rootURL.appendingPathComponent("Parent", isDirectory: true)
		try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
		XCTAssertTrue(FileManager.default.createFile(atPath: parentURL.appendingPathComponent("file.swift").path, contents: Data()))
		XCTAssertTrue(FileManager.default.createFile(atPath: parentURL.appendingPathComponent(".DS_Store").path, contents: Data()))
		XCTAssertTrue(FileManager.default.createFile(atPath: parentURL.appendingPathComponent("scratch.tmp").path, contents: Data()))
		XCTAssertTrue(FileManager.default.createFile(atPath: parentURL.appendingPathComponent("backup.bak").path, contents: Data()))
		XCTAssertTrue(FileManager.default.createFile(atPath: parentURL.appendingPathComponent("swap.swp").path, contents: Data()))
		XCTAssertTrue(FileManager.default.createFile(atPath: parentURL.appendingPathComponent("notes~").path, contents: Data()))

		let service = try await FileSystemService(
			path: rootURL.path,
			respectGitignore: false,
			respectRepoIgnore: false,
			respectCursorignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
		let preparedRelativePaths = [
			"Parent/file.swift",
			"Parent/.DS_Store",
			"Parent/scratch.tmp",
			"Parent/backup.bak",
			"Parent/swap.swp",
			"Parent/notes~"
		]

		let raw = await service.catalogRegularFileEligibilityBatch(relativePaths: preparedRelativePaths)
		let diagnosticBatch = await service.catalogRegularFileEligibilityPreparedBatchWithDiagnosticsForTesting(
			preparedRelativePaths: preparedRelativePaths
		)

		XCTAssertEqual(diagnosticBatch.results, raw)
		for relativePath in preparedRelativePaths {
			let single = await service.catalogRegularFileEligibility(relativePath: relativePath)
			XCTAssertEqual(raw[relativePath], single)
		}
		XCTAssertEqual(raw["Parent/file.swift"], .eligible)
		XCTAssertEqual(raw["Parent/.DS_Store"], .ineligible(.ignored))
		XCTAssertEqual(raw["Parent/scratch.tmp"], .ineligible(.ignored))
		XCTAssertEqual(raw["Parent/backup.bak"], .ineligible(.ignored))
		XCTAssertEqual(raw["Parent/swap.swp"], .ineligible(.ignored))
		XCTAssertEqual(raw["Parent/notes~"], .ineligible(.ignored))
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixDirectLeafFastPathParentGroupCount, 1)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixDirectLeafFastPathUnsupportedParentGroupCount, 0)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixDirectLeafFastPathLeafCheckCount, preparedRelativePaths.count)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixDirectLeafFastPathIgnoredLeafCount, 5)
		XCTAssertGreaterThan(diagnosticBatch.diagnostics.prefixDirectLeafFastPathCandidatePatternCountMax, 0)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixIgnoreCheckCount, 0)
		XCTAssertEqual(diagnosticBatch.diagnostics.singleFileFallbackUniquePathCount, 0)
	}

	func testCatalogRegularFileEligibilityPreparedBatchPrefixDirectLeafFastPathFallsBackForNegation() async throws {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FileSystemServicePreparedEligibilityDirectLeafNegation-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: rootURL) }

		try "*.log\n!keep.log\n".write(to: rootURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		XCTAssertTrue(FileManager.default.createFile(atPath: rootURL.appendingPathComponent("drop.log").path, contents: Data()))
		XCTAssertTrue(FileManager.default.createFile(atPath: rootURL.appendingPathComponent("keep.log").path, contents: Data()))

		let service = try await FileSystemService(
			path: rootURL.path,
			respectGitignore: true,
			respectRepoIgnore: false,
			respectCursorignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
		let preparedRelativePaths = [
			"drop.log",
			"keep.log"
		]

		let raw = await service.catalogRegularFileEligibilityBatch(relativePaths: preparedRelativePaths)
		let diagnosticBatch = await service.catalogRegularFileEligibilityPreparedBatchWithDiagnosticsForTesting(
			preparedRelativePaths: preparedRelativePaths
		)

		XCTAssertEqual(diagnosticBatch.results, raw)
		XCTAssertEqual(raw["drop.log"], .ineligible(.ignored))
		XCTAssertEqual(raw["keep.log"], .eligible)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixDirectLeafFastPathParentGroupCount, 0)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixDirectLeafFastPathUnsupportedParentGroupCount, 1)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixDirectLeafFastPathLeafCheckCount, 0)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixIgnoreCheckCount, preparedRelativePaths.count)
		XCTAssertEqual(diagnosticBatch.diagnostics.singleFileFallbackUniquePathCount, 0)
	}

	func testCatalogRegularFileEligibilityPreparedBatchPrefixDirectLeafFastPathFallsBackForLocalNegation() async throws {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FileSystemServicePreparedEligibilityDirectLeafLocalNegation-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: rootURL) }

		let parentURL = rootURL.appendingPathComponent("Parent", isDirectory: true)
		try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
		try "*.log\n!keep.log\n".write(to: parentURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		XCTAssertTrue(FileManager.default.createFile(atPath: parentURL.appendingPathComponent("drop.log").path, contents: Data()))
		XCTAssertTrue(FileManager.default.createFile(atPath: parentURL.appendingPathComponent("keep.log").path, contents: Data()))

		let service = try await FileSystemService(
			path: rootURL.path,
			respectGitignore: true,
			respectRepoIgnore: false,
			respectCursorignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
		let preparedRelativePaths = [
			"Parent/drop.log",
			"Parent/keep.log"
		]

		let raw = await service.catalogRegularFileEligibilityBatch(relativePaths: preparedRelativePaths)
		let diagnosticBatch = await service.catalogRegularFileEligibilityPreparedBatchWithDiagnosticsForTesting(
			preparedRelativePaths: preparedRelativePaths
		)

		XCTAssertEqual(diagnosticBatch.results, raw)
		XCTAssertEqual(raw["Parent/drop.log"], .ineligible(.ignored))
		XCTAssertEqual(raw["Parent/keep.log"], .eligible)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixDirectLeafFastPathParentGroupCount, 0)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixDirectLeafFastPathUnsupportedParentGroupCount, 1)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixDirectLeafFastPathLeafCheckCount, 0)
		XCTAssertEqual(diagnosticBatch.diagnostics.prefixIgnoreCheckCount, preparedRelativePaths.count)
		XCTAssertEqual(diagnosticBatch.diagnostics.singleFileFallbackUniquePathCount, 0)
	}

	func testCatalogRegularFileEligibilityPreparedBatchFallsBackForUnsafeInput() async throws {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FileSystemServicePreparedEligibilityBatchFallback-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: rootURL) }

		XCTAssertTrue(FileManager.default.createFile(atPath: rootURL.appendingPathComponent("eligible.swift").path, contents: Data()))
		let parentURL = rootURL.appendingPathComponent("Parent", isDirectory: true)
		try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
		XCTAssertTrue(FileManager.default.createFile(atPath: parentURL.appendingPathComponent("file.md").path, contents: Data()))

		let service = try await FileSystemService(
			path: rootURL.path,
			respectGitignore: true,
			respectRepoIgnore: false,
			respectCursorignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
		let unsafeRelativePaths = [
			"./eligible.swift",
			"Parent//file.md",
			"Parent/../Parent/file.md"
		]

		let raw = await service.catalogRegularFileEligibilityBatch(relativePaths: unsafeRelativePaths)
		let prepared = await service.catalogRegularFileEligibilityBatchForPreparedRelativePaths(unsafeRelativePaths)
		XCTAssertEqual(prepared, raw)

		let diagnosticBatch = await service.catalogRegularFileEligibilityPreparedBatchWithDiagnosticsForTesting(
			preparedRelativePaths: unsafeRelativePaths
		)
		XCTAssertEqual(diagnosticBatch.results, raw)
		XCTAssertEqual(diagnosticBatch.diagnostics.preparedRelativePathFastPathAttemptCount, 1)
		XCTAssertEqual(diagnosticBatch.diagnostics.preparedRelativePathFastPathUsedCount, 0)
		XCTAssertEqual(diagnosticBatch.diagnostics.preparedRelativePathFastPathFallbackCount, 1)
		XCTAssertEqual(diagnosticBatch.diagnostics.preparedRelativePathFastPathInputCount, unsafeRelativePaths.count)
		XCTAssertEqual(diagnosticBatch.diagnostics.preparedRelativePathFastPathGroupedEntryCount, 0)
	}

	private func assertBatchEligibilityMatchesSingleFileSemantics(
		service: FileSystemService,
		rawRelativePaths: [String],
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws {
		let batch = await service.catalogRegularFileEligibilityBatch(relativePaths: rawRelativePaths)
		let expectedKeys = Set(rawRelativePaths.map(Self.catalogEligibilityBatchKey))
		XCTAssertEqual(Set(batch.keys), expectedKeys, file: file, line: line)

		for rawRelativePath in rawRelativePaths {
			let key = Self.catalogEligibilityBatchKey(rawRelativePath)
			let single = await service.catalogRegularFileEligibility(relativePath: rawRelativePath)
			XCTAssertEqual(batch[key], single, "Batch eligibility should preserve single-file semantics for \(rawRelativePath)", file: file, line: line)
		}
	}
    
    // MARK: - Core Filter Logic Tests
    
    func testAlreadyTrackedButNowIgnoredFileIsNotDiscarded() async throws {
        // Setup: File is already tracked
        let trackedFile = "src/config.json"
        let fs = InMemoryFS()
        
        // Create the file structure
        fs.addFolder("/tmp/test/src")
        fs.addFile("/tmp/test/src/config.json")
        
        // Add ignore pattern for config.json
        let service = try await createTestService(
            visitedPaths: [trackedFile],
            visitedItems: [trackedFile: false],
            ignorePatterns: ["src/config.json"],
            fs: fs
        )
        
        // Create a modification event for the tracked file
        let event = createFSEvent(
            path: "/tmp/test/\(trackedFile)",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        )
        
        // Process the event
        let deltas = await service.simulateFSEvents([event])
        
        // Verify: Event should NOT be discarded even though file is now ignored
        XCTAssertFalse(deltas.isEmpty, "Event for already-tracked but now-ignored file should not be discarded")
        
        // Verify the file is still in visitedPaths
        let (paths, _) = await service.getTestState()
        XCTAssertTrue(paths.contains(trackedFile))
    }
    
	func testUnknownIgnoredNonRenamePathIsDiscarded() async throws {
		// Setup: File is NOT tracked
		let unknownFile = "node_modules/package/file.js"
		let fs = InMemoryFS()
		
        // Create node_modules structure (but not the specific file yet)
        fs.addFolder("/tmp/test/node_modules")
        fs.addFolder("/tmp/test/node_modules/package")
        
        let service = try await createTestService(
            visitedPaths: [],
            visitedItems: [:],
            ignorePatterns: ["node_modules/"],
            fs: fs
        )
        
        // Create a creation event for the unknown file
        let event = createFSEvent(
            path: "/tmp/test/\(unknownFile)",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )
        
		// Process the event
		let deltas = await service.simulateFSEvents([event])
		
		// Verify: Event should be discarded
		XCTAssertTrue(deltas.isEmpty, "Event for unknown ignored file should be discarded")
	}
	
	func testNewDirectoryUnderIgnoredAncestorIsDroppedImmediately() async throws {
		let fs = InMemoryFS()
		fs.addFolder("/tmp/test")
		
		let service = try await createTestService(
			ignorePatterns: ["build/"],
			fs: fs
		)
		
		// Directory does not exist yet on disk; rely on FSEvent flag.
		let event = createFSEvent(
			path: "/tmp/test/build",
			flags: FSEventStreamEventFlags(
				kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir
			)
		)
		
		let deltas = await service.simulateFSEvents([event])
		XCTAssertTrue(deltas.isEmpty, "New ignored directories should be dropped before scanning")
	}

	func testUnknownRegularFileFSEventDirectLeafFastPathDropsIgnoredLeafPattern() async throws {
		let ignoredFile = "src/generated.tmp"
		let fs = InMemoryFS()
		fs.addFolder("/tmp/test/src")
		fs.addFile("/tmp/test/\(ignoredFile)")

		let service = try await createTestService(
			ignorePatterns: ["*.tmp"],
			fs: fs
		)

		let event = createFSEvent(
			path: "/tmp/test/\(ignoredFile)",
			flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
		)

		let deltas = await service.simulateFSEvents([event])
		XCTAssertTrue(deltas.isEmpty, "Ignored unknown regular-file events should be dropped by the direct leaf fast path")

		let diagnosticsSnapshot = await service.lastEventTargetIgnoreFastPathDiagnosticsForTesting()
		let diagnostics = try XCTUnwrap(diagnosticsSnapshot)
		XCTAssertEqual(diagnostics.unknownRegularFileDecisionCount, 1)
		XCTAssertEqual(diagnostics.parentStateCacheMissCount, 1)
		XCTAssertEqual(diagnostics.exactParentStateCount, 1)
		XCTAssertEqual(diagnostics.unsupportedParentStateCount, 0)
		XCTAssertEqual(diagnostics.directLeafCheckCount, 1)
		XCTAssertEqual(diagnostics.directLeafIgnoredCount, 1)
		XCTAssertEqual(diagnostics.fallbackFullTargetIgnoreCheckCount, 0)
		XCTAssertEqual(diagnostics.exactFullTargetIgnoreCheckCount, 0)
	}

	func testUnknownRegularFileFSEventDirectLeafFastPathKeepsVisibleLeaf() async throws {
		let visibleFile = "src/visible.swift"
		let fs = InMemoryFS()
		fs.addFolder("/tmp/test/src")
		fs.addFile("/tmp/test/\(visibleFile)")

		let service = try await createTestService(
			ignorePatterns: ["*.tmp"],
			fs: fs
		)

		let event = createFSEvent(
			path: "/tmp/test/\(visibleFile)",
			flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
		)

		let deltas = await service.simulateFSEvents([event])
		XCTAssertTrue(deltas.contains(.fileAdded(visibleFile)), "Visible unknown regular-file events should continue to schedule discovery")

		let diagnosticsSnapshot = await service.lastEventTargetIgnoreFastPathDiagnosticsForTesting()
		let diagnostics = try XCTUnwrap(diagnosticsSnapshot)
		XCTAssertEqual(diagnostics.unknownRegularFileDecisionCount, 1)
		XCTAssertEqual(diagnostics.parentStateCacheMissCount, 1)
		XCTAssertEqual(diagnostics.exactParentStateCount, 1)
		XCTAssertEqual(diagnostics.unsupportedParentStateCount, 0)
		XCTAssertEqual(diagnostics.directLeafCheckCount, 1)
		XCTAssertEqual(diagnostics.directLeafIgnoredCount, 0)
		XCTAssertEqual(diagnostics.fallbackFullTargetIgnoreCheckCount, 0)
		XCTAssertEqual(diagnostics.exactFullTargetIgnoreCheckCount, 0)
	}

	func testUnknownRegularFileFSEventFastPathFallsBackForRootNegation() async throws {
		let ignoredFile = "drop.log"
		let fs = InMemoryFS()
		fs.addFile("/tmp/test/\(ignoredFile)")

		let service = try await createTestService(
			ignorePatterns: ["*.log", "!keep.log"],
			fs: fs
		)

		let event = createFSEvent(
			path: "/tmp/test/\(ignoredFile)",
			flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
		)

		let deltas = await service.simulateFSEvents([event])
		XCTAssertTrue(deltas.isEmpty, "Negations should force fallback to full ignore behavior before dropping ignored files")

		let diagnosticsSnapshot = await service.lastEventTargetIgnoreFastPathDiagnosticsForTesting()
		let diagnostics = try XCTUnwrap(diagnosticsSnapshot)
		XCTAssertEqual(diagnostics.unknownRegularFileDecisionCount, 1)
		XCTAssertEqual(diagnostics.parentStateCacheMissCount, 1)
		XCTAssertEqual(diagnostics.exactParentStateCount, 0)
		XCTAssertEqual(diagnostics.unsupportedParentStateCount, 1)
		XCTAssertEqual(diagnostics.directLeafCheckCount, 0)
		XCTAssertEqual(diagnostics.fallbackFullTargetIgnoreCheckCount, 1)
		XCTAssertEqual(diagnostics.fallbackFullTargetIgnoredCount, 1)
		XCTAssertEqual(diagnostics.exactFullTargetIgnoreCheckCount, 0)
	}

	func testUnknownRegularFileFSEventFastPathFallsBackForLocalNegation() async throws {
		let ignoredFile = "src/drop.log"
		let fs = InMemoryFS()
		fs.addFolder("/tmp/test/src")
		fs.writeGitignore(at: "/tmp/test/src", "*.log\n!keep.log\n")
		fs.addFile("/tmp/test/\(ignoredFile)")

		let service = try await createTestService(fs: fs)

		let event = createFSEvent(
			path: "/tmp/test/\(ignoredFile)",
			flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
		)

		let deltas = await service.simulateFSEvents([event])
		XCTAssertTrue(deltas.isEmpty, "Local negations should force fallback to full ignore behavior before dropping ignored files")

		let diagnosticsSnapshot = await service.lastEventTargetIgnoreFastPathDiagnosticsForTesting()
		let diagnostics = try XCTUnwrap(diagnosticsSnapshot)
		XCTAssertEqual(diagnostics.unknownRegularFileDecisionCount, 1)
		XCTAssertEqual(diagnostics.parentStateCacheMissCount, 1)
		XCTAssertEqual(diagnostics.exactParentStateCount, 0)
		XCTAssertEqual(diagnostics.unsupportedParentStateCount, 1)
		XCTAssertEqual(diagnostics.directLeafCheckCount, 0)
		XCTAssertEqual(diagnostics.fallbackFullTargetIgnoreCheckCount, 1)
		XCTAssertEqual(diagnostics.fallbackFullTargetIgnoredCount, 1)
		XCTAssertEqual(diagnostics.exactFullTargetIgnoreCheckCount, 0)
	}
	
	func testOutsideRootEventsAreIgnored() async throws {
		let fs = InMemoryFS()
		fs.addFolder("/tmp/test")
		
		let service = try await createTestService(fs: fs)
		let event = createFSEvent(
			path: "/tmp/other/outside.txt",
			flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
		)
		
		let deltas = await service.simulateFSEvents([event])
		XCTAssertTrue(deltas.isEmpty, "Events outside the watched root must be ignored")
	}
	
	// MARK: - Rename Event Tests
    
    func testRenameWithinIgnoredTreeIsDiscarded() async throws {
        let renamedFile = "node_modules/package/old.js"
        let fs = InMemoryFS()
        
        fs.addFolder("/tmp/test/node_modules")
        fs.addFolder("/tmp/test/node_modules/package")
        fs.addFile("/tmp/test/node_modules/package/old.js")
        
        let service = try await createTestService(
            visitedPaths: [],
            visitedItems: [:],
            ignorePatterns: ["node_modules/"],
            fs: fs
        )
        
        let event = createFSEvent(
            path: "/tmp/test/\(renamedFile)",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        )
        
        let deltas = await service.simulateFSEvents([event])
        XCTAssertTrue(deltas.isEmpty, "Rename within ignored tree should be discarded")
    }
    
    func testAtomicSaveRenameProcessed() async throws {
        let trackedFile = "src/main.swift"
        let tempFile = "src/.main.swift.tmp"
        let fs = InMemoryFS()
        
        fs.addFolder("/tmp/test/src")
        fs.addFile("/tmp/test/src/main.swift")
        fs.addFile("/tmp/test/src/.main.swift.tmp")
        
        let service = try await createTestService(
            visitedPaths: [trackedFile],
            visitedItems: [trackedFile: false],
            ignorePatterns: ["*.tmp"],
            fs: fs
        )
        
        // Simulate atomic save: temp file is renamed to tracked file
        // Real FSEvents emit two events: source (removed) and destination (created)
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
        
        let deltas = await service.simulateFSEvents(events)
        XCTAssertFalse(deltas.isEmpty, "Rename to tracked file should be processed")
    }
    
    func testRenameFromIgnoredToNonIgnoredProcessed() async throws {
        let fs = InMemoryFS()
        
        fs.addFolder("/tmp/test/tmp")
        fs.addFolder("/tmp/test/src")
        fs.addFile("/tmp/test/tmp/moving.txt")
        
        let service = try await createTestService(
            visitedPaths: [],
            visitedItems: [:],
            ignorePatterns: ["tmp/"],
            fs: fs
        )
        
        // Simulate the file now exists in src (before events)
        fs.remove("/tmp/test/tmp/moving.txt")
        fs.addFile("/tmp/test/src/moving.txt")
        
        // Real FSEvents emit TWO events for a rename: source (removed) and destination (created)
        let events = [
            createFSEvent(
                path: "/tmp/test/tmp/moving.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved)
            ),
            createFSEvent(
                path: "/tmp/test/src/moving.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCreated)
            )
        ]
        
        let deltas = await service.simulateFSEvents(events)
        XCTAssertFalse(deltas.isEmpty, "Rename from ignored to non-ignored should be processed")
    }

    func testRenameOnlyDeleteOfTrackedFileEmitsRemoval() async throws {
        // Regression test: rename-only events (ItemRenamed|IsFile without ItemRemoved/ItemCreated)
        // happen when files are moved to Trash or cross-directory moves. These should emit removal deltas.
        let trackedFile = "motory-group/test/tracked_motory_3.txt"
        let fs = InMemoryFS()

        fs.addFolder("/tmp/test/motory-group/test")
        fs.addFile("/tmp/test/\(trackedFile)")

        let service = try await createTestService(
            visitedPaths: [trackedFile],
            visitedItems: [trackedFile: false],
            ignorePatterns: [],
            fs: fs
        )

        // File is gone by the time the event is processed (moved to Trash, etc.)
        fs.remove("/tmp/test/\(trackedFile)")

        let event = createFSEvent(
            path: "/tmp/test/\(trackedFile)",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile)
        )

        let deltas = await service.simulateFSEvents([event])
        XCTAssertTrue(deltas.contains { if case .fileRemoved(let p) = $0 { return p == trackedFile } else { return false } },
                      "Rename-only event for missing tracked file should emit fileRemoved")

        let (paths, _) = await service.getTestState()
        XCTAssertFalse(paths.contains(trackedFile), "Tracked file should be removed from visitedPaths")
    }

	// MARK: - Trash Operation Tests
	
	func testMoveItemToTrashMovesFileToTrashAndRemovesVisitedState() async throws {
		let trackedFile = "src/delete.swift"
		let fs = InMemoryFS()
		fs.addFolder("/tmp/test/src")
		fs.addFile("/tmp/test/\(trackedFile)")
		
		let service = try await createTestService(
			visitedPaths: [trackedFile],
			visitedItems: [trackedFile: false],
			fs: fs
		)
		
		try await service.moveItemToTrash(atRelativePath: trackedFile)
		
		XCTAssertTrue(fs.trashedPathsSnapshot().contains("/tmp/test/\(trackedFile)"))
		XCTAssertFalse(fs.fileExists(atPath: "/tmp/test/\(trackedFile)", isDirectory: nil))
		let (paths, items) = await service.getTestState()
		XCTAssertFalse(paths.contains(trackedFile))
		XCTAssertNil(items[trackedFile])
	}
	
	func testMoveItemToTrashMovesFolderSubtreeToTrashAndRemovesVisitedState() async throws {
		let folder = "docs"
		let child = "docs/readme.md"
		let fs = InMemoryFS()
		fs.addFolder("/tmp/test/\(folder)")
		fs.addFile("/tmp/test/\(child)")
		
		let service = try await createTestService(
			visitedPaths: [folder, child],
			visitedItems: [folder: true, child: false],
			fs: fs
		)
		
		try await service.moveItemToTrash(atRelativePath: folder)
		
		let trashedPaths = fs.trashedPathsSnapshot()
		XCTAssertTrue(trashedPaths.contains("/tmp/test/\(folder)"))
		XCTAssertTrue(trashedPaths.contains("/tmp/test/\(child)"))
		XCTAssertFalse(fs.fileExists(atPath: "/tmp/test/\(folder)", isDirectory: nil))
		XCTAssertFalse(fs.fileExists(atPath: "/tmp/test/\(child)", isDirectory: nil))
		let (paths, items) = await service.getTestState()
		XCTAssertFalse(paths.contains(folder))
		XCTAssertFalse(paths.contains(child))
		XCTAssertNil(items[folder])
		XCTAssertNil(items[child])
	}
	
	func testMoveItemToTrashRejectsAbsoluteRelativePath() async throws {
		let fs = InMemoryFS()
		fs.addFolder("/tmp/test/src")
		fs.addFile("/tmp/test/src/delete.swift")
		let service = try await createTestService(fs: fs)
		
		do {
			try await service.moveItemToTrash(atRelativePath: "/tmp/test/src/delete.swift")
			XCTFail("Expected absolute relative paths to be rejected")
		} catch FileSystemError.invalidRelativePath {
			// Expected.
		} catch {
			XCTFail("Expected invalidRelativePath, got \(error)")
		}
	}

    // MARK: - Ignore File Tests
    
    func testIgnoreFileEventsAreAlwaysProcessed() async throws {
        // Test 1: Ignore file in ignored directory should be skipped
        let ignoreFileInIgnored = "build/.gitignore"
        let fs1 = InMemoryFS()
        
        fs1.addFolder("/tmp/test/build")
        
        let service1 = try await createTestService(
            visitedPaths: [],
            visitedItems: [:],
            ignorePatterns: ["build/"],
            fs: fs1
        )
        
        let event1 = createFSEvent(
            path: "/tmp/test/\(ignoreFileInIgnored)",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )
        
        let deltas1 = await service1.simulateFSEvents([event1])
        XCTAssertTrue(deltas1.isEmpty, "Ignore file in ignored directory should be skipped")
        
        // Test 2: Ignore file in non-ignored directory should be processed
        let ignoreFileInNonIgnored = "src/.gitignore"
        let fs2 = InMemoryFS()
        
        fs2.addFolder("/tmp/test/src")
        fs2.addFile("/tmp/test/src/.gitignore") // Create the file before the event
        
        let service2 = try await createTestService(
            visitedPaths: [],
            visitedItems: [:],
            ignorePatterns: [], // No patterns - src is NOT ignored
            fs: fs2
        )
        
        let event2 = createFSEvent(
            path: "/tmp/test/\(ignoreFileInNonIgnored)",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )
        
		let deltas2 = await service2.simulateFSEvents([event2])
		let processedFolders = await service2.getProcessedFolders()
		XCTAssertTrue(processedFolders.contains("src"), "Ignore file in non-ignored directory should trigger a rescan of its parent")
		XCTAssertTrue(deltas2.isEmpty, "Ignore files are control files and should not generate visible deltas")
    }
    
    func testIgnoreFilePatternsRecognition() async throws {
        // Test 1: Ignore files in already-ignored directories should be skipped
        let fs1 = InMemoryFS()
        fs1.addFolder("/tmp/test/src")
        
        let service1 = try await createTestService(
            visitedPaths: [],
            visitedItems: [:],
            ignorePatterns: ["src/"],
            fs: fs1
        )
        
        let ignoreFilesInIgnored = [
            "src/.gitignore",
            "src/.repo_ignore",
            "src/.cursorignore"
        ]
        
        // Ignore files inside already-ignored directories should be skipped
        // (they have no effect since the parent dir is already ignored)
        for ignoreFile in ignoreFilesInIgnored {
            let event = createFSEvent(
                path: "/tmp/test/\(ignoreFile)",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            )
            
            let deltas = await service1.simulateFSEvents([event])
            XCTAssertTrue(deltas.isEmpty, "\(ignoreFile) inside already-ignored directory should be skipped")
        }
        
        // Test 2: Ignore files in non-ignored directories SHOULD be processed
        let fs2 = InMemoryFS()
        fs2.addFolder("/tmp/test/src")
        
        let service2 = try await createTestService(
            visitedPaths: [],
            visitedItems: [:],
            ignorePatterns: [], // No patterns - src is NOT ignored
            fs: fs2
        )
        
        let ignoreFilesInNonIgnored = [
            "src/.gitignore",
            "src/.repo_ignore",
            "src/.cursorignore"
        ]
        
		var eventId: FSEventStreamEventId = 100
		for ignoreFile in ignoreFilesInNonIgnored {
			// Create the file in the filesystem before the event
			fs2.addFile("/tmp/test/\(ignoreFile)")
			
			// Use incrementing event IDs (realistic - FSEvents uses monotonic IDs)
			let event = createFSEvent(
				path: "/tmp/test/\(ignoreFile)",
				flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
				eventId: eventId
			)
			eventId += 1
			
			let deltas = await service2.simulateFSEvents([event])
			let processedFolders = await service2.getProcessedFolders()
			let parent = String(ignoreFile.split(separator: "/").dropLast().joined(separator: "/"))
			XCTAssertTrue(processedFolders.contains(parent), "\(ignoreFile) should cause its parent folder to be rescanned")
			XCTAssertTrue(deltas.isEmpty, "\(ignoreFile) is a control file and should not emit file deltas")
		}
	}
    
    // MARK: - Complex Scenario Tests
    
    func testMultipleEventsWithMixedConditions() async throws {
        let fs = InMemoryFS()
        
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
        
        let deltas = await service.simulateFSEvents(events)
        
        // Should process: tracked.swift (modified) and new.swift (added)
        // Should filter: node_modules/package/index.js (in ignored dir), build/output.js (in ignored dir), and src/temp.tmp (matches *.tmp)
        XCTAssertEqual(deltas.count, 2, "Should process 2 events (1 tracked + 1 non-ignored new)")
        
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
    
    func testLargeEventBatch() async throws {
        let fs = InMemoryFS()
        
        // Create structure
        fs.addFolder("/tmp/test/src")
        fs.addFolder("/tmp/test/ignored")
        
        // Pre-populate tracked files
        var trackedPaths = Set<String>()
        var visitedItems = [String: Bool]()
        
        for i in 0..<100 {
            let path = "src/tracked\(i).swift"
            trackedPaths.insert(path)
            visitedItems[path] = false
            fs.addFile("/tmp/test/\(path)")
        }
        
        let service = try await createTestService(
            visitedPaths: trackedPaths,
            visitedItems: visitedItems,
            ignorePatterns: ["ignored/"],
            fs: fs
        )
        
        // Create events
        var events: [(absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId)] = []
        
        // 100 tracked file modifications
        for i in 0..<100 {
            events.append(createFSEvent(
                path: "/tmp/test/src/tracked\(i).swift",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
            ))
        }
        
        // Create the new files in the filesystem BEFORE generating events
        for i in 0..<100 {
            fs.addFile("/tmp/test/src/new\(i).swift")
        }
        
        // 100 new non-ignored files
        for i in 0..<100 {
            events.append(createFSEvent(
                path: "/tmp/test/src/new\(i).swift",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            ))
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let deltas = await service.simulateFSEvents(events)
        let endTime = CFAbsoluteTimeGetCurrent()
        
        XCTAssertEqual(deltas.count, 200, "Should process all 200 non-ignored events")
        XCTAssertLessThan(endTime - startTime, 1.0, "Should process 200 events in less than 1 second")
    }
    
    // MARK: - Path Normalization Tests
    
    func testPathNormalization() async throws {
        let fs = InMemoryFS()
        
        fs.addFolder("/tmp/test/src")
        fs.addFile("/tmp/test/src/file.txt")
        
        let service = try await createTestService(
            visitedPaths: ["src/file.txt"],
            visitedItems: ["src/file.txt": false],
            fs: fs
        )
        
        let events = [
            createFSEvent(path: "/tmp/test//src//file.txt",
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)),
            createFSEvent(path: "/tmp/test/./src/file.txt",
                         flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified))
        ]
        
        let deltas = await service.simulateFSEvents(events)
        
        XCTAssertEqual(deltas.count, 1, "Normalized duplicate path variants should coalesce to a single published delta")
        
        let modifiedPaths = deltas.compactMap { delta -> String? in
            if case .fileModified(let path, _) = delta { return path }
            return nil
        }
        
        XCTAssertEqual(modifiedPaths, ["src/file.txt"],
                      "The published delta should use the normalized relative path")
    }

	func testStandardizedFSEventPathUsesFastRelativeMapping() async throws {
		let fs = InMemoryFS()
		fs.addFolder("/tmp/test/src")
		fs.addFile("/tmp/test/src/fast.txt")

		let service = try await createTestService(fs: fs)
		let event = createFSEvent(
			path: "/tmp/test/src/fast.txt",
			flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
		)

		let deltas = await service.simulateFSEvents([event])
		XCTAssertTrue(deltas.contains(.fileAdded("src/fast.txt")))

		let diagnosticsSnapshot = await service.lastEventPathMappingFastPathDiagnosticsForTesting()
		let diagnostics = try XCTUnwrap(diagnosticsSnapshot)
		XCTAssertEqual(diagnostics.rawPathCount, 1)
		XCTAssertEqual(diagnostics.fastStandardRootHitCount, 1)
		XCTAssertEqual(diagnostics.fastCanonicalRootHitCount, 0)
		XCTAssertEqual(diagnostics.fallbackStandardizationCount, 0)
		XCTAssertEqual(diagnostics.rejectedUnsafePathCount, 0)
	}

	func testNonStandardFSEventPathFallsBackToStandardization() async throws {
		let fs = InMemoryFS()
		fs.addFolder("/tmp/test/src")
		fs.addFile("/tmp/test/src/file.txt")

		let service = try await createTestService(
			visitedPaths: ["src/file.txt"],
			visitedItems: ["src/file.txt": false],
			fs: fs
		)
		let events = [
			createFSEvent(
				path: "/tmp/test//src//file.txt",
				flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
			),
			createFSEvent(
				path: "/tmp/test/./src/file.txt",
				flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
			)
		]

		let deltas = await service.simulateFSEvents(events)
		let modifiedPaths = deltas.compactMap { delta -> String? in
			if case .fileModified(let path, _) = delta { return path }
			return nil
		}
		XCTAssertEqual(modifiedPaths, ["src/file.txt"])

		let diagnosticsSnapshot = await service.lastEventPathMappingFastPathDiagnosticsForTesting()
		let diagnostics = try XCTUnwrap(diagnosticsSnapshot)
		XCTAssertEqual(diagnostics.rawPathCount, events.count)
		XCTAssertEqual(diagnostics.fastStandardRootHitCount, 0)
		XCTAssertEqual(diagnostics.fastCanonicalRootHitCount, 0)
		XCTAssertEqual(diagnostics.fallbackStandardizationCount, events.count)
		XCTAssertEqual(diagnostics.rejectedUnsafePathCount, events.count)
	}
    
    // MARK: - Directory Event Tests
    
    func testDirectoryEvents() async throws {
        let fs = InMemoryFS()
        
        fs.addFolder("/tmp/test/src")
        fs.addFolder("/tmp/test/src/components")
        
        let service = try await createTestService(
            visitedPaths: ["src/components"],
            visitedItems: ["src/components": true],
            fs: fs
        )
        
        let event = createFSEvent(
            path: "/tmp/test/src/components",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsDir)
        )
        
        let deltas = await service.simulateFSEvents([event])
        
        XCTAssertFalse(deltas.isEmpty, "Tracked directory events should be processed")
    }
    
    func testDeepDirectoryNesting() async throws {
        let fs = InMemoryFS()
        
        // Create deep nested structure
        var currentPath = "/tmp/test"
        var relativePath = ""
        
        for i in 0..<20 {
            currentPath += "/level\(i)"
            relativePath = relativePath.isEmpty ? "level\(i)" : "\(relativePath)/level\(i)"
            fs.addFolder(currentPath)
        }
        
        fs.addFile("\(currentPath)/deep.txt")
        let deepFile = "\(relativePath)/deep.txt"
        
        let service = try await createTestService(fs: fs)
        
        let event = createFSEvent(
            path: "/tmp/test/\(deepFile)",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )
        
        let deltas = await service.simulateFSEvents([event])
        
        XCTAssertFalse(deltas.isEmpty, "Deep nested files should be processed")
    }
    
    // MARK: - Special Character Tests
    
    func testSpecialCharactersInPaths() async throws {
        let fs = InMemoryFS()
        
        let specialPaths = [
            "src/file with spaces.txt",
            "src/file-with-dashes.txt",
            "src/file_with_underscores.txt",
            "src/file.multiple.dots.txt",
            "src/文件.txt", // Unicode
            "src/file@symbol.txt"
        ]
        
        fs.addFolder("/tmp/test/src")
        
        for path in specialPaths {
            fs.addFile("/tmp/test/\(path)")
        }
        
        let service = try await createTestService(fs: fs)
        
        var events: [(absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId)] = []
        
        for path in specialPaths {
            events.append(createFSEvent(
                path: "/tmp/test/\(path)",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            ))
        }
        
        let deltas = await service.simulateFSEvents(events)
        
        XCTAssertEqual(deltas.count, specialPaths.count,
                       "All special character paths should be processed")
    }
    
    // MARK: - Edge Case Tests
    
    func testEmptyPathHandling() async throws {
        let fs = InMemoryFS()
        let service = try await createTestService(fs: fs)
        
        // This should be handled gracefully
        let event = createFSEvent(
            path: "/tmp/test/",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        )
        
        let deltas = await service.simulateFSEvents([event])
        
        // Root directory events are typically ignored
        XCTAssertTrue(deltas.isEmpty || deltas.count == 1,
                      "Root directory event should be handled gracefully")
    }
}
