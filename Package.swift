// swift-tools-version: 6.0
import PackageDescription

// WorkspaceKit — neutral workspace file-tree contracts + adapters.
//
// Promoted out of CodeEditorPlugin's CodeEditorWorkspace target (workspace
// decomposition step 5). CodeEditorPlugin's CodeEditorWorkspace product is
// now an @_exported re-export shim over this package; apps/CodeEditorDemo
// consumes the contracts through that shim. Zero dependencies; the
// MacOSWorkspaceFileManager adapter is #if canImport(AppKit)-gated.
let package = Package(
    name: "WorkspaceKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "WorkspaceKit", targets: ["WorkspaceKit", "WorkspaceIgnore", "WorkspacePathsCore", "WorkspacePathLookup", "WorkspaceKitCSupport"])
    ],
    targets: [
        .target(name: "WorkspaceKit"),
        // Gitignore-aware ignore-rules stack (compiler, hierarchical
        // evaluator, caches), promoted verbatim from RepoPrompt's
        // Infrastructure/FileSystem in adoption slice 1. Swift 5 language
        // mode to keep the moved code byte-behaviorally identical
        // (RepoPromptCore precedent); the contracts target stays v6.
        .target(
            name: "WorkspaceIgnore",
            dependencies: ["WorkspaceKitCSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Bundled wildmatch matcher + gitignore-compatible wrappers
        // (promoted from RepoPrompt's Support/C/wildmatch in adoption
        // slice 1; RepoPrompt's remaining direct C callers reach these
        // symbols through this target).
        .target(name: "WorkspaceKitCSupport"),
        // Workspace path lookup/matching (PathMatcher + frozen records +
        // worker), promoted verbatim from RepoPrompt's
        // Infrastructure/WorkspaceContext/PathLookup in adoption slice 2.
        // Deliberately self-contained pure Swift — PathMatcher implements
        // its own capped Levenshtein and does NOT call the repo_* C
        // similarity helpers (see PathMatcher.swift header comment).
        .target(
            name: "WorkspacePathLookup",
            dependencies: ["WorkspacePathsCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Pure path/URL string utilities (StandardizedPath, RelativePath,
        // slug helpers), promoted from RepoPromptCore's WorkspacePaths in
        // adoption slice 2 — that target is now an @_exported shim over
        // this one (ProcessCore/ProcessKit precedent).
        .target(
            name: "WorkspacePathsCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "WorkspaceKitTests", dependencies: ["WorkspaceKit", "WorkspaceIgnore"]),
        .testTarget(
            name: "WorkspacePathLookupTests",
            dependencies: ["WorkspacePathLookup"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WorkspaceIgnoreTests",
            dependencies: ["WorkspaceIgnore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
