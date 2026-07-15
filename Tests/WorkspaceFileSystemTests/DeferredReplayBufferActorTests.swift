import XCTest
@testable import WorkspaceFileSystem
@testable import WorkspaceIgnore

final class DeferredReplayBufferActorTests: XCTestCase {
	func testIngressQueuesWhileUnfocusedAndDrainsPreparedBatchesInPreferredRootOrder() async throws {
		let actor = DeferredReplayBufferActor(maxPendingDeltasPerRoot: 32)
		let rootA = "/tmp/replay-root-a"
		let rootB = "/tmp/replay-root-b"
		await actor.updateRoutingState(isWindowFocused: false, isReplayActive: false, routingVersion: 1)

		let ingressB = await actor.ingestLiveDeltas(
			[.folderAdded("Sources-B"), .fileAdded("Sources-B/B.swift")],
			forRootKey: rootB
		)
		let ingressA = await actor.ingestLiveDeltas(
			[.folderAdded("Sources-A"), .fileAdded("Sources-A/A.swift")],
			forRootKey: rootA
		)

		switch ingressB {
		case .queued:
			break
		default:
			XCTFail("Expected queued ingress for unfocused window")
		}
		switch ingressA {
		case .queued:
			break
		default:
			XCTFail("Expected queued ingress for unfocused window")
		}
		let queuedSnapshot = await actor.pendingWorkSnapshot()
		XCTAssertEqual(
			queuedSnapshot,
			DeferredReplayPendingWorkSnapshot(
				pendingRootCount: 2,
				pendingDeltaCount: 4,
				overflowedRootCount: 0
			)
		)

		let batches = await actor.drainPreparedBatches(
			preferredRootOrder: [rootA, rootB],
			chunkSize: 1
		)

		XCTAssertEqual(batches.map(\.rootKey), [rootA, rootB])
		XCTAssertEqual(batches.map(\.chunks.count), [2, 2])
		let hasPendingWorkAfterDrain = await actor.hasPendingWork()
		XCTAssertFalse(hasPendingWorkAfterDrain)
	}

	func testOverflowedRootDropsFurtherIngressUntilCleared() async throws {
		let actor = DeferredReplayBufferActor(maxPendingDeltasPerRoot: 2)
		let rootKey = "/tmp/replay-overflow-root"
		let longFolder = "Data-" + String(repeating: "x", count: 96)
		await actor.updateRoutingState(isWindowFocused: false, isReplayActive: false, routingVersion: 1)

		let initial = await actor.ingestLiveDeltas(
			[
				.folderAdded(longFolder),
				.fileAdded("\(longFolder)/A.swift")
			],
			forRootKey: rootKey
		)
		let overflow = await actor.ingestLiveDeltas(
			[.fileModified("\(longFolder)/A.swift", nil)],
			forRootKey: rootKey
		)
		let dropped = await actor.ingestLiveDeltas(
			[.fileModified("\(longFolder)/B.swift", nil)],
			forRootKey: rootKey
		)

		guard case .queued = initial else {
			return XCTFail("Expected initial deferred ingress to queue")
		}
		guard case .overflowRequiresRefresh(let overflowedRootKey) = overflow else {
			return XCTFail("Expected overflow refresh request")
		}
		XCTAssertEqual(overflowedRootKey, rootKey)
		guard case .droppedWhileOverflowed(let droppedRootKey) = dropped else {
			return XCTFail("Expected dropped ingress after overflow")
		}
		XCTAssertEqual(droppedRootKey, rootKey)
		let overflowSnapshot = await actor.pendingWorkSnapshot()
		XCTAssertEqual(
			overflowSnapshot,
			DeferredReplayPendingWorkSnapshot(
				pendingRootCount: 0,
				pendingDeltaCount: 0,
				overflowedRootCount: 1
			)
		)

		await actor.clearRoot(rootKey)
		let requeued = await actor.ingestLiveDeltas(
			[.folderModified(longFolder, nil)],
			forRootKey: rootKey
		)
		guard case .queued = requeued else {
			return XCTFail("Expected ingress to queue after clearing overflow")
		}
		let pendingCountAfterClear = await actor.pendingDeltaCount(forRootKey: rootKey)
		XCTAssertEqual(pendingCountAfterClear, 1)
	}

	func testDeferredFolderRemovalBurstDrainsWithNestedNoiseCoalescedAndSiblingRemovalsPreserved() async throws {
		let actor = DeferredReplayBufferActor(maxPendingDeltasPerRoot: 16)
		let rootKey = "/tmp/replay-removal-burst-root"
		await actor.updateRoutingState(isWindowFocused: false, isReplayActive: false, routingVersion: 1)

		let ingress = await actor.ingestLiveDeltas(
			[
				.folderRemoved("A"),
				.fileRemoved("A/file.swift"),
				.folderRemoved("A/Nested"),
				.folderRemoved("B")
			],
			forRootKey: rootKey
		)
		guard case .queued = ingress else {
			return XCTFail("Expected deferred removal burst to queue")
		}

		let batches = await actor.drainPreparedBatches(preferredRootOrder: [rootKey], chunkSize: 8)

		let batch = try XCTUnwrap(batches.first)
		XCTAssertEqual(batches.count, 1)
		XCTAssertEqual(batch.rootKey, rootKey)
		XCTAssertEqual(batch.coalescedDeltaCount, 2)
		XCTAssertEqual(batch.discardedDeltaCount, 2)
		XCTAssertEqual(batch.preparedDeltas.map(\.delta), [.folderRemoved("A"), .folderRemoved("B")])
		let chunk = try XCTUnwrap(batch.chunks.first)
		XCTAssertEqual(batch.chunks.count, 1)
		XCTAssertEqual(chunk.summary.folderRemovedCount, 2)
		XCTAssertEqual(chunk.summary.fileRemovedCount, 0)
	}

	func testFocusedNonReplayingIngressReturnsPreparedImmediateBatch() async throws {
		let actor = DeferredReplayBufferActor(maxPendingDeltasPerRoot: 8)
		let rootKey = "/tmp/replay-immediate-root"
		let deltas: [FileSystemDelta] = [
			.folderModified("Sources", nil),
			.fileModified("Sources/A.swift", Date(timeIntervalSince1970: 123))
		]
		await actor.updateRoutingState(isWindowFocused: true, isReplayActive: false, routingVersion: 42)
		await actor.updateImmediateReplayChunkSizeOverride(1)

		let result = await actor.ingestLiveDeltas(
			deltas,
			forRootKey: rootKey
		)

		var preparedImmediate: PreparedImmediateReplay?
		switch result {
		case .preparedImmediate(let immediate):
			preparedImmediate = immediate
			XCTAssertEqual(immediate.rootKey, rootKey)
			XCTAssertEqual(immediate.sourceDeltas, deltas)
			XCTAssertEqual(immediate.routingVersion, 42)
			XCTAssertEqual(immediate.preparedBatch.rootKey, rootKey)
			XCTAssertEqual(immediate.preparedBatch.coalescedDeltaCount, deltas.count)
			XCTAssertEqual(immediate.preparedBatch.chunks.count, 2)
		case .queued, .overflowRequiresRefresh, .droppedWhileOverflowed, .droppedStaleGeneration:
			XCTFail("Expected prepared immediate replay result")
		}
		let diagnostics = await actor.diagnosticsSnapshot()
		XCTAssertTrue(diagnostics.immediatePreparedIngressInFlight)
		if let preparedImmediate {
			await actor.finishPreparedImmediateIngress(preparedImmediate)
		}
		let hasPendingWorkAfterImmediateIngress = await actor.hasPendingWork()
		XCTAssertFalse(hasPendingWorkAfterImmediateIngress)
	}

	func testFocusedIngressQueuesWhenOlderBufferedWorkExists() async throws {
		let actor = DeferredReplayBufferActor(maxPendingDeltasPerRoot: 8)
		let bufferedRoot = "/tmp/replay-buffered-root"
		let incomingRoot = "/tmp/replay-incoming-root"
		await actor.updateRoutingState(isWindowFocused: false, isReplayActive: false, routingVersion: 1)

		let queued = await actor.ingestLiveDeltas(
			[.folderAdded("QueuedOlderWork")],
			forRootKey: bufferedRoot
		)
		await actor.updateRoutingState(isWindowFocused: true, isReplayActive: false, routingVersion: 2)
		let focusedIngress = await actor.ingestLiveDeltas(
			[.folderModified("NewerFocusedWork", nil)],
			forRootKey: incomingRoot
		)

		guard case .queued = queued else {
			return XCTFail("Expected older buffered work to queue")
		}
		guard case .queued = focusedIngress else {
			return XCTFail("Expected focused ingress to queue behind buffered work")
		}
		let pendingSnapshot = await actor.pendingWorkSnapshot()
		XCTAssertEqual(pendingSnapshot.pendingRootCount, 2)
		XCTAssertEqual(pendingSnapshot.pendingDeltaCount, 2)
	}

	func testFocusedIngressQueuesWhilePreparedImmediateBatchIsInFlight() async throws {
		let actor = DeferredReplayBufferActor(maxPendingDeltasPerRoot: 8)
		await actor.updateRoutingState(isWindowFocused: true, isReplayActive: false, routingVersion: 7)

		let firstIngress = await actor.ingestLiveDeltas(
			[.folderAdded("PreparedNow")],
			forRootKey: "/tmp/replay-prepared-root"
		)
		let secondIngress = await actor.ingestLiveDeltas(
			[.folderModified("QueuedBehindImmediate", nil)],
			forRootKey: "/tmp/replay-queued-root"
		)

		guard case .preparedImmediate(let immediate) = firstIngress else {
			return XCTFail("Expected first focused ingress to prepare immediately")
		}
		guard case .queued = secondIngress else {
			return XCTFail("Expected second focused ingress to queue behind in-flight prepared work")
		}
		let pendingSnapshot = await actor.pendingWorkSnapshot()
		XCTAssertEqual(pendingSnapshot.pendingRootCount, 1)
		XCTAssertEqual(pendingSnapshot.pendingDeltaCount, 1)
		await actor.finishPreparedImmediateIngress(immediate)
	}

	func testStaleRootGenerationIngressIsDroppedAfterReload() async throws {
		let actor = DeferredReplayBufferActor(maxPendingDeltasPerRoot: 8)
		let rootKey = "/tmp/replay-generation-root"
		await actor.updateRoutingState(isWindowFocused: true, isReplayActive: false, routingVersion: 3)
		await actor.registerActiveRootGeneration(2, forRootKey: rootKey)

		let staleIngress = await actor.ingestLiveDeltas(
			[.folderAdded("Stale")],
			forRootKey: rootKey,
			rootGeneration: 1
		)
		guard case .droppedStaleGeneration(let staleRootKey) = staleIngress else {
			return XCTFail("Expected stale generation ingress to be dropped")
		}
		XCTAssertEqual(staleRootKey, rootKey)

		let currentIngress = await actor.ingestLiveDeltas(
			[.folderAdded("Fresh")],
			forRootKey: rootKey,
			rootGeneration: 2
		)
		guard case .preparedImmediate(let immediate) = currentIngress else {
			return XCTFail("Expected current generation ingress to prepare immediately")
		}
		XCTAssertEqual(immediate.rootGeneration, 2)
		await actor.finishPreparedImmediateIngress(immediate)
	}

	func testStaleRoutingStateUpdateDoesNotOverrideNewerIngressReadiness() async throws {
		let actor = DeferredReplayBufferActor(maxPendingDeltasPerRoot: 8)
		let rootKey = "/tmp/replay-routing-version-root"
		await actor.updateRoutingState(isWindowFocused: true, isReplayActive: false, routingVersion: 9)
		await actor.updateRoutingState(isWindowFocused: false, isReplayActive: true, routingVersion: 8)

		let ingress = await actor.ingestLiveDeltas(
			[.folderAdded("StillImmediate")],
			forRootKey: rootKey
		)

		guard case .preparedImmediate(let immediate) = ingress else {
			return XCTFail("Expected stale routing update to be ignored")
		}
		XCTAssertEqual(immediate.routingVersion, 9)
		let diagnostics = await actor.diagnosticsSnapshot()
		XCTAssertEqual(diagnostics.routingVersion, 9)
		XCTAssertTrue(diagnostics.immediatePreparedIngressInFlight)
		await actor.finishPreparedImmediateIngress(immediate)
	}

	func testOverlappingImmediateIngressReservesSlotBeforePreparationAwait() async throws {
		let preparationActor = BlockingDeltaReplayPreparationActor()
		let actor = DeferredReplayBufferActor(
			maxPendingDeltasPerRoot: 8,
			preparationActor: preparationActor
		)
		let firstRoot = "/tmp/replay-overlap-first-root"
		let secondRoot = "/tmp/replay-overlap-second-root"
		await actor.updateRoutingState(isWindowFocused: true, isReplayActive: false, routingVersion: 11)

		let firstIngressTask = Task {
			await actor.ingestLiveDeltas(
				[.folderAdded("PreparedFirst")],
				forRootKey: firstRoot
			)
		}
		await preparationActor.waitForFirstPrepareToStart()

		let secondIngress = await actor.ingestLiveDeltas(
			[.folderModified("QueuedSecond", nil)],
			forRootKey: secondRoot
		)

		guard case .queued = secondIngress else {
			return XCTFail("Expected overlapping ingress to queue while the first immediate preparation is reserved")
		}
		let prepareCallCount = await preparationActor.recordedPrepareCallCount()
		XCTAssertEqual(prepareCallCount, 1)
		let pendingSnapshotWhileReserved = await actor.pendingWorkSnapshot()
		XCTAssertEqual(pendingSnapshotWhileReserved.pendingRootCount, 1)
		XCTAssertEqual(pendingSnapshotWhileReserved.pendingDeltaCount, 1)

		await preparationActor.releaseFirstPrepare()
		let firstIngress = await firstIngressTask.value
		guard case .preparedImmediate(let immediate) = firstIngress else {
			return XCTFail("Expected first ingress to finish as prepared immediate work")
		}
		await actor.finishPreparedImmediateIngress(immediate)
	}

	func testClearingRootDuringImmediatePreparationRequeuesInvalidatedIngress() async throws {
		let preparationActor = BlockingDeltaReplayPreparationActor()
		let actor = DeferredReplayBufferActor(
			maxPendingDeltasPerRoot: 8,
			preparationActor: preparationActor
		)
		let rootKey = "/tmp/replay-invalidated-root"
		await actor.updateRoutingState(isWindowFocused: true, isReplayActive: false, routingVersion: 12)

		let ingressTask = Task {
			await actor.ingestLiveDeltas(
				[.folderAdded("PreparedThenCleared")],
				forRootKey: rootKey
			)
		}
		await preparationActor.waitForFirstPrepareToStart()
		await actor.clearRoot(rootKey)

		await preparationActor.releaseFirstPrepare()
		let ingress = await ingressTask.value
		guard case .queued = ingress else {
			return XCTFail("Expected invalidated in-flight immediate ingress to be requeued after clearRoot")
		}
		let pendingSnapshot = await actor.pendingWorkSnapshot()
		XCTAssertEqual(pendingSnapshot.pendingRootCount, 1)
		XCTAssertEqual(pendingSnapshot.pendingDeltaCount, 1)
		let diagnostics = await actor.diagnosticsSnapshot()
		XCTAssertFalse(diagnostics.immediatePreparedIngressInFlight)
	}

	func testEmptyImmediatePreparedBatchRequeuesSourceDeltas() async throws {
		let preparationActor = EmptyDeltaReplayPreparationActor()
		let actor = DeferredReplayBufferActor(
			maxPendingDeltasPerRoot: 8,
			preparationActor: preparationActor
		)
		let rootKey = "/tmp/replay-empty-prepared-root"
		await actor.updateRoutingState(isWindowFocused: true, isReplayActive: false, routingVersion: 13)

		let ingress = await actor.ingestLiveDeltas(
			[.fileModified("A.swift", nil)],
			forRootKey: rootKey
		)

		guard case .queued = ingress else {
			return XCTFail("Expected empty immediate prepared batch to requeue source deltas")
		}
		let pendingSnapshot = await actor.pendingWorkSnapshot()
		XCTAssertEqual(pendingSnapshot.pendingRootCount, 1)
		XCTAssertEqual(pendingSnapshot.pendingDeltaCount, 1)
		let diagnostics = await actor.diagnosticsSnapshot()
		XCTAssertFalse(diagnostics.immediatePreparedIngressInFlight)
	}
}

private actor EmptyDeltaReplayPreparationActor: DeltaReplayPreparing {
	func prepare(
		rootKey: String,
		deltas: [FileSystemDelta],
		chunkSize: Int
	) async -> PreparedFileSystemReplayBatch {
		PreparedFileSystemReplayBatch(
			rootKey: rootKey,
			queuedDeltaCount: deltas.count,
			coalescedDeltaCount: 0,
			preparedDeltas: [],
			chunks: [],
			coalesceDurationMS: 0,
			preparationDurationMS: 0
		)
	}
}

private actor BlockingDeltaReplayPreparationActor: DeltaReplayPreparing {
	private var prepareCallCount = 0
	private var firstPrepareStartedContinuation: CheckedContinuation<Void, Never>?
	private var firstPrepareReleaseContinuation: CheckedContinuation<Void, Never>?

	func prepare(
		rootKey: String,
		deltas: [FileSystemDelta],
		chunkSize: Int
	) async -> PreparedFileSystemReplayBatch {
		prepareCallCount += 1
		if prepareCallCount == 1 {
			firstPrepareStartedContinuation?.resume()
			firstPrepareStartedContinuation = nil
			await withCheckedContinuation { continuation in
				firstPrepareReleaseContinuation = continuation
			}
		}
		return FileSystemDeltaPreparation.prepareBatch(
			rootKey: rootKey,
			deltas: deltas,
			chunkSize: chunkSize
		)
	}

	func waitForFirstPrepareToStart() async {
		if prepareCallCount > 0 {
			return
		}
		await withCheckedContinuation { continuation in
			firstPrepareStartedContinuation = continuation
		}
	}

	func releaseFirstPrepare() {
		firstPrepareReleaseContinuation?.resume()
		firstPrepareReleaseContinuation = nil
	}

	func recordedPrepareCallCount() -> Int {
		prepareCallCount
	}
}
