# WorkspaceKit

Neutral workspace file-tree contracts and adapters:

- `WorkspaceFileNode` / `WorkspaceFileEvent` — value types for lazily
  materialized file trees and file-system change events.
- `WorkspaceFileTree` / `WorkspaceFileWatching` — `@MainActor` protocols for
  tree traversal and change watching.
- `MacOSWorkspaceFileManager` — `FileManager`-backed adapter conforming to
  both protocols (polling watcher; `#if canImport(AppKit)`-gated).

Also ships:

- `WorkspaceIgnore` — gitignore-aware ignore-rules stack (compiler,
  hierarchical evaluator, caches), promoted verbatim from RepoPrompt
  (adoption slice 1; Swift 5 language mode to keep the moved code
  byte-behaviorally identical).
- `WorkspaceKitCSupport` — bundled wildmatch matcher + gitignore-compatible
  `repo_*` wrappers backing the ignore stack.

Zero external dependencies. Every Swift target (and every test target) builds
in Swift 6 language mode with `StrictConcurrency` enabled.

Floor: **macOS 27 — macOS only.** The `WorkspaceFileSystem` target's
`FileSystemService` uses the FSEvents C API unconditionally, and FSEvents does
not exist on iOS, so the library product cannot cross-compile for iOS
(`xcodebuild -destination 'generic/platform=iOS'` fails with "cannot find type
'FSEventStreamRef' in scope"). The previously declared `.iOS(.v17)` floor was
never backed by a working build. Restoring an iOS floor requires
platform-gating `WorkspaceFileSystem` first.

Consumers: `CodeEditorKit` (its `CodeEditorWorkspace` product is an
`@_exported` shim over this package) and, through that shim, the CodeEditor
workspace's `CodeEditorDemo` app.
