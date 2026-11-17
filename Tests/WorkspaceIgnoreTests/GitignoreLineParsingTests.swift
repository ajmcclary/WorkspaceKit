import XCTest
@testable import WorkspaceIgnore

/// Line parsing and pattern escapes follow Git: leading whitespace is part of
/// the pattern, a backslash escapes the next character, and long rules keep
/// their full pattern.
final class GitignoreLineParsingTests: XCTestCase {

	private func rules(_ content: String) -> CompiledIgnoreRules {
		GitignoreCompiler.compile(content: content)
	}

	func testCanonicalSpellingsKeepTheirOwnPatternBytes() {
		let rules = ["normalization-caf\u{e9}.txt", "normalization-cafe\u{301}.txt"]
		for rule in rules {
			XCTAssertTrue(GitignoreCompiler.compile(content: rule).denies(rule, isDirectory: false))
		}
	}

	func testLeadingWhitespaceIsPartOfThePattern() {
		let compiled = rules("  build\n\t#notacomment\n")
		XCTAssertFalse(compiled.denies("build", isDirectory: true), "Git does not strip leading whitespace")
		XCTAssertTrue(compiled.denies("  build", isDirectory: true))
		XCTAssertTrue(compiled.denies("\t#notacomment", isDirectory: false))
	}

	func testBackslashEscapesTheNextCharacter() {
		let compiled = rules("\\*.txt\nlit\\?\n")
		XCTAssertTrue(compiled.denies("*.txt", isDirectory: false))
		XCTAssertFalse(compiled.denies("notes.txt", isDirectory: false), "\\* is a literal star")
		XCTAssertTrue(compiled.denies("lit?", isDirectory: false))
		XCTAssertFalse(compiled.denies("lita", isDirectory: false), "\\? is a literal question mark")
	}

	func testLongLineDoesNotBecomeItsTruncatedPrefix() {
		let kept = String(repeating: "x", count: 1_023)
		let compiled = rules(kept + "-and-more-that-does-not-fit\nother.log\n")
		XCTAssertFalse(compiled.denies(kept, isDirectory: false), "a truncated prefix became its own pattern")
		XCTAssertTrue(compiled.denies("other.log", isDirectory: false), "later lines still apply")
	}

	func testLongPatternMatchesALegalFileName() {
		let pattern = String(repeating: "[a-z]", count: 210) + ".txt"
		let filename = String(repeating: "a", count: 210) + ".txt"
		XCTAssertTrue(rules(pattern).denies(filename, isDirectory: false))
		let nested = GitignoreCompiler.compile(content: pattern, directoryPath: "nested")
		XCTAssertTrue(nested.denies("nested/" + filename, isDirectory: false))
		XCTAssertFalse(nested.denies(filename, isDirectory: false))
	}

	func testExistingSemanticsAreUnchanged() {
		let compiled = rules("# comment\n\\#hash\n\\!bang\n*.log\ntrailing   \nescaped\\ \n")
		XCTAssertTrue(compiled.denies("#hash", isDirectory: false))
		XCTAssertTrue(compiled.denies("!bang", isDirectory: false))
		XCTAssertTrue(compiled.denies("a/b/c.log", isDirectory: false))
		XCTAssertTrue(compiled.denies("trailing", isDirectory: false))
		XCTAssertTrue(compiled.denies("escaped ", isDirectory: false))
	}
}
