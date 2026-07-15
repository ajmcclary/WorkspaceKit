import XCTest
@testable import WorkspacePathLookup

final class PathMatcherBasicTests: XCTestCase {
    
    // MARK: - Single Root Tests
    
    func testSingleRootDirectMatch() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/main.swift", "/Users/test/project"),
            ("src/utils/helper.swift", "/Users/test/project"),
            ("README.md", "/Users/test/project")
        ])
        
        // Relative path - exact match
        PathMatcherTestHelper.assertResolves("src/main.swift", to: "src/main.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("README.md", to: "README.md", in: snapshot)
        PathMatcherTestHelper.assertResolves("src/utils/helper.swift", to: "src/utils/helper.swift", in: snapshot)
        
        // Absolute path - exact match
        PathMatcherTestHelper.assertResolves("/Users/test/project/src/main.swift", to: "src/main.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("/Users/test/project/README.md", to: "README.md", in: snapshot)
    }
    
    func testSingleRootNoMatch() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/main.swift", "/Users/test/project")
        ])
        
        // Non-existent files
        PathMatcherTestHelper.assertResolves("src/missing.swift", to: nil, exactMatchOnly: true, in: snapshot)
        PathMatcherTestHelper.assertResolves("missing/path.txt", to: nil, exactMatchOnly: true, in: snapshot)
    }
    
    func testSingleRootPartialPathMatch() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/utils/helper.swift", "/Users/test/project"),
            ("src/models/user.swift", "/Users/test/project")
        ])
        
        // Just the filename should match with fuzzy
        PathMatcherTestHelper.assertResolves("helper.swift", to: "src/utils/helper.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("user.swift", to: "src/models/user.swift", in: snapshot)
        
        // Partial path should match
        PathMatcherTestHelper.assertResolves("utils/helper.swift", to: "src/utils/helper.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("models/user.swift", to: "src/models/user.swift", in: snapshot)
    }
    
    // MARK: - Multi Root Tests
    
    func testMultiRootDistinctFiles() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("frontend/app.js", "/Users/test/web"),
            ("backend/server.py", "/Users/test/api"),
            ("docs/README.md", "/Users/test/content")
        ])
        
        // Each file should resolve correctly
        PathMatcherTestHelper.assertResolves("frontend/app.js", to: "frontend/app.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("backend/server.py", to: "backend/server.py", in: snapshot)
        PathMatcherTestHelper.assertResolves("docs/README.md", to: "docs/README.md", in: snapshot)
        
        // Just filenames should work
        PathMatcherTestHelper.assertResolves("app.js", to: "frontend/app.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("server.py", to: "backend/server.py", in: snapshot)
    }
    
    func testRelativePathWithCollapsibleTraversalStillResolves() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("main.swift", "/Users/test/project")
        ])

        PathMatcherTestHelper.assertResolves("src/../main.swift", to: "main.swift", in: snapshot)
    }

    func testSnapshotNormalizesNonStandardizedStoredPaths() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/main.swift", "/Users/test/project/./Sources/..")
        ])

        PathMatcherTestHelper.assertResolves("src/main.swift", to: "src/main.swift", in: snapshot)
        let result = PathMatcher.locate(userPath: "src/main.swift", snapshot: snapshot)
        XCTAssertEqual(result?.rootPath, "/Users/test/project")
    }

    func testSnapshotNormalizesStoredRelativePathBeforeReturningMatch() {
        let rawRoot = "/Users/test/project/./Sources/.."
        let rawFile = MockFile(name: "main.swift", relativePath: "src/../main.swift", rootPath: rawRoot)
        let rawRootFolder = MockFolder(name: "project", relativePath: "", rootPath: rawRoot)
        let snapshot = PathMatchSnapshot(
            filesByFullPath: [rawFile.fullPath: rawFile],
            foldersByFullPath: [:],
            rootFolders: [rawRootFolder]
        )

        let result = PathMatcher.locate(userPath: "main.swift", snapshot: snapshot)
        XCTAssertEqual(result?.correctedPath, "main.swift")
        XCTAssertEqual(result?.rootPath, "/Users/test/project")
    }

    func testMultiRootDuplicateFilenames() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/config.json", "/Users/test/frontend"),
            ("src/config.json", "/Users/test/backend"),
            ("config.json", "/Users/test/shared")
        ])
        
        // With path context, should resolve correctly
        PathMatcherTestHelper.assertResolves("frontend/src/config.json", to: "src/config.json", in: snapshot)
        PathMatcherTestHelper.assertResolves("backend/src/config.json", to: "src/config.json", in: snapshot)
        PathMatcherTestHelper.assertResolves("shared/config.json", to: "config.json", in: snapshot)
        
        // Just filename is ambiguous - should pick the shallowest
        PathMatcherTestHelper.assertResolves("config.json", to: "config.json", in: snapshot)
    }
    
    // MARK: - Edge Cases
    
    func testEmptyPath() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("test.txt", "/Users/test/project")
        ])
        
        PathMatcherTestHelper.assertResolves("", to: nil, in: snapshot)
        PathMatcherTestHelper.assertResolves("   ", to: nil, in: snapshot)
    }
    
    func testPathNormalization() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/main.swift", "/Users/test/project")
        ])
        
        // Various forms should normalize to the same result
        PathMatcherTestHelper.assertResolves("src/main.swift", to: "src/main.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("./src/main.swift", to: "src/main.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("src//main.swift", to: "src/main.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("  src/main.swift  ", to: "src/main.swift", in: snapshot)
    }
    
    func testCaseInsensitiveFilenameMatch() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/ViewController.swift", "/Users/test/project")
        ])
        
        // Should match case-insensitively when using parent folder optimization
        PathMatcherTestHelper.assertResolves("src/viewcontroller.swift", to: "src/ViewController.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("src/VIEWCONTROLLER.SWIFT", to: "src/ViewController.swift", in: snapshot)
    }
    
    func testDeepNesting() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("a/b/c/d/e/f/deep.txt", "/Users/test/project")
        ])
        
        // Should handle deeply nested paths
        PathMatcherTestHelper.assertResolves("deep.txt", to: "a/b/c/d/e/f/deep.txt", in: snapshot)
        PathMatcherTestHelper.assertResolves("f/deep.txt", to: "a/b/c/d/e/f/deep.txt", in: snapshot)
        PathMatcherTestHelper.assertResolves("e/f/deep.txt", to: "a/b/c/d/e/f/deep.txt", in: snapshot)
        PathMatcherTestHelper.assertResolves("a/b/c/d/e/f/deep.txt", to: "a/b/c/d/e/f/deep.txt", in: snapshot)
    }
    
    // MARK: - Root alias handling
        
        func testRootAliasStrippingParity() async {
            // root names: web, api
            let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
                ("src/app.js", "/Users/test/web"),
                ("src/server.py", "/Users/test/api")
            ])
            // Alias included vs not included should resolve identically
            PathMatcherTestHelper.assertResolves("web/src/app.js", to: "src/app.js", in: snapshot)
            PathMatcherTestHelper.assertResolves("src/app.js", to: "src/app.js", in: snapshot)
            PathMatcherTestHelper.assertResolves("api/src/server.py", to: "src/server.py", in: snapshot)
            PathMatcherTestHelper.assertResolves("src/server.py", to: "src/server.py", in: snapshot)
        }
        
        func testRootAliasBiasAcrossMultipleRoots() async {
            let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
                ("components/Button/index.tsx", "/Users/test/web"),
                ("components/Button/index.tsx", "/Users/test/mobile")
            ])
            // With explicit alias prefix, should bias that root deterministically
            PathMatcherTestHelper.assertResolves("web/components/Button/index.tsx", to: "components/Button/index.tsx", in: snapshot)
            PathMatcherTestHelper.assertResolves("mobile/components/Button/index.tsx", to: "components/Button/index.tsx", in: snapshot)
            // Without alias, resolution is allowed but may be ambiguous; just ensure we get a match
            let any = PathMatcherTestHelper.getResolvedPath("components/Button/index.tsx", in: snapshot)
            XCTAssertNotNil(any)
        }

		func testRootAliasDoublePrefixConsumesOnlyTheLeadingAlias() async {
			let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
				("nested_test.txt", "/Users/test/BombSquad"),
				("BombSquad/nested_test.txt", "/Users/test/BombSquad")
			])

			PathMatcherTestHelper.assertResolves("BombSquad/nested_test.txt", to: "nested_test.txt", in: snapshot)
			PathMatcherTestHelper.assertResolves("BombSquad/BombSquad/nested_test.txt", to: "BombSquad/nested_test.txt", in: snapshot)
		}
        
        // MARK: - Edge Cases with Path Disambiguation
    
    func testAmbiguousPathsWithLastTwoComponents() async {
        // Test when multiple files have the same last two path components
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/utils/Logger.swift", "/Users/test/frontend"),
            ("lib/utils/Logger.swift", "/Users/test/backend"),
            ("common/utils/Logger.swift", "/Users/test/shared")
        ])
        
        // When searching for "utils/Logger.swift", it should be ambiguous
        // The current implementation might pick one arbitrarily
        // Let's verify it at least finds something
        let result1 = PathMatcherTestHelper.getResolvedPath("utils/Logger.swift", in: snapshot)
        XCTAssertNotNil(result1, "Should find at least one match for utils/Logger.swift")
        
        // With more context, it should resolve correctly
        PathMatcherTestHelper.assertResolves("frontend/src/utils/Logger.swift", to: "src/utils/Logger.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("backend/lib/utils/Logger.swift", to: "lib/utils/Logger.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("shared/common/utils/Logger.swift", to: "common/utils/Logger.swift", in: snapshot)
    }
    
    func testDeeplyNestedAmbiguousFiles() async {
        // Test files with same name at different depths
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("config.json", "/Users/test/app"),
            ("src/config.json", "/Users/test/app"),
            ("src/modules/auth/config.json", "/Users/test/app"),
            ("src/modules/user/config.json", "/Users/test/app"),
            ("tests/config.json", "/Users/test/app")
        ])
        
        // Just filename should pick the shallowest
        PathMatcherTestHelper.assertResolves("config.json", to: "config.json", in: snapshot)
        
        // With partial paths
        PathMatcherTestHelper.assertResolves("src/config.json", to: "src/config.json", in: snapshot)
        PathMatcherTestHelper.assertResolves("auth/config.json", to: "src/modules/auth/config.json", in: snapshot)
        PathMatcherTestHelper.assertResolves("user/config.json", to: "src/modules/user/config.json", in: snapshot)
        PathMatcherTestHelper.assertResolves("tests/config.json", to: "tests/config.json", in: snapshot)
    }
    
    func testSimilarPathStructuresAcrossRoots() async {
        // Test when multiple roots have similar directory structures
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("components/Button/index.tsx", "/Users/test/web"),
            ("components/Button/index.tsx", "/Users/test/mobile"),
            ("components/Button/index.tsx", "/Users/test/desktop")
        ])
        
        // Without root context, it's ambiguous
        let result = PathMatcherTestHelper.getResolvedPath("components/Button/index.tsx", in: snapshot)
        XCTAssertNotNil(result, "Should find at least one match")
        
        // With root hints
        PathMatcherTestHelper.assertResolves("web/components/Button/index.tsx", to: "components/Button/index.tsx", in: snapshot)
        PathMatcherTestHelper.assertResolves("mobile/components/Button/index.tsx", to: "components/Button/index.tsx", in: snapshot)
        PathMatcherTestHelper.assertResolves("desktop/components/Button/index.tsx", to: "components/Button/index.tsx", in: snapshot)
    }
    
    func testIncompletePathsWithCorrectLastComponents() async {
        // This tests the specific case mentioned - incomplete paths where last 2 components are correct
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/main/java/com/example/utils/StringHelper.java", "/Users/test/project1"),
            ("src/test/java/com/example/utils/StringHelper.java", "/Users/test/project1"),
            ("lib/external/utils/StringHelper.java", "/Users/test/project2"),
            ("vendor/legacy/utils/StringHelper.java", "/Users/test/project3")
        ], selectedFiles: [
            "/Users/test/project1/src/main/java/com/example/utils/StringHelper.java"
        ])
        
        // Search with just last 2 components - should find something
        let result = PathMatcherTestHelper.getResolvedPath("utils/StringHelper.java", in: snapshot)
        XCTAssertNotNil(result, "Should find a match for utils/StringHelper.java")
        
        // With 3 components to disambiguate
        PathMatcherTestHelper.assertResolves("example/utils/StringHelper.java", to: "src/main/java/com/example/utils/StringHelper.java", in: snapshot)
        PathMatcherTestHelper.assertResolves("external/utils/StringHelper.java", to: "lib/external/utils/StringHelper.java", in: snapshot)
        PathMatcherTestHelper.assertResolves("legacy/utils/StringHelper.java", to: "vendor/legacy/utils/StringHelper.java", in: snapshot)
    }
    
    func testPathsWithCommonPrefixesAndSuffixes() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("UserController.swift", "/Users/test/api"),
            ("UserControllerTests.swift", "/Users/test/api"),
            ("UserControllerMock.swift", "/Users/test/api"),
            ("admin/UserController.swift", "/Users/test/api"),
            ("v2/UserController.swift", "/Users/test/api")
        ])
        
        // Exact name matches
        PathMatcherTestHelper.assertResolves("UserController.swift", to: "UserController.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("UserControllerTests.swift", to: "UserControllerTests.swift", in: snapshot)
        
        // With path prefix
        PathMatcherTestHelper.assertResolves("admin/UserController.swift", to: "admin/UserController.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("v2/UserController.swift", to: "v2/UserController.swift", in: snapshot)
    }
    
    func testMisleadingSimilarPaths() async {
        // Test paths that could be confused due to similar components
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("test/utils/Helper.swift", "/Users/test/project"),
            ("src/test/Helper.swift", "/Users/test/project"),
            ("utils/test/Helper.swift", "/Users/test/project"),
            ("utils/Helper.swift", "/Users/test/project")
        ])
        
        // Each should resolve to the correct file
        PathMatcherTestHelper.assertResolves("test/utils/Helper.swift", to: "test/utils/Helper.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("src/test/Helper.swift", to: "src/test/Helper.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("utils/test/Helper.swift", to: "utils/test/Helper.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("utils/Helper.swift", to: "utils/Helper.swift", in: snapshot)
    }
    
    func testVeryLongPathsWithCommonSuffixes() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/main/java/com/company/product/module/submodule/util/DataProcessor.java", "/Users/test/monorepo"),
            ("src/test/java/com/company/product/module/submodule/util/DataProcessor.java", "/Users/test/monorepo"),
            ("external/vendor/lib/util/DataProcessor.java", "/Users/test/monorepo")
        ], selectedFiles: [
            "/Users/test/monorepo/src/main/java/com/company/product/module/submodule/util/DataProcessor.java"
        ])
        
        // With just filename
        let result = PathMatcherTestHelper.getResolvedPath("DataProcessor.java", in: snapshot)
        XCTAssertNotNil(result, "Should find DataProcessor.java")
        
        // With 2 components
        PathMatcherTestHelper.assertResolves("util/DataProcessor.java", to: "external/vendor/lib/util/DataProcessor.java", in: snapshot)
        
        // With more specific paths
        PathMatcherTestHelper.assertResolves("submodule/util/DataProcessor.java", to: "src/main/java/com/company/product/module/submodule/util/DataProcessor.java", in: snapshot)
    }
    
    func testSpecialCharactersInPaths() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/[utils]/helper.js", "/Users/test/project"),
            ("src/@types/helper.js", "/Users/test/project"),
            ("src/utils-v2/helper.js", "/Users/test/project"),
            ("src/utils.old/helper.js", "/Users/test/project")
        ])
        
        // These should still resolve correctly
        PathMatcherTestHelper.assertResolves("[utils]/helper.js", to: "src/[utils]/helper.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("@types/helper.js", to: "src/@types/helper.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("utils-v2/helper.js", to: "src/utils-v2/helper.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("utils.old/helper.js", to: "src/utils.old/helper.js", in: snapshot)
    }
    
    // MARK: - Missing Component Tolerance Tests
    
    func testMissingComponentTolerance() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/components/auth/LoginForm.tsx", "/Users/test/app"),
            ("src/components/user/ProfileForm.tsx", "/Users/test/app"),
            ("tests/components/auth/LoginForm.test.tsx", "/Users/test/app")
        ])
        
        // Missing "src" - should still find the file
        let result1 = PathMatcherTestHelper.getResolvedPath("components/auth/LoginForm.tsx", in: snapshot)
        XCTAssertEqual(result1, "src/components/auth/LoginForm.tsx", "Should find file with missing 'src' component")
        
        // Missing middle component
        let result2 = PathMatcherTestHelper.getResolvedPath("src/auth/LoginForm.tsx", in: snapshot)
        XCTAssertEqual(result2, "src/components/auth/LoginForm.tsx", "Should find file with missing 'components' component")
        
        // This shouldn't match the test file since it has different extension
        let result3 = PathMatcherTestHelper.getResolvedPath("components/auth/LoginForm.tsx", in: snapshot)
        XCTAssertEqual(result3, "src/components/auth/LoginForm.tsx", "Should match the source file, not the test")
    }
    
    func testMissingComponentWithAmbiguity() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("frontend/src/utils/api/client.js", "/Users/test/monorepo"),
            ("backend/src/utils/api/client.js", "/Users/test/monorepo"),
            ("shared/utils/api/client.js", "/Users/test/monorepo")
        ])
        
        // When missing a component, prefer the shallowest match
        let result = PathMatcherTestHelper.getResolvedPath("utils/api/client.js", in: snapshot)
        XCTAssertEqual(result, "shared/utils/api/client.js", "Should prefer the shallowest path when ambiguous")
    }
    
    // MARK: - Exact Match Only Tests
    
    func testExactMatchOnlyMode() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/main.swift", "/Users/test/project"),
            ("src/mainViewModel.swift", "/Users/test/project")
        ])
        
        // Exact matches should work
        PathMatcherTestHelper.assertResolves("src/main.swift", to: "src/main.swift", exactMatchOnly: true, in: snapshot)
        
        // Fuzzy matches should fail in exact mode
        PathMatcherTestHelper.assertResolves("main.swift", to: nil, exactMatchOnly: true, in: snapshot)
        PathMatcherTestHelper.assertResolves("src/main.swif", to: nil, exactMatchOnly: true, in: snapshot)
        
        // But without exact mode, fuzzy should work
        PathMatcherTestHelper.assertResolves("main.swift", to: "src/main.swift", exactMatchOnly: false, in: snapshot)
    }
    
    func testRootPreferenceSingleComponent() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(
            files: [
                ("src/main.swift", "/Users/test/rootA"),
                ("src/main.swift", "/Users/test/rootB"),
                ("README.md",      "/Users/test/rootB")   // dummy selected file in rootB
            ],
            selectedFiles: [
                "/Users/test/rootB/README.md"
            ]
        )
        
        let result = PathMatcher.locate(
            userPath: "main.swift",
            exactMatchOnly: false,
            snapshot: snapshot
        )
        
        XCTAssertEqual(
            result?.rootPath,
            "/Users/test/rootB",
            "When multiple roots contain the same file, the root that already has a selected file should be preferred"
        )
        XCTAssertEqual(result?.correctedPath, "src/main.swift")
    }

    func testRootPreferenceRelativePath() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(
            files: [
                ("src/utils/helper.swift", "/Users/test/alpha"),
                ("src/utils/helper.swift", "/Users/test/beta"),
                ("docs/guide.md",          "/Users/test/beta") // dummy selected file in beta
            ],
            selectedFiles: [
                "/Users/test/beta/docs/guide.md"
            ]
        )
        
        let result = PathMatcher.locate(
            userPath: "src/utils/helper.swift",
            exactMatchOnly: false,
            snapshot: snapshot
        )
        
        XCTAssertEqual(
            result?.rootPath,
            "/Users/test/beta",
            "Relative-path resolution should prefer the root that contains selected files"
        )
        XCTAssertEqual(result?.correctedPath, "src/utils/helper.swift")
    }
    
    // MARK: - Special Character Stress Tests
    
    func testMixedHyphensAndUnderscores() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/my-component_test.js", "/Users/test/project"),
            ("src/my_component-test.js", "/Users/test/project"),
            ("src/my-component-test.js", "/Users/test/project"),
            ("src/my_component_test.js", "/Users/test/project"),
            ("tests/auth-service_spec.rb", "/Users/test/project"),
            ("tests/auth_service-spec.rb", "/Users/test/project"),
            ("lib/data-parser_utils.py", "/Users/test/project"),
            ("lib/data_parser-utils.py", "/Users/test/project")
        ])
        
        // Test exact matches work
        PathMatcherTestHelper.assertResolves("src/my-component_test.js", to: "src/my-component_test.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("src/my_component-test.js", to: "src/my_component-test.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("tests/auth-service_spec.rb", to: "tests/auth-service_spec.rb", in: snapshot)
        PathMatcherTestHelper.assertResolves("lib/data-parser_utils.py", to: "lib/data-parser_utils.py", in: snapshot)
        
        // Test partial path matches
        PathMatcherTestHelper.assertResolves("my-component_test.js", to: "src/my-component_test.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("auth-service_spec.rb", to: "tests/auth-service_spec.rb", in: snapshot)
        PathMatcherTestHelper.assertResolves("data-parser_utils.py", to: "lib/data-parser_utils.py", in: snapshot)
        
        // Test absolute paths
        PathMatcherTestHelper.assertResolves("/Users/test/project/src/my-component_test.js", to: "src/my-component_test.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("/Users/test/project/tests/auth_service-spec.rb", to: "tests/auth_service-spec.rb", in: snapshot)
    }
    
    func testComplexSpecialCharacterPaths() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("@types/node_modules/react-native.d.ts", "/Users/test/project"),
            ("src/[id]/page-component_test.tsx", "/Users/test/project"),
            ("tests/e2e/auth-flow_test-suite.spec.js", "/Users/test/project"),
            ("lib/@company/shared-utils_v2.1.0.js", "/Users/test/project"),
            ("docs/API-Reference_v2-draft.md", "/Users/test/project"),
            ("scripts/build-prod_deploy-staging.sh", "/Users/test/project")
        ])
        
        // Test exact matches with special characters
        PathMatcherTestHelper.assertResolves("@types/node_modules/react-native.d.ts", to: "@types/node_modules/react-native.d.ts", in: snapshot)
        PathMatcherTestHelper.assertResolves("src/[id]/page-component_test.tsx", to: "src/[id]/page-component_test.tsx", in: snapshot)
        PathMatcherTestHelper.assertResolves("lib/@company/shared-utils_v2.1.0.js", to: "lib/@company/shared-utils_v2.1.0.js", in: snapshot)
        
        // Test partial matches
        PathMatcherTestHelper.assertResolves("react-native.d.ts", to: "@types/node_modules/react-native.d.ts", in: snapshot)
        PathMatcherTestHelper.assertResolves("page-component_test.tsx", to: "src/[id]/page-component_test.tsx", in: snapshot)
        PathMatcherTestHelper.assertResolves("shared-utils_v2.1.0.js", to: "lib/@company/shared-utils_v2.1.0.js", in: snapshot)
        
        // Test with absolute paths
        PathMatcherTestHelper.assertResolves("/Users/test/project/tests/e2e/auth-flow_test-suite.spec.js", to: "tests/e2e/auth-flow_test-suite.spec.js", in: snapshot)
    }
    
    func testSimilarNamesWithDifferentSpecialChars() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/user-profile.js", "/Users/test/project"),
            ("src/user_profile.js", "/Users/test/project"),
            ("src/userProfile.js", "/Users/test/project"),
            ("tests/user-profile-test.js", "/Users/test/project"),
            ("tests/user_profile_test.js", "/Users/test/project"),
            ("tests/userProfileTest.js", "/Users/test/project")
        ])
        
        // Ensure exact matches work for similar names
        PathMatcherTestHelper.assertResolves("src/user-profile.js", to: "src/user-profile.js", exactMatchOnly: true, in: snapshot)
        PathMatcherTestHelper.assertResolves("src/user_profile.js", to: "src/user_profile.js", exactMatchOnly: true, in: snapshot)
        PathMatcherTestHelper.assertResolves("src/userProfile.js", to: "src/userProfile.js", exactMatchOnly: true, in: snapshot)
        
        // Test that fuzzy matching doesn't confuse similar files
        PathMatcherTestHelper.assertResolves("user-profile.js", to: "src/user-profile.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("user_profile.js", to: "src/user_profile.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("userProfile.js", to: "src/userProfile.js", in: snapshot)
    }
    
    func testDeepNestedPathsWithSpecialChars() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/components/auth/login-form_controller-v2.tsx", "/Users/test/project"),
            ("src/components/auth/signup-form_controller-v2.tsx", "/Users/test/project"),
            ("src/services/api/auth-service_client-impl.ts", "/Users/test/project"),
            ("src/services/api/user-service_client-impl.ts", "/Users/test/project"),
            ("tests/unit/components/auth/login-form_controller-v2.test.tsx", "/Users/test/project"),
            ("tests/integration/services/api/auth-service_client-impl.test.ts", "/Users/test/project")
        ])
        
        // Test deep paths with exact match
        PathMatcherTestHelper.assertResolves("src/components/auth/login-form_controller-v2.tsx", to: "src/components/auth/login-form_controller-v2.tsx", in: snapshot)
        PathMatcherTestHelper.assertResolves("tests/unit/components/auth/login-form_controller-v2.test.tsx", to: "tests/unit/components/auth/login-form_controller-v2.test.tsx", in: snapshot)
        
        // Test partial deep paths
        PathMatcherTestHelper.assertResolves("auth/login-form_controller-v2.tsx", to: "src/components/auth/login-form_controller-v2.tsx", in: snapshot)
        PathMatcherTestHelper.assertResolves("api/auth-service_client-impl.ts", to: "src/services/api/auth-service_client-impl.ts", in: snapshot)
        
        // Test just filename matching in deep paths
        PathMatcherTestHelper.assertResolves("login-form_controller-v2.tsx", to: "src/components/auth/login-form_controller-v2.tsx", in: snapshot)
        PathMatcherTestHelper.assertResolves("auth-service_client-impl.ts", to: "src/services/api/auth-service_client-impl.ts", in: snapshot)
    }
    
    // Simulate deeply nested Java files with very long filenames to ensure
    // precheck in multi-component matching does not block valid resolutions.
    func testDeepJavaLongFilenamePrecheckDoesNotBlockResolution() async {
        let deepRel = "service-a/src/main/java/com/acme/very/deep/and/long/package/structure/with/many/levels/AndAVeryVeryLongFileNameForEnterpriseStandards.java"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (deepRel, "/Users/test/monorepo")
        ])

        // 1) Exact relative path should resolve
        PathMatcherTestHelper.assertResolves(deepRel, to: deepRel, in: snapshot)

        // 2) Multi-component suffix (hits lastComponentExists precheck) should resolve
        PathMatcherTestHelper.assertResolves(
            "package/structure/with/many/levels/AndAVeryVeryLongFileNameForEnterpriseStandards.java",
            to: deepRel,
            in: snapshot
        )

        // 3) Even just the filename should resolve when unique
        PathMatcherTestHelper.assertResolves(
            "AndAVeryVeryLongFileNameForEnterpriseStandards.java",
            to: deepRel,
            in: snapshot
        )

        // 4) Absolute path should resolve as well
        PathMatcherTestHelper.assertResolves(
            "/Users/test/monorepo/" + deepRel,
            to: deepRel,
            in: snapshot
        )
    }
    
    // Absolute path outside root prefix should still resolve via suffix matching
    // (e.g., symlinked path or different mount point), provided the tail matches.
    func testAbsoluteDeepPathOutsideRootStillResolvesBySuffix() async {
        let rel = "service-b/src/main/java/org/example/deep/tree/with/a/lot/of/components/AndAnotherExtremelyLongEnterpriseFileName.java"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (rel, "/Users/test/monorepo")
        ])

        // Simulate an absolute path that doesn't string-prefix match the loaded root
        let foreignAbs = "/mnt/buildagent/workspace/monorepo/" + rel

        // Should still resolve to the only matching file via suffix-based matching
        PathMatcherTestHelper.assertResolves(foreignAbs, to: rel, in: snapshot)
    }
    
    func testAbsoluteDeepPathDuplicateTailDeterministicPick() async {
        // Two roots, same last-two components, different depths
        let a = "srvA/x/y/bar/Foo.java"
        let b = "srvB/bar/Foo.java"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (a, "/Users/test/monorepoA"),
            (b, "/Users/test/monorepoB")
        ])
        let foreignAbs = "/foreign/build/output/long/path/bar/Foo.java"
        // Should resolve to the shallower path (b)
        PathMatcherTestHelper.assertResolves(foreignAbs, to: b, in: snapshot)
    }
    
    func testUltraDeepAbsoluteJavaPathResolvesByParentQualifiedTail() async {
        // >20 components
        let rel = "service-c/src/main/java/com/company/product/feature/experimental/very/deep/hierarchy/with/many/segments/and/even/more/levels/UltraDeepClassName.java"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (rel, "/Users/test/monorepo")
        ])
        let foreignAbs = "/mnt/ci/workspace/monorepo/" + rel
        PathMatcherTestHelper.assertResolves(foreignAbs, to: rel, in: snapshot)
    }
    
    func testExtremeDeepAbsoluteJavaPathResolves() async {
        // Build a path with ~60 components (extremely deep)
        let deepDirs = (1...59).map { "dir\($0)" }.joined(separator: "/")
        let rel = "service-d/src/main/java/" + deepDirs + "/UltraMegaDeepFile.java"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (rel, "/Users/test/monorepo")
        ])
        // Absolute variant under the actual loaded root
        let absUnderRoot = "/Users/test/monorepo/" + rel
        PathMatcherTestHelper.assertResolves(absUnderRoot, to: rel, in: snapshot)
        
        // Absolute variant with a different mount/prefix (simulates CI/agent path)
        let foreignAbs = "/mnt/data/ci/workspaces/monorepo/" + rel
        PathMatcherTestHelper.assertResolves(foreignAbs, to: rel, in: snapshot)
        
        // Another absolute variant to simulate a different volume prefix
        let foreignAbs2 = "/Volumes/build/agent/work/monorepo/" + rel
        PathMatcherTestHelper.assertResolves(foreignAbs2, to: rel, in: snapshot)
        
        // Also ensure filename-only resolves when unique
        PathMatcherTestHelper.assertResolves("UltraMegaDeepFile.java", to: rel, in: snapshot)
    }
    
    func testAbsoluteBoundaryPrefixDoesNotCrossRoot() async {
        // Roots: /Users/test/proj and /Users/test/projX
        let files = [
            ("file.txt", "/Users/test/projX"),
            ("main.txt", "/Users/test/proj")
        ]
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: files)
        // Absolute path under projX must resolve under projX, not proj
        PathMatcherTestHelper.assertResolves("/Users/test/projX/file.txt", to: "file.txt", in: snapshot)
        // Absolute path under proj must resolve under proj
        PathMatcherTestHelper.assertResolves("/Users/test/proj/main.txt", to: "main.txt", in: snapshot)
    }
    
    func testSpecialCharacterFilenamesExactAndFuzzy() async {
        let files = [
            ("src/My File (v2)+build#1!.swift", "/Users/test/project"),
            ("docs/%Notes{Draft}.md", "/Users/test/project")
        ]
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: files)
        // Exact relative
        PathMatcherTestHelper.assertResolves("src/My File (v2)+build#1!.swift", to: "src/My File (v2)+build#1!.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("docs/%Notes{Draft}.md", to: "docs/%Notes{Draft}.md", in: snapshot)
        // Absolute resolves
        PathMatcherTestHelper.assertResolves("/Users/test/project/src/My File (v2)+build#1!.swift", to: "src/My File (v2)+build#1!.swift", in: snapshot)
        // Filename-only should work when unique
        PathMatcherTestHelper.assertResolves("My File (v2)+build#1!.swift", to: "src/My File (v2)+build#1!.swift", in: snapshot)
    }
    
    func testAmbiguousLastTwoWithDifferentExtensionsPrefersExactExt() async {
        let files = [
            ("pkg/utils/Foo.java", "/Users/test/projA"),
            ("pkg/utils/Foo.kt", "/Users/test/projB")
        ]
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: files)
        // Exact extension should pick the exact file
        PathMatcherTestHelper.assertResolves("Foo.kt", to: "pkg/utils/Foo.kt", in: snapshot)
        PathMatcherTestHelper.assertResolves("Foo.java", to: "pkg/utils/Foo.java", in: snapshot)
        // Last-two with extension should pick exact
        PathMatcherTestHelper.assertResolves("utils/Foo.kt", to: "pkg/utils/Foo.kt", in: snapshot)
        PathMatcherTestHelper.assertResolves("utils/Foo.java", to: "pkg/utils/Foo.java", in: snapshot)
    }
    
	func testCaseInsensitiveAbsoluteResolution() async {
		let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
			("src/ViewController.swift", "/Users/test/project")
		])
		// Absolute with different casing should still resolve
		PathMatcherTestHelper.assertResolves("/Users/test/project/src/viewcontroller.swift", to: "src/ViewController.swift", in: snapshot)
	}

	// Folder components containing punctuation should survive canonicalization.
	func testDirectoryComponentsWithPunctuation_RelativeAndAbsolute() async {
		let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
			("src/features/Feature(Foo)/index.ts", "/Users/test/frontend"),
			("lib/{Core}/Math+Utils.swift", "/Users/test/backend"),
			("docs/Guides (v2)/Intro.md", "/Users/test/site"),
			("assets/icons/!bang#hash%perc.svg", "/Users/test/site")
		])

		// Relative (exact)
		PathMatcherTestHelper.assertResolves("src/features/Feature(Foo)/index.ts", to: "src/features/Feature(Foo)/index.ts", in: snapshot)
		PathMatcherTestHelper.assertResolves("lib/{Core}/Math+Utils.swift", to: "lib/{Core}/Math+Utils.swift", in: snapshot)
		PathMatcherTestHelper.assertResolves("docs/Guides (v2)/Intro.md", to: "docs/Guides (v2)/Intro.md", in: snapshot)
		PathMatcherTestHelper.assertResolves("assets/icons/!bang#hash%perc.svg", to: "assets/icons/!bang#hash%perc.svg", in: snapshot)

		// Absolute (parent-folder optimization path)
		PathMatcherTestHelper.assertResolves("/Users/test/frontend/src/features/Feature(Foo)/index.ts", to: "src/features/Feature(Foo)/index.ts", in: snapshot)
		PathMatcherTestHelper.assertResolves("/Users/test/backend/lib/{Core}/Math+Utils.swift", to: "lib/{Core}/Math+Utils.swift", in: snapshot)
		PathMatcherTestHelper.assertResolves("/Users/test/site/docs/Guides (v2)/Intro.md", to: "docs/Guides (v2)/Intro.md", in: snapshot)
		PathMatcherTestHelper.assertResolves("/Users/test/site/assets/icons/!bang#hash%perc.svg", to: "assets/icons/!bang#hash%perc.svg", in: snapshot)

		// Fuzzy: last-two components
		PathMatcherTestHelper.assertResolves("Feature(Foo)/index.ts", to: "src/features/Feature(Foo)/index.ts", in: snapshot)
		PathMatcherTestHelper.assertResolves("{Core}/Math+Utils.swift", to: "lib/{Core}/Math+Utils.swift", in: snapshot)
	}

	// Alias-prefixed searches should tolerate parentheses.
	func testRootAliasWithParentheses() async {
		let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
			("src/features/Feature(Foo)/index.ts", "/Users/test/web"),
			("src/features/Feature(Foo)/index.ts", "/Users/test/mobile")
		])

		PathMatcherTestHelper.assertResolves("web/src/features/Feature(Foo)/index.ts", to: "src/features/Feature(Foo)/index.ts", in: snapshot)
		PathMatcherTestHelper.assertResolves("mobile/src/features/Feature(Foo)/index.ts", to: "src/features/Feature(Foo)/index.ts", in: snapshot)

		let any = PathMatcherTestHelper.getResolvedPath("features/Feature(Foo)/index.ts", in: snapshot)
		XCTAssertNotNil(any)
	}
    
     func testAbsolutePathParentFolderOptimization() async {
        // This test verifies the fix for the absolute path parent-folder optimization bug
        // where folderRel was built as a relative path instead of absolute
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/components/Button.tsx", "/Users/test/frontend"),
            ("src/components/Modal.tsx", "/Users/test/frontend"),
            ("lib/utils/helper.js", "/Users/test/backend"),
            ("lib/utils/parser.js", "/Users/test/backend")
        ])
        
        // Test absolute path with parent folder that exists
        // This should trigger the parent-folder optimization path
        let buttonResult = PathMatcher.locate(
            userPath: "/Users/test/frontend/src/components/Button.tsx",
            exactMatchOnly: false,
            snapshot: snapshot
        )
        XCTAssertNotNil(buttonResult, "Should find Button.tsx via absolute path parent-folder optimization")
        XCTAssertEqual(buttonResult?.rootPath, "/Users/test/frontend")
        XCTAssertEqual(buttonResult?.correctedPath, "src/components/Button.tsx")
        
        // Test with backend files
        let helperResult = PathMatcher.locate(
            userPath: "/Users/test/backend/lib/utils/helper.js",
            exactMatchOnly: false,
            snapshot: snapshot
        )
        XCTAssertNotNil(helperResult, "Should find helper.js via absolute path parent-folder optimization")
        XCTAssertEqual(helperResult?.rootPath, "/Users/test/backend")
        XCTAssertEqual(helperResult?.correctedPath, "lib/utils/helper.js")
        
        // Test with non-existent file in existing folder
        let missingResult = PathMatcher.locate(
            userPath: "/Users/test/frontend/src/components/NonExistent.tsx",
            exactMatchOnly: false,
            snapshot: snapshot
        )
        XCTAssertNil(missingResult, "Should not find non-existent file even if parent folder exists")
    }
    
    func testMultiRootWithSpecialCharPaths() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/auth-module_v1.js", "/Users/test/frontend"),
            ("src/auth-module_v2.js", "/Users/test/backend"),
            ("lib/data-parser_utils.py", "/Users/test/frontend"),
            ("lib/data-parser_utils.py", "/Users/test/backend"),
            ("tests/api-client_test.rb", "/Users/test/frontend"),
            ("tests/api-server_test.rb", "/Users/test/backend")
        ])
        
        // Test disambiguation between roots
        PathMatcherTestHelper.assertResolves("/Users/test/frontend/src/auth-module_v1.js", to: "src/auth-module_v1.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("/Users/test/backend/src/auth-module_v2.js", to: "src/auth-module_v2.js", in: snapshot)
        
        // Test that similar files in different roots can be found
        // When using absolute paths, we should get the exact root specified
        // FIXME: This test currently fails due to a bug in PathMatcher
        // where it doesn't correctly disambiguate between roots when the same file exists in multiple roots
        
        let frontendResult = PathMatcher.locate(userPath: "/Users/test/frontend/lib/data-parser_utils.py", exactMatchOnly: false, snapshot: snapshot)
        XCTAssertEqual(frontendResult?.rootPath, "/Users/test/frontend", 
                      "PathMatcher should return the file from the frontend root when given an absolute frontend path")
        XCTAssertEqual(frontendResult?.correctedPath, "lib/data-parser_utils.py")
        
        let backendResult = PathMatcher.locate(userPath: "/Users/test/backend/lib/data-parser_utils.py", exactMatchOnly: false, snapshot: snapshot)
        XCTAssertEqual(backendResult?.rootPath, "/Users/test/backend",
                      "PathMatcher should return the file from the backend root when given an absolute backend path")
        XCTAssertEqual(backendResult?.correctedPath, "lib/data-parser_utils.py")
    }
    
    // MARK: - Unicode & Case-Insensitivity

    func testUnicodeFilenames_CaseInsensitiveAndExact() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/Ångström.swift", "/Users/test/project"),
            ("src/naïve.swift",    "/Users/test/project"),
            ("src/文件.swift",       "/Users/test/project")
        ])

        // Exact relative path should resolve
        PathMatcherTestHelper.assertResolves("src/Ångström.swift", to: "src/Ångström.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("src/naïve.swift",    to: "src/naïve.swift",    in: snapshot)
        PathMatcherTestHelper.assertResolves("src/文件.swift",       to: "src/文件.swift",       in: snapshot)

        // Absolute path should resolve
        PathMatcherTestHelper.assertResolves("/Users/test/project/src/Ångström.swift", to: "src/Ångström.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("/Users/test/project/src/naïve.swift",    to: "src/naïve.swift",    in: snapshot)
        PathMatcherTestHelper.assertResolves("/Users/test/project/src/文件.swift",       to: "src/文件.swift",       in: snapshot)

        // Single component (filename-only) should resolve case-insensitively
        PathMatcherTestHelper.assertResolves("ångström.swift", to: "src/Ångström.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("NAÏVE.SWIFT",    to: "src/naïve.swift",    in: snapshot)
        PathMatcherTestHelper.assertResolves("文件.swift",        to: "src/文件.swift",       in: snapshot)
    }

    func testUnicodeInFolderNames_Resolution() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/über/utils/Parser.kt", "/Users/test/project"),
            ("src/данные/модуль/Main.java", "/Users/test/project")
        ])

        PathMatcherTestHelper.assertResolves("src/über/utils/Parser.kt", to: "src/über/utils/Parser.kt", in: snapshot)
        PathMatcherTestHelper.assertResolves("src/данные/модуль/Main.java", to: "src/данные/модуль/Main.java", in: snapshot)

        // Filename-only should still resolve
        PathMatcherTestHelper.assertResolves("Parser.kt", to: "src/über/utils/Parser.kt", in: snapshot)
        PathMatcherTestHelper.assertResolves("Main.java", to: "src/данные/модуль/Main.java", in: snapshot)
    }

    // MARK: - Dash Homoglyphs (GPT-5 Fix)

    func testDashHomoglyphs_FileNames_RelativeAndAbsolute_Resolve() async {
        let root = "/Users/test/zenml"
        let a = "docs/book/how-to/dashboard/dashboard-features.md"
        let b = "docs/book/user-guide/starter-guide/create-an-ml-pipeline.md"
        let c = "docs/book/how-to/steps-pipelines/steps_and_pipelines.md"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (a, root), (b, root), (c, root)
        ])

        // EN DASH U+2013 between tokens (what GPT often emits)
        let en: Character = "–"

        // Relative queries with EN DASH should resolve to ASCII-hyphen files
        PathMatcherTestHelper.assertResolves(
            "docs/book/how-to/dashboard/dashboard\(en)features.md",
            to: a,
            in: snapshot
        )
        PathMatcherTestHelper.assertResolves(
            "docs/book/user-guide/starter-guide/create\(en)an\(en)ml\(en)pipeline.md",
            to: b,
            in: snapshot
        )
        PathMatcherTestHelper.assertResolves(
            "docs/book/how-to/steps\(en)pipelines/steps_and_pipelines.md",
            to: c,
            in: snapshot
        )

        // Absolute with EN DASH
        PathMatcherTestHelper.assertResolves(
            "\(root)/docs/book/how-to/dashboard/dashboard\(en)features.md",
            to: a,
            in: snapshot
        )
    }

    func testDashHomoglyphs_ByLastTwoCanonicalKey_FoldsToHyphen() async {
        let root = "/Users/test/zenml"
        let ascii = "dashboard-features.md"
        let homog = "dashboard–features.md" // EN DASH

        let relA = "docs/\(ascii)"
        let relB = "docs/\(homog)" // This file does NOT exist; we test the key behavior

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (relA, root)
        ])

        // Keys computed from queries should normalize EN DASH to '-'
        let kAscii = snapshot.canonical("docs/\(ascii)")
        let kHomog = snapshot.canonical("docs/\(homog)")
        XCTAssertEqual(kAscii, kHomog, "Homoglyph dash should fold to ASCII hyphen in canonical key")

        // Lookup via homoglyph path should still find ASCII file
        PathMatcherTestHelper.assertResolves("docs/\(homog)", to: relA, in: snapshot)
    }

    func testDashHomoglyphs_FolderNames_Resolve() async {
        let root = "/Users/test/zenml"
        let rel  = "docs/book/how-to/steps-pipelines/steps_and_pipelines.md"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (rel, root)
        ])

        let en: Character = "–"
        // Folder name with EN DASH should resolve
        PathMatcherTestHelper.assertResolves(
            "docs/book/how-to/steps\(en)pipelines/steps_and_pipelines.md",
            to: rel,
            in: snapshot
        )
    }

    func testDashHomoglyphs_MultipleVariants_AllResolve() async {
        let root = "/Users/test/project" 
        let target = "src/multi-dash-file.swift"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (target, root)
        ])

        // Test various dash lookalikes that should all resolve to the ASCII hyphen file
        let variants = [
            "src/multi‐dash‐file.swift", // U+2010 hyphen
            "src/multi‑dash‑file.swift", // U+2011 non-breaking hyphen
            "src/multi‒dash‒file.swift", // U+2012 figure dash
            "src/multi–dash–file.swift", // U+2013 en dash
            "src/multi—dash—file.swift", // U+2014 em dash
            "src/multi−dash−file.swift", // U+2212 minus
        ]

        for variant in variants {
            PathMatcherTestHelper.assertResolves(variant, to: target, in: snapshot)
        }
    }

    // MARK: - Enhanced Homoglyph Tests

    func testFullwidthAlnum_FoldsToASCII() async {
        let root = "/Users/test/repo"
        let ascii = "docs/v2.10.0/Readme.txt"
        let fullw = "docs/v２.１0.０/Ｒｅａｄｍｅ.txt" // mix of fullwidth digits/letters

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (ascii, root)
        ])

        // Relative with fullwidth should resolve to ASCII file
        PathMatcherTestHelper.assertResolves(fullw, to: ascii, in: snapshot)
    }

    func testWeirdSpaces_ZeroWidth_DroppedOrFolded() async {
        let root = "/Users/test/repo"
        let ascii = "docs/how to/guide.md"
        // "how<NBSP>to" and zero-width joiner inside 'guide'
        let qp = "docs/how\u{00A0}to/gui\u{200D}de.md"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (ascii, root)
        ])

        PathMatcherTestHelper.assertResolves(qp, to: ascii, in: snapshot)
    }

    // Windows-specific backslash/Yen normalization removed for macOS-only app

    func testMoreDashes_FoldToHyphen() async {
        let root = "/Users/test/repo"
        let ascii = "docs/three---em-dash.md"
        // Use THREE-EM DASH and HYPHEN BULLET - positions must match ASCII file
        // THREE-EM DASH (⸻) folds to '---', HYPHEN BULLET (⁃) folds to '-'  
        let q = "docs/three\u{2E3B}em\u{2043}dash.md"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (ascii, root)
        ])

        PathMatcherTestHelper.assertResolves(q, to: ascii, in: snapshot)
    }

    func testMultiCharDashFolding_TwoAndThreeEM() async {
        let root = "/Users/test/repo"
        // Test precise folding: TWO-EM DASH → '--', THREE-EM DASH → '---'
        let ascii1 = "docs/version--2.0.md"
        let ascii2 = "docs/final---draft.md"
        let ascii3 = "docs/mix--and---match.md"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (ascii1, root),
            (ascii2, root), 
            (ascii3, root)
        ])

        // TWO-EM DASH (⸺) → '--'
        PathMatcherTestHelper.assertResolves("docs/version\u{2E3A}2.0.md", to: ascii1, in: snapshot)
        
        // THREE-EM DASH (⸻) → '---'
        PathMatcherTestHelper.assertResolves("docs/final\u{2E3B}draft.md", to: ascii2, in: snapshot)
        
        // Mix of both in one path
        PathMatcherTestHelper.assertResolves("docs/mix\u{2E3A}and\u{2E3B}match.md", to: ascii3, in: snapshot)
    }

    func testVariousSpaces_NormalizeToASCII() async {
        let root = "/Users/test/repo"
        let ascii = "src/utils lib/parser.swift"
        
        // Test various Unicode spaces that should normalize to ASCII space
        let variants = [
            "src/utils\u{00A0}lib/parser.swift", // NBSP U+00A0
            "src/utils\u{1680}lib/parser.swift", // OGHAM SPACE MARK U+1680  
            "src/utils\u{2000}lib/parser.swift", // EN QUAD U+2000
            "src/utils\u{2001}lib/parser.swift", // EM QUAD U+2001
            "src/utils\u{2002}lib/parser.swift", // EN SPACE U+2002
            "src/utils\u{2003}lib/parser.swift", // EM SPACE U+2003
            "src/utils\u{2004}lib/parser.swift", // THREE-PER-EM SPACE U+2004
            "src/utils\u{2005}lib/parser.swift", // FOUR-PER-EM SPACE U+2005
            "src/utils\u{2006}lib/parser.swift", // SIX-PER-EM SPACE U+2006
            "src/utils\u{2007}lib/parser.swift", // FIGURE SPACE U+2007
            "src/utils\u{2008}lib/parser.swift", // PUNCTUATION SPACE U+2008
            "src/utils\u{2009}lib/parser.swift", // THIN SPACE U+2009
            "src/utils\u{200A}lib/parser.swift", // HAIR SPACE U+200A
            "src/utils\u{202F}lib/parser.swift", // NARROW NBSP U+202F
            "src/utils\u{205F}lib/parser.swift", // MEDIUM MATHEMATICAL SPACE U+205F
            "src/utils\u{3000}lib/parser.swift"  // IDEOGRAPHIC SPACE U+3000
        ]

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (ascii, root)
        ])

        for variant in variants {
            PathMatcherTestHelper.assertResolves(variant, to: ascii, in: snapshot)
        }
    }

    func testZeroWidthChars_DroppedCompletely() async {
        let root = "/Users/test/repo"
        let ascii = "src/filename.swift"
        
        // Test various zero-width characters that should be completely dropped
        let variants = [
            "src/file\u{200B}name.swift", // ZERO WIDTH SPACE U+200B
            "src/file\u{200C}name.swift", // ZERO WIDTH NON-JOINER U+200C
            "src/file\u{200D}name.swift", // ZERO WIDTH JOINER U+200D
            "src/file\u{2060}name.swift", // WORD JOINER U+2060
            "src/file\u{FEFF}name.swift", // ZERO WIDTH NO-BREAK SPACE (BOM) U+FEFF
            "src/file\u{200E}name.swift", // LEFT-TO-RIGHT MARK U+200E
            "src/file\u{200F}name.swift"  // RIGHT-TO-LEFT MARK U+200F
        ]

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (ascii, root)
        ])

        for variant in variants {
            PathMatcherTestHelper.assertResolves(variant, to: ascii, in: snapshot)
        }
    }

    func testFullwidthPunctuation_FoldsToASCII() async {
        let root = "/Users/test/repo"
        let ascii = "docs/my_file[v2].txt@backup"
        
        // Test fullwidth punctuation folding
        let fullwidth = "docs/my＿file［v２］.txt＠backup"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (ascii, root)
        ])

        PathMatcherTestHelper.assertResolves(fullwidth, to: ascii, in: snapshot)
    }

    func testMixedHomoglyphs_ComplexPath() async {
        let root = "/Users/test/complex"
        let ascii = "docs/v2.0-final/how-to_guide[new].md"
        
        // Mix various homoglyphs in a single path
        let mixed = "docs/v２.０–final/how‑to＿guide［new］.md"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (ascii, root)
        ])

        PathMatcherTestHelper.assertResolves(mixed, to: ascii, in: snapshot)
    }

    // MARK: - ASCII Allowed Punctuation Parity

    func testAllowedAsciiPunctuation_SingleComponentMatch() async {
        // Ensure we keep . _ - [ ] @ in canonical/cleaned and match correctly
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/user_profile-manager[alpha]@v2.tsx", "/Users/test/project"),
            ("src/lib/core-utils_v1.0.0.js",           "/Users/test/project")
        ])

        // Exact relative
        PathMatcherTestHelper.assertResolves("src/user_profile-manager[alpha]@v2.tsx", to: "src/user_profile-manager[alpha]@v2.tsx", in: snapshot)
        PathMatcherTestHelper.assertResolves("src/lib/core-utils_v1.0.0.js",           to: "src/lib/core-utils_v1.0.0.js",           in: snapshot)

        // Filename-only
        PathMatcherTestHelper.assertResolves("user_profile-manager[alpha]@v2.tsx", to: "src/user_profile-manager[alpha]@v2.tsx", in: snapshot)
        PathMatcherTestHelper.assertResolves("core-utils_v1.0.0.js",               to: "src/lib/core-utils_v1.0.0.js",           in: snapshot)

        // Uppercase query should still match
        PathMatcherTestHelper.assertResolves("USER_PROFILE-MANAGER[ALPHA]@V2.TSX", to: "src/user_profile-manager[alpha]@v2.tsx", in: snapshot)
    }

    // MARK: - Disallowed Punctuation / Emoji (no crash; exact still resolves)

    func testDisallowedPunctuationAndEmoji_NoCrashAndResolves() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/My File (v2)+build#1!.swift", "/Users/test/project"),
            ("docs/%Notes{Draft}.md",           "/Users/test/project"),
            ("assets/emoji-😀-file.txt",        "/Users/test/project")
        ])

        // Exact relative and absolute resolution must succeed (parity with previous behavior)
        PathMatcherTestHelper.assertResolves("src/My File (v2)+build#1!.swift", to: "src/My File (v2)+build#1!.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("/Users/test/project/src/My File (v2)+build#1!.swift", to: "src/My File (v2)+build#1!.swift", in: snapshot)

        PathMatcherTestHelper.assertResolves("docs/%Notes{Draft}.md", to: "docs/%Notes{Draft}.md", in: snapshot)
        PathMatcherTestHelper.assertResolves("/Users/test/project/docs/%Notes{Draft}.md", to: "docs/%Notes{Draft}.md", in: snapshot)

        PathMatcherTestHelper.assertResolves("assets/emoji-😀-file.txt", to: "assets/emoji-😀-file.txt", in: snapshot)
        PathMatcherTestHelper.assertResolves("/Users/test/project/assets/emoji-😀-file.txt", to: "assets/emoji-😀-file.txt", in: snapshot)

        // Filename-only queries should not crash and will typically resolve
        let maybeEmoji = PathMatcherTestHelper.getResolvedPath("emoji-😀-file.txt", in: snapshot)
        XCTAssertTrue(maybeEmoji == "assets/emoji-😀-file.txt" || maybeEmoji == nil, "Emoji filename-only should not crash; may or may not match based on fuzzy thresholds")
    }

    // MARK: - ASCII Case Insensitive Single-Component

    func testAsciiCaseInsensitive_SingleComponent() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/ViewController.swift", "/Users/test/project")
        ])

        // Existing tests cover parent-folder checks; this verifies single-component uppercased query
        PathMatcherTestHelper.assertResolves("VIEWCONTROLLER.SWIFT", to: "src/ViewController.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("viewcontroller.swift", to: "src/ViewController.swift", in: snapshot)
    }

    // MARK: - Collision Safety (canonical drops some chars): Exact paths remain resolvable

    func testCanonicalCollisionSafety_ExactPathsStillResolvable() async {
        // Canonical filtering drops # and !; ensure we still can resolve exact paths distinctively
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/strange#name!.txt", "/Users/test/project"),
            ("src/strangename.txt",   "/Users/test/project")
        ])

        PathMatcherTestHelper.assertResolves("src/strange#name!.txt", to: "src/strange#name!.txt", in: snapshot)
        PathMatcherTestHelper.assertResolves("src/strangename.txt",   to: "src/strangename.txt",   in: snapshot)
    }

    // MARK: - Large Index Smoke Test (no hang/crash)

    func testLargeRepository_Smoke_NoHang() async {
        // Build a snapshot with a few thousand files; just assert lookups succeed.
        var files: [(path: String, root: String)] = []
        files.reserveCapacity(5_000)
        for i in 0..<5_000 {
            files.append(("src/gen/file_\(i).swift", "/Users/test/huge"))
        }

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: files)

        // Resolve by file name (last one)
        PathMatcherTestHelper.assertResolves("file_4999.swift", to: "src/gen/file_4999.swift", in: snapshot)

        // Resolve by relative path
        PathMatcherTestHelper.assertResolves("src/gen/file_1234.swift", to: "src/gen/file_1234.swift", in: snapshot)

        // Resolve by absolute path
        PathMatcherTestHelper.assertResolves("/Users/test/huge/src/gen/file_42.swift", to: "src/gen/file_42.swift", in: snapshot)
    }
}

extension PathMatcherBasicTests {

    /// Regression: when '/' is stripped from the "last two" canonical key,
    /// ASCII-dense paths like "ab/cdef.swift" and "abc/def.swift" collide.
    /// Keeping '/' must allow both to resolve correctly.
    func testAsciiDense_LastTwo_SeparatorPreserved() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("ab/cdef.swift",  "/Users/test/proj"),
            ("abc/def.swift",  "/Users/test/proj"),
            ("x/abcdef.swift", "/Users/test/proj")  // decoy that would also collide if slash is dropped
        ])

        // Exact relative resolutions must pick the right file
        PathMatcherTestHelper.assertResolves("ab/cdef.swift", to: "ab/cdef.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("abc/def.swift", to: "abc/def.swift", in: snapshot)

        // Filename-only queries remain ambiguous but should still find a match
        XCTAssertNotNil(PathMatcherTestHelper.getResolvedPath("cdef.swift", in: snapshot))
        XCTAssertNotNil(PathMatcherTestHelper.getResolvedPath("def.swift",  in: snapshot))
    }

    /// Deep ASCII-heavy path: ensure suffix matching works with many ASCII components
    /// (exercise candidate prefilters without crashing or missing due to key collisions)
    func testAsciiHeavy_DeepSuffix_Resolves() async {
        // Build very ASCII-dense folder names
        let dirA = "components-super-long-ascii-sequence_v1-alpha"
        let dirB = "ui-layer-with-multiple-hyphens_and_underscores"
        let dirC = "feature-abcde-12345-EXPERIMENTAL"
        let file = "PrimaryButton_Controller-View_v2.swift"

        let rel = "\(dirA)/\(dirB)/\(dirC)/\(file)"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (rel, "/Users/test/app")
        ])

        // 1) Exact relative path
        PathMatcherTestHelper.assertResolves(rel, to: rel, in: snapshot)

        // 2) Last-two components (dirC + file) should suffice
        PathMatcherTestHelper.assertResolves("\(dirC)/\(file)", to: rel, in: snapshot)

        // 3) Foreign absolute path with the same tail (common in CI agents)
        let foreignAbs = "/mnt/builds/workspace/app/\(rel)"
        PathMatcherTestHelper.assertResolves(foreignAbs, to: rel, in: snapshot)
    }

    /// Stress a crafted ambiguity that only disambiguates if '/' is preserved in the last-two key.
    func testAsciiDense_BorderAmbiguity_DisambiguatesWithSlash() async {
        // These two are easy to confuse if '/' is removed:
        //   "aa/aaab.swift"  -> "aaaaab.swift"
        //   "aaa/aab.swift"  -> "aaaaab.swift"
        let f1 = "aa/aaab.swift"
        let f2 = "aaa/aab.swift"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (f1, "/Users/test/proj"),
            (f2, "/Users/test/proj")
        ])

        PathMatcherTestHelper.assertResolves(f1, to: f1, in: snapshot)
        PathMatcherTestHelper.assertResolves(f2, to: f2, in: snapshot)

        // Filename-only queries remain possible; we just ensure no crash and some result.
        XCTAssertNotNil(PathMatcherTestHelper.getResolvedPath("aaab.swift", in: snapshot))
        XCTAssertNotNil(PathMatcherTestHelper.getResolvedPath("aab.swift",  in: snapshot))
    }

    // Absolute path under the loaded WordPress root should resolve directly
    func testWordPress_AbsolutePath_DirectUnderRoot() async {
        let root = "/Users/bala/Sites/motory-group/wordpress"
        let rel  = "wp-content/plugins/gravityforms-adf/gravityforms-adf.php"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (rel, root)
        ])

        PathMatcherTestHelper.assertResolves(
            "\(root)/\(rel)",
            to: rel,
            in: snapshot
        )
    }

    // Absolute path with a foreign prefix (different mount) should still resolve
    // via parent-qualified tail fallback, as long as the folder chain + file exist under a loaded root.
    func testWordPress_AbsolutePath_ForeignPrefix_ResolvesByTail() async {
        let root = "/Users/bala/Sites/motory-group/wordpress"
        let rel  = "wp-content/plugins/gravityforms-adf/gravityforms-adf.php"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (rel, root)
        ])

        let foreignAbs = "/Volumes/devsites/motory-group/wordpress/\(rel)"
        PathMatcherTestHelper.assertResolves(
            foreignAbs,
            to: rel,
            in: snapshot
        )
    }

    // Exact relative path should resolve when the root is the WordPress root
    func testWordPress_RelativePath_Complete_Resolves() async {
        let root = "/Users/bala/Sites/motory-group/wordpress"
        let rel  = "wp-content/plugins/gravityforms-adf/gravityforms-adf.php"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (rel, root)
        ])

        PathMatcherTestHelper.assertResolves(
            rel,
            to: rel,
            in: snapshot
        )
    }

    // Relative path missing the leading "wp-content" component should still resolve
    // through strict suffix matching of the last components.
    func testWordPress_RelativePath_MissingLeadingComponent_ResolvesBySuffix() async {
        let root = "/Users/bala/Sites/motory-group/wordpress"
        let fullRel = "wp-content/plugins/gravityforms-adf/gravityforms-adf.php"
        let partial = "plugins/gravityforms-adf/gravityforms-adf.php" // missing "wp-content"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (fullRel, root)
        ])

        PathMatcherTestHelper.assertResolves(
            partial,
            to: fullRel,
            in: snapshot
        )
    }

    // Filename-only should resolve when unique in the loaded roots
    func testWordPress_FileNameOnly_ResolvesWhenUnique() async {
        let root = "/Users/bala/Sites/motory-group/wordpress"
        let rel  = "wp-content/plugins/gravityforms-adf/gravityforms-adf.php"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (rel, root)
        ])

        PathMatcherTestHelper.assertResolves(
            "gravityforms-adf.php",
            to: rel,
            in: snapshot
        )
    }

    // If the file does not exist anywhere under loaded roots, both absolute and relative lookups should fail in exact mode.
    func testWordPress_Nonexistent_ReturnsNilInExactMode() async {
        let root = "/Users/bala/Sites/motory-group/wordpress"
        let presentRel = "wp-content/index.php"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (presentRel, root)
        ])

        let missingAbs = "/Users/bala/Sites/motory-group/wordpress/wp-content/plugins/gravityforms-adf/gravityforms-adf.php"
        PathMatcherTestHelper.assertResolves(
            missingAbs,
            to: nil,
            exactMatchOnly: true,
            in: snapshot
        )

        PathMatcherTestHelper.assertResolves(
            "wp-content/plugins/gravityforms-adf/gravityforms-adf.php",
            to: nil,
            exactMatchOnly: true,
            in: snapshot
        )
    }

    // MARK: - 1) ASCII-dense "last two" collisions

    /// Regression guard: Two files whose "last two components" collide when '/' is removed:
    ///   - "aa/aaab.swift"      -> "aaaaab.swift"
    ///   - "aaa/aab.swift"      -> "aaaaab.swift"
    /// If canonicalization ever drops '/', resolution by 2-component suffix could degrade.
    /// We assert both remain resolvable.
    func testCollision_LastTwo_ASCII_Dense_Pair_Resolves() async {
        let root = "/Users/test/proj"
        let f1 = "aa/aaab.swift"
        let f2 = "aaa/aab.swift"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (f1, root),
            (f2, root)
        ])

        // 2-component suffix should resolve each one exactly
        PathMatcherTestHelper.assertResolves("aa/aaab.swift", to: f1, in: snapshot)
        PathMatcherTestHelper.assertResolves("aaa/aab.swift", to: f2, in: snapshot)

        // Absolute should also resolve
        PathMatcherTestHelper.assertResolves("\(root)/\(f1)", to: f1, in: snapshot)
        PathMatcherTestHelper.assertResolves("\(root)/\(f2)", to: f2, in: snapshot)
    }

    /// A broader ambiguity set that would create many collisions if '/' were removed.
    /// We still expect precise resolution by the exact 2-component suffix.
    func testCollision_LastTwo_ASCII_Dense_AmbiguitySet_StillResolves() async {
        let root = "/Users/test/proj"

        // Target that we must find:
        let target = "ab/cdef.swift"

        // Ambiguities that would collide if '/' is dropped:
        //   "abc/def.swift" -> "abcdef.swift"
        //   "a/bcdef.swift" -> "abcdef.swift"
        //   "ab/cdef.swift" -> "abcdef.swift" (the actual target)
        //   Add more ASCII-dense neighbors.
        var files: [(String, String)] = [
            (target, root),
            ("abc/def.swift", root),
            ("a/bcdef.swift", root),
            ("ab/cdef1.swift", root),
            ("ab1/cdef.swift", root),
            ("ab_/cdef.swift", root)
        ]

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: files)

        // Exact 2-component suffix must resolve to the intended target
        PathMatcherTestHelper.assertResolves("ab/cdef.swift", to: target, in: snapshot)

        // Foreign prefix absolute should still resolve by parent-qualified tail
        let foreignAbs = "/mnt/ci/workspace/proj/\(target)"
        PathMatcherTestHelper.assertResolves(foreignAbs, to: target, in: snapshot)
    }

    // MARK: - 2) WordPress gravityforms-adf path with ASCII collision decoys

    /// Ensure the WordPress plugin file remains findable even if there are crafted ASCII
    /// decoys whose "last two" would collide with the real key if '/' were removed.
    func testCollision_WordPress_GravityForms_LastTwo_Resolves() async {
        let root = "/Users/bala/Sites/motory-group/wordpress"
        let base = "wp-content/plugins"
        let folder = "gravityforms-adf"
        let file   = "gravityforms-adf.php"
        let target = "\(base)/\(folder)/\(file)"

        // Craft decoys that would collide with "gravityforms-adf/gravityforms-adf.php"
        // if '/' were removed from the canonical key:
        // Example: "gravityforms-adfg/ravityforms-adf.php" -> "gravityforms-adfgravityforms-adf.php"
        var files: [(String, String)] = [
            (target, root)
        ]
        let decoys = [
            "\(base)/gravityforms-adfg/ravityforms-adf.php",
            "\(base)/gravityforms-adfgr/avityforms-adf.php",
            "\(base)/gravityforms-adf_/gravityforms-adf.php" // similar name; not a collision in last-two, but adds pressure
        ]
        files.append(contentsOf: decoys.map { ($0, root) })

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: files)

        // Direct relative (complete)
        PathMatcherTestHelper.assertResolves(target, to: target, in: snapshot)

        // Two-component tail (the risky zone if '/' were dropped in indexing)
        PathMatcherTestHelper.assertResolves("\(folder)/\(file)", to: target, in: snapshot)

        // Absolute from the screenshot
        let abs = "\(root)/\(target)"
        PathMatcherTestHelper.assertResolves(abs, to: target, in: snapshot)

        // Foreign prefix absolute (common in CI or logs)
        let foreignAbs = "/Volumes/devsites/motory-group/wordpress/\(target)"
        PathMatcherTestHelper.assertResolves(foreignAbs, to: target, in: snapshot)
    }

    // MARK: - 3) Collision swarms (lots of look-alikes) still should not return nil

    /// Build a swarm of look-alike "last two" pairs around a target so that,
    /// if canonical '/' were removed, many keys would merge. We still expect
    /// locate() to find the target rather than returning nil.
    func testCollision_Swarm_ASCII_Dense_StillFindsTarget() async {
        let root = "/Users/test/proj"

        // Target last-two
        let target = "aa/aaab.swift"

        // Generate lots of look-alikes that would collide if '/' is removed.
        // We keep their filenames similar (candidates balloon), but ensure the exact
        // two-component query can still disambiguate the target.
        var files: [(String, String)] = [(target, root)]
        for i in 0..<2000 {
            // Alternate between shifting the split and perturbing the folder/file
            if i % 2 == 0 {
                files.append(("aaa/aab.swift", root))
            } else {
                files.append(("a/aaab.swift", root))
            }
        }

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: files)

        // Query by exact 2-component suffix (strict suffix pass)
        PathMatcherTestHelper.assertResolves("aa/aaab.swift", to: target, in: snapshot)

        // Also via absolute with foreign prefix to ensure suffix fallback remains robust
        let foreignAbs = "/mnt/agent/workspace/proj/\(target)"
        PathMatcherTestHelper.assertResolves(foreignAbs, to: target, in: snapshot)
    }

    // MARK: - 4) Ensure collisions don't accidentally yield nil on partial tails

    /// Many files with the same last-two components. We only require that locate()
    /// returns *a* valid match from that set (i.e. collisions don't degrade to "not found").
    func testCollision_ManySameFilename_PartialTail_ReturnsSomeMatch() async {
        let root = "/Users/test/big"
        let target = "src/moduleX/deep/gravityforms-adf.php"

        // Build a swarm of look-alikes
        var files: [(path: String, root: String)] = [(target, root)]
        var expectedPaths = Set([target])
        for i in 0..<3000 {
            let rel = "src/mod\(i)/deep/gravityforms-adf.php"
            files.append((rel, root))
            expectedPaths.insert(rel)
        }

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: files)

        // Query by the ambiguous tail
        let resolved = PathMatcherTestHelper.getResolvedPath(
            "deep/gravityforms-adf.php",
            in: snapshot
        )

        XCTAssertNotNil(resolved, "Collision swarm should still yield a match (not nil)")
        if let r = resolved {
            XCTAssertTrue(expectedPaths.contains(r),
                          "Resolved '\(r)' is not in the expected set of tail matches")
            XCTAssertTrue(r.hasSuffix("deep/gravityforms-adf.php"),
                          "Resolved path should end with the queried tail")
        }
    }

    /// Same swarm as above, but mark the intended file as 'selected' to verify
    /// tie-breaking chooses it deterministically.
    func testCollision_ManySameFilename_PartialTail_SelectedBiasPicksModuleX() async {
        let root = "/Users/test/big"
        let target = "src/moduleX/deep/gravityforms-adf.php"

        var files: [(path: String, root: String)] = [(target, root)]
        for i in 0..<3000 {
            files.append(("src/mod\(i)/deep/gravityforms-adf.php", root))
        }

        // Bias: mark the target as selected; the matcher prefers selected files on ties.
        let snapshot = await PathMatcherTestHelper.makeSnapshot(
            files: files,
            selectedFiles: ["\(root)/\(target)"]
        )

        PathMatcherTestHelper.assertResolves(
            "deep/gravityforms-adf.php",
            to: target,
            in: snapshot
        )
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // 1) Core invariant: canonical 2-component key must preserve '/'
    //    (This fails if canonical drops '/', which caused collisions.)
    // ─────────────────────────────────────────────────────────────────────────────
    func testIndexes_ByLastTwo_CanonicalPreservesSlash_ASCII_Dense() async {
        let root = "/Users/test/proj"
        let a = "ab/cdef.swift"
        let b = "abc/def.swift"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (a, root),
            (b, root)
        ])

        let keyA = snapshot.canonical("ab/cdef.swift")
        let keyB = snapshot.canonical("abc/def.swift")

        // Must keep the separator
        XCTAssertTrue(keyA.contains("/"), "canonical('ab/cdef.swift') should preserve '/'")
        XCTAssertTrue(keyB.contains("/"), "canonical('abc/def.swift') should preserve '/'")

        // Keys must differ for distinct 2-component tails
        XCTAssertNotEqual(keyA, keyB, "Different 'last two' tails must produce different canonical keys")

        // Buckets should isolate the intended file for each key
        let bucketA = (snapshot.indexes.byLastTwo[keyA] ?? []).map { $0.relativePath }.sorted()
        let bucketB = (snapshot.indexes.byLastTwo[keyB] ?? []).map { $0.relativePath }.sorted()

        XCTAssertEqual(bucketA, [a], "byLastTwo[\(keyA)] should only contain \(a)")
        XCTAssertEqual(bucketB, [b], "byLastTwo[\(keyB)] should only contain \(b)")
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // 2) WordPress target vs crafted ASCII decoys:
    //    ensure distinct canonical keys and isolated buckets (no collision).
    // ─────────────────────────────────────────────────────────────────────────────
    func testIndexes_ByLastTwo_WordPress_GravityForms_NoCollision() async {
        let root  = "/Users/bala/Sites/motory-group/wordpress"
        let base  = "wp-content/plugins"
        let dir   = "gravityforms-adf"
        let file  = "gravityforms-adf.php"
        let real  = "\(base)/\(dir)/\(file)"

        // Decoys that would collide with real if '/' were dropped from the key
        let d1 = "\(base)/gravityforms-adfg/ravityforms-adf.php"
        let d2 = "\(base)/gravityforms-adfgr/avityforms-adf.php"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            (real, root),
            (d1,   root),
            (d2,   root)
        ])

        let kReal = snapshot.canonical("\(dir)/\(file)")
        let kD1   = snapshot.canonical("gravityforms-adfg/ravityforms-adf.php")
        let kD2   = snapshot.canonical("gravityforms-adfgr/avityforms-adf.php")

        // Keys must preserve '/' and be distinct
        XCTAssertTrue(kReal.contains("/"))
        XCTAssertTrue(kD1.contains("/"))
        XCTAssertTrue(kD2.contains("/"))
        XCTAssertNotEqual(kReal, kD1, "Real key must not collide with d1")
        XCTAssertNotEqual(kReal, kD2, "Real key must not collide with d2")
        XCTAssertNotEqual(kD1,   kD2, "Decoy keys should also be distinct")

        // Buckets isolated per key
        let bReal = (snapshot.indexes.byLastTwo[kReal] ?? []).map { $0.relativePath }.sorted()
        let bD1   = (snapshot.indexes.byLastTwo[kD1]   ?? []).map { $0.relativePath }.sorted()
        let bD2   = (snapshot.indexes.byLastTwo[kD2]   ?? []).map { $0.relativePath }.sorted()

        XCTAssertEqual(bReal, [real])
        XCTAssertEqual(bD1,   [d1])
        XCTAssertEqual(bD2,   [d2])
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // 3) Stress: generate many pairs that would collapse if '/' were dropped.
    //    We assert 1:1 key→file isolation, catching any regression in canonical().
    // ─────────────────────────────────────────────────────────────────────────────
    func testIndexes_ByLastTwo_Stress_ManyPotentialCollisions_IsolatedBuckets() async {
        let root = "/Users/test/proj"

        // Build a set of pairs like:
        //   "aa/aaab.swift"  vs "aaa/aab.swift"
        //   "ab/bbcd.swift"  vs "abb/bcd.swift"
        // etc. – each pair would collide if '/' is removed.
        var rels: [String] = []
        for i in 0..<250 {
            let left  = String(repeating: "a", count: 2 + i % 3)
            let right = String(repeating: "a", count: 3 + (i % 2)) + "b"
            // Pair 1: "aa.../aa..ab.swift"
            let p1 = "\(left)/\(right).swift"
            // Pair 2: shift the split: "aaa../a..ab.swift"
            let p2 = "\(left)a/\(String(right.dropFirst())).swift"
            rels.append(contentsOf: [p1, p2])
        }

        let files = rels.map { ($0, root) }
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: files)

        // For each rel, verify its canonical key isolates that exact rel in byLastTwo
        for rel in rels {
            // last two components string == rel (each rel is exactly 2 components here)
            let key = snapshot.canonical(rel)
            XCTAssertTrue(key.contains("/"), "Key for \(rel) should preserve '/'")

            let bucket = (snapshot.indexes.byLastTwo[key] ?? []).map { $0.relativePath }.sorted()
            XCTAssertEqual(bucket, [rel], "byLastTwo[\(key)] should isolate \(rel)")
        }
    }

    func testCanonicalUnicodeFallback_LowercasingOnce() async {
        // Includes non-ASCII to force the Unicode fallback path
        let s = "FöÖ/Bar-[X]"
        let lower = PathMatchIndexes.canonical(s, caseSensitive: false)
        let exact = PathMatchIndexes.canonical(s, caseSensitive: true)

        // Lowercased result should be lower, preserve '/', and keep allowed punctuation
        XCTAssertEqual(lower, "föö/bar-[x]")
        XCTAssertTrue(lower.contains("/"))
        XCTAssertEqual(exact, "FöÖ/Bar-[X]")
    }

	func testPolicyParity_CanonicalVsCleaned_ASCII() async {
		// These chars should be preserved by both cleaned() and canonical(caseSensitive: true)
		let ascii = "Aa0._-[](){}+!#%@/Zz"
		let canon = PathMatchIndexes.canonical(ascii, caseSensitive: true)
		XCTAssertEqual(canon, ascii)

		// Disallowed chars (e.g., '&', '^', '~') should still be stripped
		let withDisallowed = "A&B^C~_[]"
		let canonDropped = PathMatchIndexes.canonical(withDisallowed, caseSensitive: true)
		XCTAssertEqual(canonDropped, "ABC_[]")
	}
    
    // MARK: - Underscore/Dash Regression Tests
    
    func testLeadingUnderscore_FileNameOnly_Resolves() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/_variables.scss", "/Users/test/project")
        ])
        PathMatcherTestHelper.assertResolves("variables.scss", to: "src/_variables.scss", in: snapshot)
    }
    
    func testHyphenUnderscore_Equivalence_SingleComponent() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/user_profile.js", "/Users/test/project"),
            ("src/user-profile.js", "/Users/test/project")
        ])
        // Either should match sensibly; pick a deterministic shallowest/tie-breaker as you prefer
        XCTAssertNotNil(PathMatcherTestHelper.getResolvedPath("user-profile.js", in: snapshot))
        XCTAssertNotNil(PathMatcherTestHelper.getResolvedPath("user_profile.js", in: snapshot))
    }
    
    func testHyphenUnderscore_Equivalence_MultiComponent() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("pkg/my-utils/foo_bar.ts", "/Users/test/app")
        ])
        PathMatcherTestHelper.assertResolves("my-utils/foo-bar.ts", to: "pkg/my-utils/foo_bar.ts", in: snapshot)
    }
    
    func testLeadingUnderscore_VariousScenarios() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/_components/Button.tsx", "/Users/test/project"),
            ("src/_utils/helper.js", "/Users/test/project"),
            ("tests/_fixtures/data.json", "/Users/test/project"),
            ("lib/_internal/config.ts", "/Users/test/project")
        ])
        
        // Leading underscore files should match without underscore prefix
        PathMatcherTestHelper.assertResolves("components/Button.tsx", to: "src/_components/Button.tsx", in: snapshot)
        PathMatcherTestHelper.assertResolves("utils/helper.js", to: "src/_utils/helper.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("fixtures/data.json", to: "tests/_fixtures/data.json", in: snapshot)
        PathMatcherTestHelper.assertResolves("internal/config.ts", to: "lib/_internal/config.ts", in: snapshot)
        
        // File names without directory should also work
        PathMatcherTestHelper.assertResolves("Button.tsx", to: "src/_components/Button.tsx", in: snapshot)
        PathMatcherTestHelper.assertResolves("helper.js", to: "src/_utils/helper.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("data.json", to: "tests/_fixtures/data.json", in: snapshot)
        PathMatcherTestHelper.assertResolves("config.ts", to: "lib/_internal/config.ts", in: snapshot)
    }
    
    func testSeparatorEquivalence_ComplexCases() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/components/user-profile-card.tsx", "/Users/test/project"),
            ("src/utils/date_formatter_util.js", "/Users/test/project"),
            ("tests/auth-service_test.spec.js", "/Users/test/project"),
            ("lib/data-parser_v2-stable.ts", "/Users/test/project")
        ])
        
        // Mixed separator queries should match mixed separator files
        PathMatcherTestHelper.assertResolves("user_profile_card.tsx", to: "src/components/user-profile-card.tsx", in: snapshot)
        PathMatcherTestHelper.assertResolves("date-formatter-util.js", to: "src/utils/date_formatter_util.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("auth_service-test.spec.js", to: "tests/auth-service_test.spec.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("data_parser-v2_stable.ts", to: "lib/data-parser_v2-stable.ts", in: snapshot)
        
        // Multi-component paths with separator differences
        PathMatcherTestHelper.assertResolves("components/user_profile_card.tsx", to: "src/components/user-profile-card.tsx", in: snapshot)
        PathMatcherTestHelper.assertResolves("utils/date-formatter-util.js", to: "src/utils/date_formatter_util.js", in: snapshot)
    }
    
    func testLeadingUnderscore_WithExtensionMatching() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("scss/_variables.scss", "/Users/test/project"),
            ("scss/_mixins.scss", "/Users/test/project"),
            ("js/_private.js", "/Users/test/project"),
            ("css/_base.css", "/Users/test/project")
        ])
        
        // Extension matching should work with leading underscores
        PathMatcherTestHelper.assertResolves("variables.scss", to: "scss/_variables.scss", in: snapshot)
        PathMatcherTestHelper.assertResolves("mixins.scss", to: "scss/_mixins.scss", in: snapshot)
        PathMatcherTestHelper.assertResolves("private.js", to: "js/_private.js", in: snapshot)
        PathMatcherTestHelper.assertResolves("base.css", to: "css/_base.css", in: snapshot)
    }
}
