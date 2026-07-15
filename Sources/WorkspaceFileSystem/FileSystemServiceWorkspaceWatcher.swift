import Foundation
import Combine
import WorkspaceKit

/// FSEvents-grade `WorkspaceFileWatching` adapter backed by the promoted
/// `FileSystemService` engine (adoption slice 5 — watcher unification).
///
/// `MacOSWorkspaceFileManager` remains the dependency-free polling option
/// for simple consumers; this adapter is the recursive, FSEvents-driven
/// alternative. Deltas map as: added → `.created`, removed → `.deleted`,
/// modified → `.modified`. The engine reports renames as remove+add pairs,
/// so `.renamed` is never emitted here.
@MainActor
public final class FileSystemServiceWorkspaceWatcher: WorkspaceFileWatching {
	private var service: FileSystemService?
	private var subscription: AnyCancellable?
	private var eventContinuation: AsyncStream<WorkspaceFileEvent>.Continuation?
	private var eventStream: AsyncStream<WorkspaceFileEvent>?
	private var rootURL: URL?
	private let respectGitignore: Bool

	public init(respectGitignore: Bool = true) {
		self.respectGitignore = respectGitignore
	}

	public func startWatching(root: URL) async throws {
		stopWatching()

		let service = try await FileSystemService(
			path: root.standardizedFileURL.path,
			respectGitignore: respectGitignore
		)
		self.service = service
		self.rootURL = root.standardizedFileURL

		let (stream, continuation) = AsyncStream<WorkspaceFileEvent>.makeStream()
		eventStream = stream
		eventContinuation = continuation

		let base = root.standardizedFileURL
		await service.startWatchingForChanges()
		subscription = await service.publisherForChanges()
			.sink { [weak self] deltas in
				guard let self, let continuation = self.eventContinuation else { return }
				for delta in deltas {
					continuation.yield(Self.event(for: delta, base: base))
				}
			}
	}

	public func stopWatching() {
		subscription?.cancel()
		subscription = nil
		if let service {
			let retained = service
			Task { await retained.stopWatchingForChanges() }
		}
		service = nil
		rootURL = nil
		eventContinuation?.finish()
		eventContinuation = nil
		eventStream = nil
	}

	public var events: AsyncStream<WorkspaceFileEvent> {
		eventStream ?? AsyncStream { $0.finish() }
	}

	private static func event(for delta: FileSystemDelta, base: URL) -> WorkspaceFileEvent {
		func url(_ relative: String) -> URL {
			base.appendingPathComponent(relative)
		}
		switch delta {
		case .fileAdded(let path), .folderAdded(let path):
			return .created(url: url(path))
		case .fileRemoved(let path), .folderRemoved(let path):
			return .deleted(url: url(path))
		case .fileModified(let path, _), .folderModified(let path, _):
			return .modified(url: url(path))
		}
	}
}
