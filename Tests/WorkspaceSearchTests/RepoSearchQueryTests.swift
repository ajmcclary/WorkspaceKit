import XCTest
@testable import WorkspaceSearch
import WorkspaceKitCSupport

final class RepoSearchQueryTests: XCTestCase {
	func testFactoryStripsWildcardsWhenDisabled() {
		let query = RepoSearchQueryFactory.make("  foo*bar?  ", supportsWildcards: false)
		XCTAssertEqual(query.raw, "foobar")
		XCTAssertEqual(query.lowered, "foobar")
		XCTAssertFalse(query.isWildcard)
	}

	func testFactoryPreservesWildcardsWhenEnabled() {
		let query = RepoSearchQueryFactory.make("  foo*bar?  ", supportsWildcards: true)
		XCTAssertEqual(query.raw, "foo*bar?")
		XCTAssertTrue(query.isWildcard)
	}

	func testFactoryAppliesMaxLength() {
		let query = RepoSearchQueryFactory.make(String(repeating: "a", count: 10), maxLength: 4)
		XCTAssertEqual(query.raw, "aaaa")
	}
}
