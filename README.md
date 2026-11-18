# WorkspaceKit

Workspace file-tree contracts, gitignore-aware filtering, and a recursive file-system watcher
for macOS editor tooling.

WorkspaceKit covers the parts of an editor that deal with "the folder the user opened": a lazily
loaded file tree, `.gitignore`-compatible ignore rules, an FSEvents-backed scan/watch engine that
publishes change deltas, path-search and path-matching primitives, and the small C library that
backs the hot loops. It has no third-party dependencies; the one piece of bundled third-party
code (wildmatch) is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## What's inside

The package ships one library product, `WorkspaceKit`, that makes seven modules importable:

| Module | Role |
|---|---|
| `WorkspaceKit` | The file-tree contracts and the simple macOS adapter. |
| `WorkspaceIgnore` | Gitignore-aware ignore-rules stack. |
| `WorkspaceFileSystem` | FSEvents-backed scan/watch/delta engine. |
| `WorkspaceSearch` | Workspace file-search index, query parsing and batch scoring. |
| `WorkspacePathLookup` | Resolving user- or model-supplied paths against a workspace. |
| `WorkspacePathsCore` | Pure path-string utilities (no file-system I/O). |
| `WorkspaceKitCSupport` | C target: wildmatch plus the `repo_*` matching/similarity functions. |

Key public types:

- `WorkspaceFileNode` / `WorkspaceFileEvent` — value types for a node in a lazily materialized
  tree and for a created / modified / deleted / renamed change.
- `WorkspaceFileTree` / `WorkspaceFileWatching` — `@MainActor` protocols for tree traversal and
  change watching.
- `MacOSWorkspaceFileManager` — `FileManager`-backed adapter conforming to both protocols. Children
  load lazily and sort Finder-style; watching polls every two seconds. Simple, no FSEvents.
- `FileSystemServiceWorkspaceWatcher` — the recursive, FSEvents-driven `WorkspaceFileWatching`
  alternative, backed by `FileSystemService`. It walks the tree before returning so existing
  files are tracked; renames arrive as a delete plus a create.
- `FileSystemService` — actor that scans a directory, watches it via FSEvents, honours ignore
  rules, and publishes `FileSystemDelta` batches. Content decoding goes through the
  `WorkspaceCharsetDetecting` seam; `FoundationOnlyCharsetDetector` is the built-in default.
- `IgnoreRules` — layered, `Sendable` ignore rules that start from a default layer (`.git`,
  `.DS_Store`, …); add `.gitignore` content with `addIgnoreFile(content:priority:directoryPath:)`.
  `GitignoreCompiler`, `HierarchicalIgnoreEvaluator` and `IgnoreRulesManager` handle compilation,
  nested ignore files and caching.
- `PathSearchIndex`, `RepoSearchQuery`, `RepoSearchBatchScorer` — fuzzy file search over a
  workspace.
- `PathMatcher`, `PathMatchWorker` — resolve a possibly partial or misspelled path to workspace
  files, including where a new file should be created.
- `StandardizedPath`, `RelativePath` — standardize, join, relativize and containment-check path
  strings.

## When to use it

- You are building a macOS editor or agent tool that needs a workspace file tree, change events,
  and `.gitignore` semantics that match git.
- You need a recursive watcher that reports deltas relative to a root rather than raw FSEvents.
- You want `MacOSWorkspaceFileManager` as a dependency-free polling tree for a small tool.

## When not to use it

- **iOS or Linux.** The package is macOS-only (see Requirements).
- **Applying edits or computing diffs.** That is ApplyEditsKit, which depends on this package and
  links the `repo_*` similarity functions from `WorkspaceKitCSupport`.
- **Language detection.** Use LanguageKit.
- **Editor integration.** CodeEditorKit's `CodeEditorWorkspace` product re-exports the
  `WorkspaceKit` module; if you already use CodeEditorKit, import that instead of adding this
  package directly.

Out of scope: third-party charset detection backends (inject one through
`WorkspaceCharsetDetecting`), persistence, project/workspace settings, and UI.

## Installation

```swift
dependencies: [
    // 0.1.0-beta.15 is a prerelease identifier — SwiftPM only resolves
    // prerelease tags when the lower bound itself names one.
    .package(url: "https://github.com/ajmcclary/WorkspaceKit.git", .upToNextMinor(from: "0.1.0-beta.15"))
]
```

```swift
.target(
    name: "MyTool",
    dependencies: [.product(name: "WorkspaceKit", package: "WorkspaceKit")]
)
```

Then `import` whichever modules you use (`WorkspaceKit`, `WorkspaceIgnore`, …).

## Usage

List the files a workspace shows after applying its `.gitignore`, then watch it for changes:

```swift
import Foundation
import WorkspaceKit
import WorkspaceIgnore
import WorkspaceFileSystem
import WorkspacePathsCore

@MainActor
func visibleFiles(in root: URL, gitignore: String) -> [String] {
    let tree = MacOSWorkspaceFileManager(rootURL: root)
    let rules = IgnoreRules()  // default layer already ignores .git, .DS_Store, …
    rules.addIgnoreFile(content: gitignore, priority: 1)

    var files: [String] = []
    var pending = [tree.root]
    while let directory = pending.popLast() {
        for child in tree.children(of: directory) {
            let path = RelativePath.from(absolutePath: child.url.path, rootPath: root.path)
            if rules.isIgnored(relativePath: path, isDirectory: child.isDirectory) { continue }
            if child.isDirectory { pending.append(child) } else { files.append(path) }
        }
    }
    return files.sorted()
}

@MainActor
func watch(_ root: URL) async throws {
    let watcher = FileSystemServiceWorkspaceWatcher(respectGitignore: true)
    try await watcher.startWatching(root: root)
    defer { watcher.stopWatching() }
    for await event in watcher.events {
        switch event {
        case .created(let url), .modified(let url), .deleted(let url):
            print(event, url.lastPathComponent)
        case .renamed(let old, let new):
            print("renamed", old.lastPathComponent, "->", new.lastPathComponent)
        }
    }
}
```

## Requirements

- Swift tools 6.0; every Swift target builds in Swift 6 language mode with strict concurrency.
- **macOS 27 only.** `FileSystemService` in the `WorkspaceFileSystem` module uses the FSEvents C
  API unconditionally, and FSEvents does not exist on iOS, so the library product cannot be built
  for iOS (`xcodebuild -destination 'generic/platform=iOS'` fails with "cannot find type
  'FSEventStreamRef' in scope"). Supporting iOS would first require platform-gating
  `WorkspaceFileSystem`. (`MacOSWorkspaceFileManager` is additionally `#if canImport(AppKit)`.)
- Dependencies: none. The bundled wildmatch C sources are covered by
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Stability

Pre-1.0 (`0.x` beta): the public API may change between minor versions; pin `.upToNextMinor`.

## Development

`swift build` / `swift test` — fast, exercises a real temporary directory tree; the watcher tests
poll for about two seconds.

## Origin

Extracted from CodeEditorKit and the RepoPrompt app.

## License

Apache License 2.0 — see [LICENSE](LICENSE). Bundled third-party code is listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
