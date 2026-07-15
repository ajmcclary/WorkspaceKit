import XCTest
@testable import WorkspacePathLookup

final class PathMatcherHeadTrimTests: XCTestCase {
    
    // MARK: - Head Trim Tests
    
    func testHeadTrimWithExtraPrefixPath() async {
        // Test case: user provides "pathA/pathB/loadedRoot/src/file.txt"
        // where "loadedRoot" is an actual loaded root, and the file is at "src/file.txt"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/file.txt", "/Users/test/loadedRoot"),
            ("src/other.txt", "/Users/test/loadedRoot"),
            ("docs/readme.md", "/Users/test/loadedRoot")
        ])
        
        // The path has extra prefix components before the actual root name
        PathMatcherTestHelper.assertResolves("pathA/pathB/loadedRoot/src/file.txt", to: "src/file.txt", in: snapshot)
        PathMatcherTestHelper.assertResolves("some/random/prefix/loadedRoot/src/other.txt", to: "src/other.txt", in: snapshot)
        PathMatcherTestHelper.assertResolves("extra/loadedRoot/docs/readme.md", to: "docs/readme.md", in: snapshot)
    }
    
    func testHeadTrimWithMultipleRoots() async {
        // Test with multiple roots where the path prefix could match different roots
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/app.js", "/Users/test/frontend"),
            ("src/server.js", "/Users/test/backend"),
            ("src/shared.js", "/Users/test/common")
        ])
        
        // Path with prefix that includes a root name
        PathMatcherTestHelper.assertResolves("old/frontend/src/app.js", to: "src/app.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("legacy/code/backend/src/server.js", to: "src/server.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("archive/common/src/shared.js", to: "src/shared.js", in: snapshot)
    }
    
    func testHeadTrimWithNestedRootNames() async {
        // Test when path contains multiple segments that match root names
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("components/Button.tsx", "/Users/test/web"),
            ("utils/helper.js", "/Users/test/web"),
            ("tests/web/components/test.js", "/Users/test/testing")
        ])
        
        // "testing/web/components/Button.tsx" should NOT match web's Button.tsx
        // because "testing" is also a root, it should look in testing root
        PathMatcherTestHelper.assertResolves("testing/tests/web/components/test.js", to: "tests/web/components/test.js", in: snapshot)
        
        // But "random/web/components/Button.tsx" should match web's Button.tsx
        // because "random" is not a root
        PathMatcherTestHelper.assertResolves("random/web/components/Button.tsx", to: "components/Button.tsx", in: snapshot)
    }
    
    func testHeadTrimWithAmbiguousRootNames() async {
        // Test when the root name appears multiple times in the path
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/project/config.json", "/Users/test/project"),
            ("project/settings.json", "/Users/test/project"),
            ("data/project/info.txt", "/Users/test/project")
        ])
        
        // "old/project/src/project/config.json" should resolve correctly
        PathMatcherTestHelper.assertResolves("old/project/src/project/config.json", to: "src/project/config.json", in: snapshot)
        
        // "backup/project/project/settings.json" should resolve correctly
        PathMatcherTestHelper.assertResolves("backup/project/project/settings.json", to: "project/settings.json", in: snapshot)
    }
    
    func testHeadTrimWithSimilarButNotExactRootNames() async {
        // Test that head trimming only works with exact root name matches (case-insensitive)
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/main.swift", "/Users/test/MyProject"),
            ("lib/helper.swift", "/Users/test/MyProject")
        ])
        
        // Should work with exact match (case-insensitive)
        PathMatcherTestHelper.assertResolves("old/MyProject/src/main.swift", to: "src/main.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("old/myproject/src/main.swift", to: "src/main.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("old/MYPROJECT/src/main.swift", to: "src/main.swift", in: snapshot)
        
        // Should NOT work with partial matches
        PathMatcherTestHelper.assertResolves("old/MyProj/src/main.swift", to: nil, exactMatchOnly: true, in: snapshot)
        PathMatcherTestHelper.assertResolves("old/Project/src/main.swift", to: nil, exactMatchOnly: true, in: snapshot)
    }
    
    func testHeadTrimWithRootNameAsFirstComponent() async {
        // Test the interaction between alias root detection and head trimming
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/app.js", "/Users/test/frontend"),
            ("src/styles.css", "/Users/test/frontend")
        ])
        
        // "frontend/src/app.js" should work (alias root detection)
        PathMatcherTestHelper.assertResolves("frontend/src/app.js", to: "src/app.js", in: snapshot)
        
        // "path/to/frontend/src/app.js" should also work (head trimming)
        PathMatcherTestHelper.assertResolves("path/to/frontend/src/app.js", to: "src/app.js", in: snapshot)
        
        // Both should resolve to the same file
        let result1 = PathMatcherTestHelper.getResolvedPath("frontend/src/app.js", in: snapshot)
        let result2 = PathMatcherTestHelper.getResolvedPath("path/to/frontend/src/app.js", in: snapshot)
        XCTAssertEqual(result1, result2)
    }
    
    func testHeadTrimPreservesRootBias() async {
        // Test that head trimming respects the root bias when found
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("config.json", "/Users/test/projectA"),
            ("config.json", "/Users/test/projectB"),
            ("src/config.json", "/Users/test/projectA"),
            ("src/config.json", "/Users/test/projectB")
        ])
        
        // When head-trimming finds a specific root, it should only look in that root
        PathMatcherTestHelper.assertResolves("old/path/projectA/config.json", to: "config.json", in: snapshot)
        PathMatcherTestHelper.assertResolves("old/path/projectB/config.json", to: "config.json", in: snapshot)
        PathMatcherTestHelper.assertResolves("archive/projectA/src/config.json", to: "src/config.json", in: snapshot)
        PathMatcherTestHelper.assertResolves("archive/projectB/src/config.json", to: "src/config.json", in: snapshot)
        
        // Verify the files are from the correct roots
        let resultA = PathMatcher.locate(userPath: "old/path/projectA/config.json", snapshot: snapshot)
        let resultB = PathMatcher.locate(userPath: "old/path/projectB/config.json", snapshot: snapshot)
        XCTAssertTrue(resultA?.rootPath.contains("projectA") ?? false)
        XCTAssertTrue(resultB?.rootPath.contains("projectB") ?? false)
    }
    
    func testHeadTrimWithDeepPaths() async {
        // Test head trimming with very deep paths
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/components/ui/buttons/PrimaryButton.tsx", "/Users/test/webapp"),
            ("src/components/ui/buttons/SecondaryButton.tsx", "/Users/test/webapp")
        ])
        
        // Very deep prefix before the root name
        PathMatcherTestHelper.assertResolves(
            "backup/2024/january/old/projects/webapp/src/components/ui/buttons/PrimaryButton.tsx",
            to: "src/components/ui/buttons/PrimaryButton.tsx",
            in: snapshot
        )
    }
    
    func testHeadTrimWithParentFolderCheck() async {
        // Test that head trimming works with the parent-folder optimization
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("utils/StringHelper.java", "/Users/test/project"),
            ("utils/NumberHelper.java", "/Users/test/project"),
            ("tests/StringHelperTest.java", "/Users/test/project")
        ])
        
        // Path with prefix that should trigger parent-folder check after head-trim
        PathMatcherTestHelper.assertResolves("old/code/project/utils/StringHelper.java", to: "utils/StringHelper.java", in: snapshot)
        PathMatcherTestHelper.assertResolves("archive/project/utils/NumberHelper.java", to: "utils/NumberHelper.java", in: snapshot)
    }
    
    func testHeadTrimDoesNotBreakNormalMatching() async {
        // Ensure that head trimming doesn't interfere with normal path matching
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/main.swift", "/Users/test/app"),
            ("tests/mainTests.swift", "/Users/test/app")
        ])
        
        // Normal matching should still work
        PathMatcherTestHelper.assertResolves("src/main.swift", to: "src/main.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("main.swift", to: "src/main.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("/Users/test/app/src/main.swift", to: "src/main.swift", in: snapshot)
        
        // Head trim matching should also work
        PathMatcherTestHelper.assertResolves("old/app/src/main.swift", to: "src/main.swift", in: snapshot)
    }
    
    func testHeadTrimWithNoMatchingRoot() async {
        // Test that paths with no matching root name don't cause issues
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/file.txt", "/Users/test/project")
        ])
        
        // Path with components that don't match any root name
        PathMatcherTestHelper.assertResolves("random/path/src/file.txt", to: nil, exactMatchOnly: true, in: snapshot)
        
        // But fuzzy matching might still find it
        let fuzzyResult = PathMatcherTestHelper.getResolvedPath("random/path/src/file.txt", in: snapshot)
        // Fuzzy match might find "src/file.txt" based on suffix matching
        XCTAssertTrue(fuzzyResult == nil || fuzzyResult == "src/file.txt")
    }
    
    func testHeadTrimWithDuplicateRootNames() async {
        // Two different roots share the same lastPathComponent (case-insensitive): "project" vs "Project"
        // This used to crash when building a Dictionary with duplicate keys.
        let rootA = "/Users/test/a/project"
        let rootB = "/Users/test/b/Project" // same name differing only by case

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/app.swift", rootA),
            ("src/main.swift", rootB)
        ])

        // Head-trim should generate variants for each matching root name without crashing,
        // and resolve to the file that actually exists in the corresponding root.
        PathMatcherTestHelper.assertResolves("random/prefix/project/src/main.swift", to: "src/main.swift", in: snapshot)
        let resultMain = PathMatcher.locate(userPath: "random/prefix/project/src/main.swift", snapshot: snapshot)
        XCTAssertEqual(resultMain?.rootPath, rootB)

        PathMatcherTestHelper.assertResolves("old/path/project/src/app.swift", to: "src/app.swift", in: snapshot)
        let resultApp = PathMatcher.locate(userPath: "old/path/project/src/app.swift", snapshot: snapshot)
        XCTAssertEqual(resultApp?.rootPath, rootA)
    }

    func testHeadTrimWithEmptyPathAfterRoot() async {
        // Test edge case where nothing comes after the root name
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("README.md", "/Users/test/docs"),
            ("index.html", "/Users/test/docs")
        ])
        
        // These should not match anything as there's no file path after root
        PathMatcherTestHelper.assertResolves("old/path/docs", to: nil, exactMatchOnly: true, in: snapshot)
        PathMatcherTestHelper.assertResolves("archive/docs/", to: nil, exactMatchOnly: true, in: snapshot)
    }
}
