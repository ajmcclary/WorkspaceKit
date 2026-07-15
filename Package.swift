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
        .library(name: "WorkspaceKit", targets: ["WorkspaceKit"])
    ],
    targets: [
        .target(name: "WorkspaceKit"),
        .testTarget(name: "WorkspaceKitTests", dependencies: ["WorkspaceKit"])
    ]
)
