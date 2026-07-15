import XCTest
@testable import WorkspaceSearch
import WorkspaceKitCSupport

final class PathSearchIndexTests: XCTestCase {
    
    // MARK: - Test Data
    
    let testPaths = [
        "src/components/FileViewController.swift",
        "src/components/SearchViewModel.swift",
        "src/utils/PathHelper.swift",
        "src/utils/StringExtensions.swift",
        "tests/FileViewControllerTests.swift",
        "tests/SearchViewModelTests.swift",
        "docs/README.md",
        "docs/API.md",
        "package.json",
        "tsconfig.json",
        "src/index.ts",
        "src/app.tsx",
        "src/components/Button.tsx",
        "src/components/Modal/Modal.tsx",
        "src/components/Modal/ModalHeader.tsx",
        "config/webpack.config.js",
        "scripts/build.sh",
        "scripts/deploy.sh",
        ".gitignore",
        ".github/workflows/ci.yml"
    ]
    
    // MARK: - Basic Search Tests
    
    func testEmptyIndex() async {
        let index = await PathSearchIndex(paths: [])
        let results = await index.search("test")
        XCTAssertEqual(results.count, 0)
        let count = await index.count
        XCTAssertEqual(count, 0)
    }
    
    func testSimpleSubstringSearch() async {
        let index = await PathSearchIndex(paths: testPaths)
        
        // Search for "View"
        let results = await index.search("View")
        XCTAssertEqual(results.count, 4) // FileViewController, SearchViewModel, and their tests
        
        let paths = results.map { $0.path }
        XCTAssertTrue(paths.contains("src/components/FileViewController.swift"))
        XCTAssertTrue(paths.contains("src/components/SearchViewModel.swift"))
        XCTAssertTrue(paths.contains("tests/FileViewControllerTests.swift"))
        XCTAssertTrue(paths.contains("tests/SearchViewModelTests.swift"))
    }
    
    func testCaseInsensitiveSearch() async {
        let index = await PathSearchIndex(paths: testPaths)
        
        let results1 = await index.search("modal")
        let results2 = await index.search("MODAL")
        let results3 = await index.search("Modal")
        
        XCTAssertEqual(results1.count, 2)
        XCTAssertEqual(results2.count, 2)
        XCTAssertEqual(results3.count, 2)
        
        let paths = results1.map { $0.path }
        XCTAssertTrue(paths.contains("src/components/Modal/Modal.tsx"))
        XCTAssertTrue(paths.contains("src/components/Modal/ModalHeader.tsx"))
    }
    
    // MARK: - File Extension Tests (Auto-detection removed)
    
    func testExplicitWildcardFileExtension() async {
        let index = await PathSearchIndex(paths: testPaths)
        
        // Test explicit "*.swift"
        let swiftResults = await index.search("*.swift")
        XCTAssertEqual(swiftResults.count, 6)
        for result in swiftResults {
            XCTAssertTrue(result.path.hasSuffix(".swift"))
        }
        
        // Test explicit "*.md"
        let mdResults = await index.search("*.md")
        XCTAssertEqual(mdResults.count, 2)
        for result in mdResults {
            XCTAssertTrue(result.path.hasSuffix(".md"))
        }
        
        // Test explicit "*.json"
        let jsonResults = await index.search("*.json")
        XCTAssertEqual(jsonResults.count, 2)
        for result in jsonResults {
            XCTAssertTrue(result.path.hasSuffix(".json"))
        }
    }
    
    func testLiteralDotSearch() async {
        let index = await PathSearchIndex(paths: testPaths)
        
        // Test that ".tsx" searches for literal ".tsx" substring
        let results = await index.search(".tsx")
        XCTAssertEqual(results.count, 4) // app.tsx, Button.tsx, Modal.tsx, ModalHeader.tsx
        for result in results {
            XCTAssertTrue(result.path.contains(".tsx"))
        }
    }
    
    // MARK: - Space Handling Tests (NEW)
    
    func testSpaceSeparatedTermsAsAND() async {
        let index = await PathSearchIndex(paths: testPaths)
        
        // Test "search model" matches SearchViewModel
        let results = await index.search("search model")
        let paths = results.map { $0.path }
        XCTAssertTrue(paths.contains("src/components/SearchViewModel.swift"))
        XCTAssertTrue(paths.contains("tests/SearchViewModelTests.swift"))
        
        // Should NOT match files with only one term
        XCTAssertEqual(results.count, 2) // Only files with both terms
    }
    
    func testMultipleSpacedTerms() async {
        let index = await PathSearchIndex(paths: testPaths)
        
        // Test three terms
        let results = await index.search("file view controller")
        let paths = results.map { $0.path }
        XCTAssertTrue(paths.contains("src/components/FileViewController.swift"))
        XCTAssertTrue(paths.contains("tests/FileViewControllerTests.swift"))
        XCTAssertEqual(results.count, 2)
    }
    
    // MARK: - Wildcard Pattern Tests
    
    func testWildcardPatterns() async {
        let index = await PathSearchIndex(paths: testPaths)
        
        // Test "src/*.swift"
        let results = await index.search("src/*.swift")
        XCTAssertEqual(results.count, 0) // Should be 0 because * doesn't match /
        
        // Test "src/**/*.swift"
        let deepResults = await index.search("src/**/*.swift")
        XCTAssertEqual(deepResults.count, 4)
        for result in deepResults {
            XCTAssertTrue(result.path.hasPrefix("src/"))
            XCTAssertTrue(result.path.hasSuffix(".swift"))
        }
        
        // Test "*.config.*"
        let configResults = await index.search("*.config.*")
        XCTAssertEqual(configResults.count, 1)
        if configResults.count > 0 {
            XCTAssertEqual(configResults[0].path, "config/webpack.config.js")
        }
    }
    
    func testQuestionMarkWildcard() async {
        let index = await PathSearchIndex(paths: testPaths)
        
        // Test "src/???.tsx" - matches app.tsx
        let results = await index.search("src/???.tsx")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].path, "src/app.tsx")
    }
    
    // MARK: - Short String Matching Tests
    
    func testShortStringMatching() async {
        let paths = ["docker-compose.yml", "Dockerfile", "docs/docker-setup.md"]
        let index = await PathSearchIndex(paths: paths)
        
        // "do" should match all docker-related files
        let results = await index.search("do")
        XCTAssertEqual(results.count, 3)
        
        // "doc" should also match all
        let docsResults = await index.search("doc")
        XCTAssertEqual(docsResults.count, 3)
    }
    
    // MARK: - Edge Cases
    
    func testEmptyPattern() async {
        let index = await PathSearchIndex(paths: testPaths)
        let results = await index.search("")
        XCTAssertEqual(results.count, testPaths.count) // Empty pattern matches all
    }
    
	func testSpecialCharacters() async {
		let index = await PathSearchIndex(paths: testPaths)
		
		// Test paths with dots
		let results = await index.search(".gitignore")
		XCTAssertEqual(results.count, 1)
		XCTAssertEqual(results[0].path, ".gitignore")
		
		// Test paths with slashes
		let githubResults = await index.search(".github")
		XCTAssertEqual(githubResults.count, 1)
		XCTAssertEqual(githubResults[0].path, ".github/workflows/ci.yml")
	}
	
	func testSearchWithLiteralParentheses() async {
		let paths = [
			"/root/src/features/Feature(Foo)/index.ts",
			"/root/src/features/FeatureBar/index.ts",
			"/root/docs/Guides (v2)/Intro.md"
		]
		let index = await PathSearchIndex(paths: paths)
		let hits = await index.search("Feature(Foo)", limit: 10)
		let hitPaths = hits.map(\.path)
		XCTAssertTrue(hitPaths.contains("/root/src/features/Feature(Foo)/index.ts"))
	}
    
    func testLongPatterns() async {
        let index = await PathSearchIndex(paths: testPaths)
        
        // Test exact path match
        let results = await index.search("src/components/FileViewController.swift")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].path, "src/components/FileViewController.swift")
    }
    
    func testSpaceSeparatedWordsMatching() async {
        // Test the specific case mentioned: "project transport plan tractor" 
        // should match "app/models/project_transport_plan_tractor.rb"
        let testPaths = [
            "app/models/project_transport_plan_tractor.rb",
            "app/models/project_transport_tractor.rb",  // Missing "plan"
            "app/models/transport_plan_tractor.rb",     // Missing "project"
            "app/models/project_plan_tractor.rb",       // Missing "transport"
            "app/models/project_transport_plan.rb",     // Missing "tractor"
            "app/controllers/project_transport_plan_tractor_controller.rb",
            "spec/models/project_transport_plan_tractor_spec.rb",
            "app/models/unrelated_model.rb"
        ]
        
        let index = await PathSearchIndex(paths: testPaths)
        
        // Search with space-separated terms
        let results = await index.search("project transport plan tractor")
        
        // Should find all paths containing all four terms
        XCTAssertEqual(results.count, 3)
        
        let resultPaths = results.map { $0.path }
        XCTAssertTrue(resultPaths.contains("app/models/project_transport_plan_tractor.rb"))
        XCTAssertTrue(resultPaths.contains("app/controllers/project_transport_plan_tractor_controller.rb"))
        XCTAssertTrue(resultPaths.contains("spec/models/project_transport_plan_tractor_spec.rb"))
        
        // Should not find paths missing any term
        XCTAssertFalse(resultPaths.contains("app/models/project_transport_tractor.rb"))
        XCTAssertFalse(resultPaths.contains("app/models/transport_plan_tractor.rb"))
        XCTAssertFalse(resultPaths.contains("app/models/project_plan_tractor.rb"))
        XCTAssertFalse(resultPaths.contains("app/models/project_transport_plan.rb"))
        XCTAssertFalse(resultPaths.contains("app/models/unrelated_model.rb"))
        
        // Test partial matches to ensure each individual term works
        let projectResults = await index.search("project")
        XCTAssertGreaterThanOrEqual(projectResults.count, 6) // All with "project"
        
        let tractorResults = await index.search("tractor")
        XCTAssertGreaterThanOrEqual(tractorResults.count, 6) // All with "tractor"
    }
    
    // MARK: - Performance Tests
    
    func testLargeIndexPerformance() async {
        // Generate 10,000 paths
        var largePaths: [String] = []
        for i in 0..<10000 {
            largePaths.append("src/components/Component\(i).swift")
            largePaths.append("tests/Component\(i)Tests.swift")
        }
        
        // Measure index creation time
        let startBuild = Date()
        let index = await PathSearchIndex(paths: largePaths)
        let buildTime = Date().timeIntervalSince(startBuild)
        print("Index build time for 20k paths: \(buildTime)s")
        XCTAssertLessThan(buildTime, 1.0) // Should build in under 1 second
        
        // Measure search time
        let startSearch = Date()
        let results = await index.search("Component123")
        let searchTime = Date().timeIntervalSince(startSearch)
        print("Search time: \(searchTime)s")
        XCTAssertLessThan(searchTime, 0.02) // Adjusted to 20ms for safety
        // Will find Component123, Component1123, Component1230-1239, etc.
        // Any path containing "123" will match
        XCTAssertGreaterThan(results.count, 2) // Will find many matches
        
        // Verify it at least found the expected ones
        let paths = results.map { $0.path }
        XCTAssertTrue(paths.contains("src/components/Component123.swift"))
        XCTAssertTrue(paths.contains("tests/Component123Tests.swift"))
    }
    
    // MARK: - Index Lifecycle Tests
    
    func testIndexRebuild() async {
        let index = PathSearchIndex()
        
        // Initially empty
        let count1 = await index.count
        XCTAssertEqual(count1, 0)
        
        // Build with first set
        await index.rebuild(paths: ["file1.swift", "file2.swift"])
        let count2 = await index.count
        XCTAssertEqual(count2, 2)
        
        // Rebuild with new set
        await index.rebuild(paths: ["file3.swift", "file4.swift", "file5.swift"])
        let count3 = await index.count
        XCTAssertEqual(count3, 3)
        
        // Search should only find new files
        let results = await index.search("file")
        XCTAssertEqual(results.count, 3)
        let paths = results.map { $0.path }
        XCTAssertTrue(paths.contains("file3.swift"))
        XCTAssertTrue(paths.contains("file4.swift"))
        XCTAssertTrue(paths.contains("file5.swift"))
        XCTAssertFalse(paths.contains("file1.swift"))
        XCTAssertFalse(paths.contains("file2.swift"))
    }
    
    func testClearIndex() async {
        let index = await PathSearchIndex(paths: testPaths)
        let count1 = await index.count
        XCTAssertGreaterThan(count1, 0)
        
        await index.rebuild(paths: [])
        let count2 = await index.count
        XCTAssertEqual(count2, 0)
        
        let results = await index.search("test")
        XCTAssertEqual(results.count, 0)
    }
    
    // MARK: - Result Properties Tests
    
    func testResultProperties() async {
        let index = await PathSearchIndex(paths: testPaths)
        let results = await index.search("Modal.tsx")
        
        XCTAssertGreaterThan(results.count, 0)
        
        let result = results[0]
        XCTAssertEqual(result.filename, "Modal.tsx")
        XCTAssertEqual(result.path, "src/components/Modal/Modal.tsx")
        XCTAssertGreaterThanOrEqual(result.index, 0)
        XCTAssertLessThan(result.index, testPaths.count)
        
        // Verify index points to correct path
        let pathAtIndex = await index.path(at: result.index)
        XCTAssertEqual(pathAtIndex, result.path)
        
        let filenameAtIndex = await index.filename(at: result.index)
        XCTAssertEqual(filenameAtIndex, result.filename)
    }
    
    // MARK: - Limit Tests
    
    func testSearchLimit() async {
        // Create many matching paths
        var manyPaths: [String] = []
        for i in 0..<1000 {
            manyPaths.append("test/file\(i).swift")
        }
        
        let index = await PathSearchIndex(paths: manyPaths)
        
        // Default limit
        let defaultResults = await index.search("test")
        XCTAssertEqual(defaultResults.count, 300) // Default limit
        
        // Custom limit
        let limitedResults = await index.search("test", limit: 50)
        XCTAssertEqual(limitedResults.count, 50)
        
        // Large limit
        let unlimitedResults = await index.search("test", limit: 2000)
        XCTAssertEqual(unlimitedResults.count, 1000) // All matches
    }
}

// MARK: - Test Helpers

extension PathSearchIndexTests {
    func assertPathsContain(_ results: [PathSearchIndex.Candidate], paths: [String]) {
        let resultPaths = Set(results.map { $0.path })
        for path in paths {
            XCTAssertTrue(resultPaths.contains(path), "Expected to find \(path) in results")
        }
    }
    
    func assertPathsDoNotContain(_ results: [PathSearchIndex.Candidate], paths: [String]) {
        let resultPaths = Set(results.map { $0.path })
        for path in paths {
            XCTAssertFalse(resultPaths.contains(path), "Did not expect to find \(path) in results")
        }
    }
}
