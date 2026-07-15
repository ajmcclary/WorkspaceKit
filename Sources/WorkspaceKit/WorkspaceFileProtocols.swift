import Foundation

// MARK: - Workspace File Protocols

/// A node in the workspace file tree. Represents a file or directory.
public struct WorkspaceFileNode: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let isDirectory: Bool
    /// Cached children file names for directories. Empty for files.
    public var children: [String]

    public init(
        name: String,
        url: URL,
        isDirectory: Bool,
        children: [String] = [],
        id: String? = nil
    ) {
        self.id = id ?? url.absoluteString
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
    }
}

/// Events emitted by workspace file watching.
public enum WorkspaceFileEvent: Sendable {
    case created(url: URL)
    case modified(url: URL)
    case deleted(url: URL)
    case renamed(oldURL: URL, newURL: URL)
}

// MARK: - WorkspaceFileTree

/// Protocol for lazily materializing a workspace file tree.
///
/// Only root children are loaded initially; deeper nodes are
/// loaded on demand via `children(of:)`.
@MainActor
public protocol WorkspaceFileTree: AnyObject {
    /// The root node of the file tree (the workspace directory itself).
    var root: WorkspaceFileNode { get }

    /// Returns the children of a directory node. Files return `[]`.
    func children(of node: WorkspaceFileNode) -> [WorkspaceFileNode]

    /// Returns `true` if the node represents a directory.
    func isDirectory(_ node: WorkspaceFileNode) -> Bool

    /// Returns the file URL for a node.
    func fileURL(for node: WorkspaceFileNode) -> URL

    /// Refresh the cached children of a directory node.
    func refresh(node: WorkspaceFileNode) async throws
}

// MARK: - WorkspaceFileWatching

/// Protocol for watching file-system changes in a workspace.
@MainActor
public protocol WorkspaceFileWatching: AnyObject {
    /// Start watching a root directory.
    func startWatching(root: URL) async throws

    /// Stop watching.
    func stopWatching()

    /// An async stream of file events.
    var events: AsyncStream<WorkspaceFileEvent> { get }
}
