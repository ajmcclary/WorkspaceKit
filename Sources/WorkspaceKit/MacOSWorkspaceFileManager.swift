#if canImport(AppKit)

import Foundation

// MARK: - MacOS Workspace File Manager

/// macOS adapter conforming to both `WorkspaceFileTree` and
/// `WorkspaceFileWatching`.
///
/// Uses `FileManager` for directory enumeration and `FSEvents`
/// for file watching. Children are loaded lazily — only cached
/// directories are refreshed on FSEvents.
@MainActor
public final class MacOSWorkspaceFileManager: WorkspaceFileTree, WorkspaceFileWatching {
    // MARK: - Types

    private struct CacheEntry {
        let node: WorkspaceFileNode
        var children: [WorkspaceFileNode]
        var isLoaded = false
    }

    // MARK: - State

    private let fileManager = FileManager.default
    private var cache: [String: CacheEntry] = [:]
    private var eventContinuation: AsyncStream<WorkspaceFileEvent>.Continuation?
    private var eventStream: AsyncStream<WorkspaceFileEvent>?
    private var streamTask: Task<Void, Never>?

    private let rootURL: URL
    public let root: WorkspaceFileNode

    // MARK: - Initialization

    public init(rootURL: URL) {
        self.rootURL = rootURL
        let rootName = rootURL.lastPathComponent
        self.root = WorkspaceFileNode(
            name: rootName,
            url: rootURL,
            isDirectory: true,
            children: []
        )
        cache[root.id] = CacheEntry(node: root, children: [])
    }

    // MARK: - WorkspaceFileTree

    public func children(of node: WorkspaceFileNode) -> [WorkspaceFileNode] {
        guard node.isDirectory else { return [] }

        // Return cached children if loaded.
        if let entry = cache[node.id], entry.isLoaded {
            return entry.children
        }

        // Load lazily.
        let loaded = loadChildren(of: node.url)
        cache[node.id] = CacheEntry(node: node, children: loaded, isLoaded: true)
        return loaded
    }

    public func isDirectory(_ node: WorkspaceFileNode) -> Bool {
        node.isDirectory
    }

    public func fileURL(for node: WorkspaceFileNode) -> URL {
        node.url
    }

    public func refresh(node: WorkspaceFileNode) async throws {
        guard node.isDirectory else { return }
        let loaded = loadChildren(of: node.url)
        cache[node.id] = CacheEntry(node: node, children: loaded, isLoaded: true)
    }

    // MARK: - WorkspaceFileWatching

    public func startWatching(root: URL) async throws {
        // Create the event stream.
        let (stream, continuation) = AsyncStream<WorkspaceFileEvent>.makeStream()
        eventStream = stream
        eventContinuation = continuation

        // Use a polling approach with FileManager instead of FSEvents
        // for broader compatibility. FSEvents can be added as a future
        // optimization via `FSEventStreamCreate`.
        streamTask = Task { [weak self] in
            guard let self else { return }
            var lastModDates: [String: Date] = [:]
            // Initial snapshot
            await self.snapshotModDates(into: &lastModDates, at: root)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s poll
                await self.pollChanges(previousDates: &lastModDates, at: root, continuation: continuation)
            }
        }
    }

    public func stopWatching() {
        streamTask?.cancel()
        streamTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        eventStream = nil
    }

    public var events: AsyncStream<WorkspaceFileEvent> {
        eventStream ?? AsyncStream { $0.finish() }
    }

    // MARK: - Private

    private func loadChildren(of directoryURL: URL) -> [WorkspaceFileNode] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let nodes = contents.compactMap { url -> WorkspaceFileNode? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return WorkspaceFileNode(
                name: url.lastPathComponent,
                url: url,
                isDirectory: isDir,
                children: []
            )
        }
        return nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func snapshotModDates(into dates: inout [String: Date], at url: URL) async {
        enumerateFiles(at: url, into: &dates)
    }

    private func enumerateFiles(at url: URL, into dates: inout [String: Date]) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for fileURL in contents {
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                enumerateFiles(at: fileURL, into: &dates)
            } else {
                let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                dates[fileURL.path] = modDate
            }
        }
    }

    private func pollChanges(
        previousDates: inout [String: Date],
        at url: URL,
        continuation: AsyncStream<WorkspaceFileEvent>.Continuation
    ) async {
        var newDates: [String: Date] = [:]
        await snapshotModDates(into: &newDates, at: url)

        // Detect new and modified files.
        for (path, newDate) in newDates {
            if let oldDate = previousDates[path] {
                if newDate > oldDate {
                    continuation.yield(.modified(url: URL(fileURLWithPath: path)))
                }
            } else {
                continuation.yield(.created(url: URL(fileURLWithPath: path)))
            }
        }

        // Detect deleted files.
        for (path, _) in previousDates where newDates[path] == nil {
            continuation.yield(.deleted(url: URL(fileURLWithPath: path)))
        }

        previousDates = newDates
    }
}

#endif // canImport(AppKit)
