import XCTest
@testable import WorkspacePathLookup

@MainActor
final class PathMatcherFileCreationAliasPriorityTests: XCTestCase {
	func testAliasPriority_DeepFolderUnderOtherRoot() async {
		// Alias root 'NewTestDir' exists and another root contains a real folder 'NewTestDir/src'.
		// Creation should prioritize the alias root and treat the leading component as root alias.
		let snapshot = await PathMatcherTestHelper.makeSnapshot(
			files: [],
			folders: [
				("NewTestDir/src", "/Users/test/BombSquad"),
				("", "/Users/test/NewTestDir")
			]
		)
		let result = PathMatcher.findCreationPath(userPath: "NewTestDir/src/NewFile.swift", snapshot: snapshot)
		XCTAssertNotNil(result)
		XCTAssertEqual(result?.rootFolder.fullPath, "/Users/test/NewTestDir")
		XCTAssertEqual(result?.componentsToCreate, ["src", "NewFile.swift"])
	}

	func testAliasPriority_IgnoresSelectedRootBias() async {
		// Even if another root has selected files, alias root must win for creation
		let snapshot = await PathMatcherTestHelper.makeSnapshot(
			files: [],
			folders: [
				("NewTestDir", "/Users/test/BombSquad"),
				("", "/Users/test/NewTestDir")
			],
			selectedFiles: ["/Users/test/BombSquad/selected.txt"]
		)
		let result = PathMatcher.findCreationPath(userPath: "NewTestDir/abc.txt", snapshot: snapshot)
		XCTAssertNotNil(result)
		XCTAssertEqual(result?.rootFolder.fullPath, "/Users/test/NewTestDir")
		XCTAssertEqual(result?.componentsToCreate, ["abc.txt"])
	}

	func testAliasPriority_CaseInsensitiveAlias() async {
		// Alias matching should be case-insensitive
		let snapshot = await PathMatcherTestHelper.makeSnapshot(
			files: [],
			folders: [
				("NewTestDir", "/Users/test/BombSquad"),
				("", "/Users/test/NewTestDir")
			]
		)
		let result = PathMatcher.findCreationPath(userPath: "nEwTeStDiR/Mixed.txt", snapshot: snapshot)
		XCTAssertNotNil(result)
		XCTAssertEqual(result?.rootFolder.fullPath, "/Users/test/NewTestDir")
		XCTAssertEqual(result?.componentsToCreate, ["Mixed.txt"])
	}
}
