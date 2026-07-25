import Foundation
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
	/// Pumps `FileSystemService.changesStream()` — a `Sendable` AsyncStream —
	/// into this `@MainActor` adapter's own event stream. Combine's
	/// `AnyCancellable` cannot cross the actor boundary under Swift 6, so the
	/// engine-side subscription is owned by the engine actor and this side owns
	/// only a `Task`.
	private var forwardingTask: Task<Void, Never>?
	private var eventContinuation: AsyncStream<WorkspaceFileEvent>.Continuation?
	private var eventStream: AsyncStream<WorkspaceFileEvent>?
	private var rootURL: URL?
	private let respectGitignore: Bool

	public init(respectGitignore: Bool = true) {
		self.respectGitignore = respectGitignore
	}

	/// Restores the teardown-on-dealloc the replaced `AnyCancellable` provided.
	///
	/// Releasing a `Task` handle does NOT cancel the task, so a watcher dropped
	/// without an explicit `stopWatching()` would otherwise leave the forwarder
	/// suspended in `for await batch in deltas` forever — and with it the
	/// engine-side `changesStream()` subscription, whose `onTermination` only
	/// fires once the stream is torn down. The `[weak self]` guard inside the
	/// loop does not help: it is only reached when a batch actually arrives,
	/// which for an abandoned watcher may be never.
	///
	/// `isolated deinit` is required because the stored property is
	/// `@MainActor`-isolated; it is available at this package's macOS 27 floor.
	isolated deinit {
		forwardingTask?.cancel()
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
		let deltas = await service.changesStream()
		await service.startWatchingForChanges()
		forwardingTask = Task { @MainActor [weak self] in
			for await batch in deltas {
				guard let self else { return }
				// Same per-batch semantics as the old Combine sink: a batch
				// arriving while no continuation is installed is dropped, it
				// does not tear the forwarder down.
				guard let continuation = self.eventContinuation else { continue }
				for delta in batch {
					continuation.yield(Self.event(for: delta, base: base))
				}
			}
		}
	}

	public func stopWatching() {
		forwardingTask?.cancel()
		forwardingTask = nil
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
