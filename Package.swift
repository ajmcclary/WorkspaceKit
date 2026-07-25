// swift-tools-version: 6.0
import PackageDescription

// Workspace-standard Swift 6 settings. Every Swift target and test target in
// this package carries this array so the language-mode policy is checkable
// per target. C targets take no language mode.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableExperimentalFeature("StrictConcurrency")
]

// WorkspaceKit — neutral workspace file-tree contracts + adapters.
//
// Promoted out of CodeEditorKit's CodeEditorWorkspace target (workspace
// decomposition step 5). CodeEditorKit's CodeEditorWorkspace product is
// now an @_exported re-export shim over this package; apps/CodeEditorDemo
// consumes the contracts through that shim. Zero dependencies; the
// MacOSWorkspaceFileManager adapter is #if canImport(AppKit)-gated.
let package = Package(
    name: "WorkspaceKit",
    // macOS ONLY — the former `.iOS(.v17)` line was an unbacked declaration.
    //
    // The single `WorkspaceKit` library product includes the
    // `WorkspaceFileSystem` target, whose `FileSystemService` uses the FSEvents
    // C API (`FSEventStreamRef`, `FSEventStreamCallback`,
    // `FSEventStreamEventFlags`, `FSEventStreamEventId`,
    // `kFSEventStreamEventFlag*`) unconditionally — none of it sits behind an
    // `#if os(macOS)` guard, and FSEvents does not exist on iOS. Verified:
    //   xcodebuild -scheme WorkspaceKit -destination 'generic/platform=iOS' build
    // failed with "cannot find type 'FSEventStreamRef' in scope" (and siblings)
    // in FileSystemService.swift while `.iOS("27.0")` was still declared. That
    // is long-standing, and is the documented reason ApplyEditsKit — which
    // depends on this package — is macOS-only.
    //
    // With no iOS floor declared, an iOS build now trips the default (very old)
    // iOS deployment target first and reports `Mutex` (iOS 18+) and
    // `isolated deinit` (iOS 18.4+) availability errors before it ever reaches
    // the FSEvents ones. Both are symptoms of building an unsupported
    // platform. Restoring an iOS floor requires platform-gating
    // `WorkspaceFileSystem` first.
    //
    // NOTE: `swift build --triple arm64-apple-ios27.0` is NOT a valid check
    // here — it reports "Build complete!" while emitting macOS objects
    // (LC_BUILD_VERSION platform 1). Only xcodebuild with an iOS destination
    // actually cross-compiles.
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(name: "WorkspaceKit", targets: ["WorkspaceKit", "WorkspaceIgnore", "WorkspacePathsCore", "WorkspacePathLookup", "WorkspaceSearch", "WorkspaceFileSystem", "WorkspaceKitCSupport"])
    ],
    targets: [
        .target(name: "WorkspaceKit", swiftSettings: swiftSettings),
        // Gitignore-aware ignore-rules stack (compiler, hierarchical
        // evaluator, caches), promoted verbatim from RepoPrompt's
        // Infrastructure/FileSystem in adoption slice 1.
        .target(
            name: "WorkspaceIgnore",
            dependencies: ["WorkspaceKitCSupport"],
            swiftSettings: swiftSettings
        ),
        // The workspace scan/watch/delta engine: the FileSystemService actor
        // promoted from RepoPrompt in adoption slice 4. Content decoding
        // rides the WorkspaceCharsetDetecting seam (CharsetDetection.swift)
        // so the Cuchardet/UniversalCharsetDetection third-party backends
        // stay app-side and this package stays zero-dependency.
        .target(
            name: "WorkspaceFileSystem",
            dependencies: ["WorkspaceKit", "WorkspaceIgnore", "WorkspacePathsCore"],
            swiftSettings: swiftSettings
        ),
        // Workspace file-search primitives (path search index, batch scorer,
        // query parsing), promoted verbatim from RepoPrompt's
        // Infrastructure/WorkspaceContext/Search in adoption slice 3. The
        // repo_file_info / repo_score_matches_batch C backends live in
        // WorkspaceKitCSupport (path_search.c, search_scoring.c).
        .target(
            name: "WorkspaceSearch",
            dependencies: ["WorkspaceKitCSupport"],
            swiftSettings: swiftSettings
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
            swiftSettings: swiftSettings
        ),
        // Pure path/URL string utilities (StandardizedPath, RelativePath,
        // slug helpers), promoted from RepoPromptCore's WorkspacePaths in
        // adoption slice 2 — that target is now an @_exported shim over
        // this one (ProcessCore/ProcessKit precedent).
        .target(
            name: "WorkspacePathsCore",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WorkspaceKitTests",
            dependencies: ["WorkspaceKit", "WorkspaceIgnore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WorkspacePathLookupTests",
            dependencies: ["WorkspacePathLookup"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WorkspaceSearchTests",
            dependencies: ["WorkspaceSearch"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WorkspaceFileSystemTests",
            dependencies: ["WorkspaceFileSystem"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WorkspaceIgnoreTests",
            dependencies: ["WorkspaceIgnore"],
            swiftSettings: swiftSettings
        )
    ]
)
