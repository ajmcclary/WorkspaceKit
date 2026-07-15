# WorkspaceKit

Neutral workspace file-tree contracts and adapters:

- `WorkspaceFileNode` / `WorkspaceFileEvent` — value types for lazily
  materialized file trees and file-system change events.
- `WorkspaceFileTree` / `WorkspaceFileWatching` — `@MainActor` protocols for
  tree traversal and change watching.
- `MacOSWorkspaceFileManager` — `FileManager`-backed adapter conforming to
  both protocols (polling watcher; `#if canImport(AppKit)`-gated).

Zero dependencies. Swift 6 strict concurrency. Floors: macOS 14 / iOS 17.

Consumers: `CodeEditorPlugin` (its `CodeEditorWorkspace` product is an
`@_exported` shim over this package) and, through that shim, the CodeEditor
workspace's `CodeEditorDemo` app.
