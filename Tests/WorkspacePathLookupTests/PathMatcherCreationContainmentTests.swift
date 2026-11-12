import XCTest
@testable import WorkspacePathLookup

/// A relative creation path must never resolve to components that climb out of
/// the chosen root. `..` that would leave the root makes the path unresolvable;
/// `..` that stays inside the root is collapsed before matching.
@MainActor
final class PathMatcherCreationContainmentTests: XCTestCase {

	private func makeSnapshot() async -> PathMatchSnapshot {
		await PathMatcherTestHelper.makeSnapshot(
			files: [("src/existing.swift", "/work/app")],
			folders: [("src", "/work/app")]
		)
	}

	func testRelativeCreationPathThatClimbsAboveTheRootIsRejected() async {
		let snapshot = await makeSnapshot()
		for input in ["../../escaped/evil.txt", "../evil.txt", "src/../../via-src.txt", "app/../../alias-escape.txt", "app/src/../../../x.txt"] {
			XCTAssertNil(PathMatcher.findCreationPath(userPath: input, snapshot: snapshot), "bestEffort accepted \(input)")
			XCTAssertNil(
				PathMatcher.resolveCreationPath(userPath: input, snapshot: snapshot, mode: .requireUnambiguous),
				"requireUnambiguous accepted \(input)"
			)
			XCTAssertNil(
				PathMatcher.resolveCreationPath(userPath: input, snapshot: snapshot, mode: .bestEffort),
				"resolveCreationPath(.bestEffort) accepted \(input)"
			)
		}
	}

	func testParentTraversalThatStaysInsideTheRootIsCollapsed() async {
		let snapshot = await makeSnapshot()
		let result = PathMatcher.findCreationPath(userPath: "src/../lib/new.swift", snapshot: snapshot)
		XCTAssertEqual(result?.rootFolder.fullPath, "/work/app")
		XCTAssertEqual(result?.componentsToCreate, ["lib", "new.swift"])
	}

	func testNoCreationResultEverContainsParentOrCurrentDirectoryComponents() async {
		let snapshot = await makeSnapshot()
		for input in ["./src/./a.swift", "src/x/../b.swift", "app/./src/c.swift"] {
			guard let result = PathMatcher.findCreationPath(userPath: input, snapshot: snapshot) else { continue }
			XCTAssertFalse(result.componentsToCreate.contains(".."), "\(input) -> \(result.componentsToCreate)")
			XCTAssertFalse(result.componentsToCreate.contains("."), "\(input) -> \(result.componentsToCreate)")
		}
	}
}
