import XCTest
@testable import WorkspaceIgnore

/// Patterns in a nested ignore file apply only below that file's directory.
/// A slash-free pattern such as `lib/` in `lib/mypkg/.gitignore` matches
/// `lib` directories at any depth *under* `lib/mypkg`, never the ancestor
/// `lib` the file itself lives in (Git semantics).
final class NestedIgnoreFileScopeTests: XCTestCase {

	private struct StaticProvider: HierarchicalIgnoreEvaluator.RulesProvider {
		let rulesByDirectory: [String: IgnoreRules]
		func rulesForDirectory(_ directoryPath: String) async throws -> IgnoreRules {
			var path = directoryPath
			while true {
				if let rules = rulesByDirectory[path] { return rules }
				if path.isEmpty { return IgnoreRules() }
				path = (path as NSString).deletingLastPathComponent
			}
		}
	}

	private func rules(nestedAt directory: String, content: String) -> IgnoreRules {
		let rules = IgnoreRules()
		rules.addIgnoreFile(content: content, priority: 1, directoryPath: directory)
		return rules
	}

	func testSlashFreeDirectoryPatternDoesNotMatchTheAncestorItLivesIn() {
		let python = rules(nestedAt: "lib/mypkg", content: "lib/\nbuild/\ndist/\n")
		XCTAssertFalse(python.isIgnored(relativePath: "lib/mypkg/src/main.py", isDirectory: false))
		XCTAssertFalse(python.isIgnored(relativePath: "lib/mypkg/src", isDirectory: true))
		XCTAssertTrue(python.isIgnored(relativePath: "lib/mypkg/lib", isDirectory: true))
		XCTAssertTrue(python.isIgnored(relativePath: "lib/mypkg/lib/vendored.py", isDirectory: false))
		XCTAssertTrue(python.isIgnored(relativePath: "lib/mypkg/src/lib/deep.py", isDirectory: false))
		XCTAssertTrue(python.isIgnored(relativePath: "lib/mypkg/dist/pkg.whl", isDirectory: false))

		let gradle = rules(nestedAt: "build/android", content: "build/\n")
		XCTAssertFalse(gradle.isIgnored(relativePath: "build/android/app/Main.kt", isDirectory: false))
		XCTAssertTrue(gradle.isIgnored(relativePath: "build/android/app/build/out.class", isDirectory: false))
	}

	func testSlashFreeFilePatternsMatchOnlyBelowTheIgnoreFile() {
		let nested = rules(nestedAt: "pkg", content: "*.log\nsecret.txt\n!keep.log\n")
		XCTAssertTrue(nested.isIgnored(relativePath: "pkg/a.log", isDirectory: false))
		XCTAssertTrue(nested.isIgnored(relativePath: "pkg/sub/b.log", isDirectory: false))
		XCTAssertTrue(nested.isIgnored(relativePath: "pkg/sub/secret.txt", isDirectory: false))
		XCTAssertFalse(nested.isIgnored(relativePath: "pkg/keep.log", isDirectory: false))
		XCTAssertFalse(nested.isIgnored(relativePath: "other/a.log", isDirectory: false))
		XCTAssertFalse(nested.isIgnored(relativePath: "a.log", isDirectory: false))
	}

	func testRootIgnoreFileIsUnchanged() {
		let root = rules(nestedAt: "", content: "lib/\n*.log\n")
		XCTAssertTrue(root.isIgnored(relativePath: "lib/x.py", isDirectory: false))
		XCTAssertTrue(root.isIgnored(relativePath: "a/b/lib/x.py", isDirectory: false))
		XCTAssertTrue(root.isIgnored(relativePath: "a/b/c.log", isDirectory: false))
	}

	func testHierarchicalEvaluatorKeepsTheNestedPackageSource() async throws {
		let root = IgnoreRules()
		let nested = rules(nestedAt: "lib/mypkg", content: "lib/\n")
		let evaluator = HierarchicalIgnoreEvaluator(rulesProvider: StaticProvider(rulesByDirectory: [
			"": root,
			"lib/mypkg": nested
		]))
		let source = try await evaluator.isIgnored(relativePath: "lib/mypkg/src/main.py", isDirectory: false)
		XCTAssertFalse(source)
		let vendored = try await evaluator.isIgnored(relativePath: "lib/mypkg/lib/vendored.py", isDirectory: false)
		XCTAssertTrue(vendored)
	}
}
