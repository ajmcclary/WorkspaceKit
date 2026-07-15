import XCTest
@testable import WorkspaceFileSystem
@testable import WorkspaceIgnore

final class FileSystemServiceFSEventsCallbackTests: XCTestCase {
	func testDeepCopiedEventPathDetachesFromMutableNSStringBacking() throws {
		let source = NSMutableString(string: "/tmp/original.swift")
		let copied = try XCTUnwrap(FileSystemService.deepCopiedEventPathForTesting(source))

		source.setString("/tmp/mutated.swift")

		XCTAssertEqual(copied, "/tmp/original.swift")
	}

	func testBuildOwnedFSEventPayloadDropsInvalidElementsWithoutMisaligningFlagsAndIDs() throws {
		let mutable = NSMutableString(string: "/tmp/one.swift")
		let payload = try XCTUnwrap(
			FileSystemService.buildOwnedFSEventPayloadFromCFArrayForTesting(
				pathObjects: [mutable, NSNumber(value: 7), NSString(string: "/tmp/two.swift")],
				flags: [
					FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
					FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved),
					FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
				],
				ids: [11, 22, 33]
			)
		)

		mutable.setString("/tmp/changed.swift")

		XCTAssertEqual(payload.paths, ["/tmp/one.swift", "/tmp/two.swift"])
		XCTAssertEqual(
			payload.flags,
			[
				FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
				FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
			]
		)
		XCTAssertEqual(payload.ids, [11, 33])
	}

	func testBuildOwnedFSEventPayloadPreservesUnicodePaths() throws {
		let payload = try XCTUnwrap(
			FileSystemService.buildOwnedFSEventPayloadFromCFArrayForTesting(
				pathObjects: [
					NSString(string: "/tmp/naïve/日本語.swift"),
					NSString(string: "/tmp/emoji-🧪.txt")
				],
				flags: [
					FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
					FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
				],
				ids: [101, 102]
			)
		)

		XCTAssertEqual(payload.paths, ["/tmp/naïve/日本語.swift", "/tmp/emoji-🧪.txt"])
		XCTAssertEqual(payload.ids, [101, 102])
	}

	func testMapRelativeEventPathForTestingKeepsRootAndNestedPathsInsideRoot() async throws {
		let testPath = "/tmp/test-fsevent-path-mapping"
		let virtualFS = InMemoryFS()
		virtualFS.addFolder(testPath)
		virtualFS.addFolder("\(testPath)/src")
		let service = try await FileSystemService(
			path: testPath,
			respectGitignore: true,
			skipSymlinks: true,
			isTestMode: true,
			fileManagerOverride: virtualFS
		)

		let rootResult = await service.mapRelativeEventPathForTesting(testPath)
		XCTAssertTrue(rootResult.isInside)
		XCTAssertEqual(rootResult.value, "")

		let nestedResult = await service.mapRelativeEventPathForTesting("\(testPath)//src/file.swift/")
		XCTAssertTrue(nestedResult.isInside)
		XCTAssertEqual(nestedResult.value, "src/file.swift")

		let outsideResult = await service.mapRelativeEventPathForTesting("/tmp/other/outside.swift")
		XCTAssertFalse(outsideResult.isInside)
		XCTAssertEqual(outsideResult.value, "/tmp/other/outside.swift")
	}
}
