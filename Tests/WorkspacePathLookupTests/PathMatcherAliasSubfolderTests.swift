import XCTest
@testable import WorkspacePathLookup

/// Tests for the canonical root-alias policy.
///
/// A leading root alias is consumed exactly once across matching and creation.
/// If a workspace root contains a literal same-name top-level folder, callers
/// must repeat the alias to address it explicitly:
/// - `RepoPrompt/ViewModels/File.swift` -> root-relative `ViewModels/File.swift`
/// - `RepoPrompt/RepoPrompt/ViewModels/File.swift` -> literal `RepoPrompt/ViewModels/File.swift`
final class PathMatcherAliasSubfolderTests: XCTestCase {

    // MARK: - locate() Tests

    func testLocateConsumesLeadingAliasEvenWhenSameNameSubfolderExists() async {
        let rootPath = "/Users/test/RepoPrompt"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("ViewModels/MCPServerViewModel.swift", rootPath),
            ("RepoPrompt/ViewModels/MCPServerViewModel.swift", rootPath)
        ])

        PathMatcherTestHelper.assertResolves(
            "RepoPrompt/ViewModels/MCPServerViewModel.swift",
            to: "ViewModels/MCPServerViewModel.swift",
            in: snapshot
        )

        PathMatcherTestHelper.assertResolves(
            "RepoPrompt/RepoPrompt/ViewModels/MCPServerViewModel.swift",
            to: "RepoPrompt/ViewModels/MCPServerViewModel.swift",
            in: snapshot
        )
    }

    func testLocateWithAliasOnlyNoSubfolder() async {
        let rootPath = "/Users/test/MyApp"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("ViewModels/MainViewModel.swift", rootPath),
            ("Models/User.swift", rootPath)
        ])

        PathMatcherTestHelper.assertResolves(
            "MyApp/ViewModels/MainViewModel.swift",
            to: "ViewModels/MainViewModel.swift",
            in: snapshot
        )
    }

    func testLocatePrefersExplicitDoublePrefixForLiteralSameNameFolder() async {
        let rootPath = "/Users/test/RepoPrompt"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("RepoPrompt/File.swift", rootPath),
            ("File.swift", rootPath)
        ])

        PathMatcherTestHelper.assertResolves(
            "RepoPrompt/File.swift",
            to: "File.swift",
            in: snapshot
        )

        PathMatcherTestHelper.assertResolves(
            "RepoPrompt/RepoPrompt/File.swift",
            to: "RepoPrompt/File.swift",
            in: snapshot
        )
    }

    func testLocateCaseInsensitiveDoublePrefixKeepsLiteralSameNameFolder() async {
        let rootPath = "/Users/test/RepoPrompt"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("RepoPrompt/ViewModels/File.swift", rootPath)
        ])

        PathMatcherTestHelper.assertResolves(
            "repoprompt/repoprompt/ViewModels/File.swift",
            to: "RepoPrompt/ViewModels/File.swift",
            in: snapshot
        )

        PathMatcherTestHelper.assertResolves(
            "REPOPROMPT/REPOPROMPT/ViewModels/File.swift",
            to: "RepoPrompt/ViewModels/File.swift",
            in: snapshot
        )
    }

    func testLocateMultipleRootsWithExplicitDoublePrefix() async {
        let rootA = "/Users/test/Frontend"
        let rootB = "/Users/test/Backend"

        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("Frontend/components/Button.tsx", rootA),
            ("src/server.js", rootB)
        ])

        PathMatcherTestHelper.assertResolves(
            "Frontend/Frontend/components/Button.tsx",
            to: "Frontend/components/Button.tsx",
            in: snapshot
        )

        let result = PathMatcher.locate(
            userPath: "Frontend/Frontend/components/Button.tsx",
            snapshot: snapshot
        )
        XCTAssertEqual(result?.rootPath, rootA)
    }

    // MARK: - findCreationPath() Tests

    func testCreationPathConsumesLeadingAliasEvenWhenSameNameSubfolderExists() async {
        let rootPath = "/Users/test/RepoPrompt"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(
            files: [
                ("RepoPrompt/ViewModels/ExistingFile.swift", rootPath),
                ("ViewModels/ExistingRootFile.swift", rootPath)
            ],
            folders: [
                ("RepoPrompt", rootPath),
                ("RepoPrompt/ViewModels", rootPath),
                ("ViewModels", rootPath)
            ]
        )

        PathMatcherTestHelper.assertCreationPath(
            "RepoPrompt/ViewModels/NewFile.swift",
            rootPath: rootPath,
            components: ["ViewModels", "NewFile.swift"],
            in: snapshot
        )
    }

    func testCreationPathAliasOnlyNoSubfolder() async {
        let rootPath = "/Users/test/MyApp"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(
            files: [
                ("ViewModels/ExistingFile.swift", rootPath)
            ],
            folders: [
                ("ViewModels", rootPath)
            ]
        )

        PathMatcherTestHelper.assertCreationPath(
            "MyApp/ViewModels/NewFile.swift",
            rootPath: rootPath,
            components: ["ViewModels", "NewFile.swift"],
            in: snapshot
        )
    }

    func testCreationPathNewSubfolderMatchingAlias() async {
        let rootPath = "/Users/test/MyProject"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(
            files: [
                ("src/main.swift", rootPath)
            ],
            folders: [
                ("src", rootPath)
            ]
        )

        PathMatcherTestHelper.assertCreationPath(
            "MyProject/NewFolder/NewFile.swift",
            rootPath: rootPath,
            components: ["NewFolder", "NewFile.swift"],
            in: snapshot
        )
    }

    func testCreationPathFileAtRootWithAliasPrefix() async {
        let rootPath = "/Users/test/MyApp"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(
            files: [
                ("existing.swift", rootPath)
            ],
            folders: []
        )

        PathMatcherTestHelper.assertCreationPath(
            "MyApp/NewFile.swift",
            rootPath: rootPath,
            components: ["NewFile.swift"],
            in: snapshot
        )
    }

    func testCreationPathDuplicateAliasPrefixDoesNotInsertAliasMidPath() async {
        let rootPath = "/Users/test/RepoPrompt"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(
            files: [],
            folders: [
                ("RepoPrompt", rootPath),
                ("RepoPrompt/Views", rootPath),
                ("RepoPrompt/Views/AgentMode", rootPath)
            ]
        )

        PathMatcherTestHelper.assertCreationPath(
            "RepoPrompt/RepoPrompt/Views/AgentMode/AgentWorkspaceRootsSectionView.swift",
            rootPath: rootPath,
            components: [
                "RepoPrompt",
                "Views",
                "AgentMode",
                "AgentWorkspaceRootsSectionView.swift"
            ],
            in: snapshot
        )
    }

    func testCreationPathDoublePrefixStillKeepsSingleLiteralSameNameSegmentWhenNestedFolderExists() async {
        let rootPath = "/Users/test/RepoPrompt"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(
            files: [],
            folders: [
                ("RepoPrompt", rootPath),
                ("RepoPrompt/RepoPrompt", rootPath),
                ("RepoPrompt/RepoPrompt/Views", rootPath),
                ("RepoPrompt/RepoPrompt/Views/AgentMode", rootPath)
            ]
        )

        PathMatcherTestHelper.assertCreationPath(
            "RepoPrompt/RepoPrompt/Views/AgentMode/AgentWorkspaceRootsSectionView.swift",
            rootPath: rootPath,
            components: [
                "RepoPrompt",
                "Views",
                "AgentMode",
                "AgentWorkspaceRootsSectionView.swift"
            ],
            in: snapshot
        )
    }

    // MARK: - Regression Tests

    func testOriginalBugScenarioNowRequiresDoublePrefixForLiteralSameNameFolder() async {
        let rootPath = "/Users/test/RepoPrompt"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("RepoPrompt/ViewModels/MCPServerViewModel.swift", rootPath)
        ])

        let single = PathMatcher.locate(
            userPath: "RepoPrompt/ViewModels/MCPServerViewModel.swift",
            snapshot: snapshot
        )
        XCTAssertNil(single, "Single alias prefix should resolve root-relative, not into a literal same-name subfolder")

        let doubled = PathMatcher.locate(
            userPath: "RepoPrompt/RepoPrompt/ViewModels/MCPServerViewModel.swift",
            snapshot: snapshot
        )
        XCTAssertNotNil(doubled)
        XCTAssertEqual(doubled?.correctedPath, "RepoPrompt/ViewModels/MCPServerViewModel.swift")
        XCTAssertEqual(doubled?.rootPath, rootPath)
    }

    func testAliasStrippingStillWorksWhenNoSubfolder() async {
        let rootPath = "/Users/test/MyProject"
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/main.swift", rootPath),
            ("tests/test.swift", rootPath)
        ])

        PathMatcherTestHelper.assertResolves("MyProject/src/main.swift", to: "src/main.swift", in: snapshot)
        PathMatcherTestHelper.assertResolves("myproject/tests/test.swift", to: "tests/test.swift", in: snapshot)
    }
}
