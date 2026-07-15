import XCTest
@testable import WorkspaceFileSystem

/// Pins the two coalescing modes introduced by the deletion/rename
/// stabilization slice: replay preparation drops everything under a removed
/// folder (subtree-aware consumers), while the publish boundary preserves
/// descendant removals for per-item WorkspaceFileWatching consumers.
final class DeltaCoalescingContractTests: XCTestCase {
	private let rawDeltas: [FileSystemDelta] = [
		.folderRemoved("data/old"),
		.fileRemoved("data/old/a.txt"),
		.folderRemoved("data/old/nested"),
		.fileRemoved("data/old/nested/trace.log"),
		.fileModified("data/old/b.txt", nil),
		.fileAdded("data/old/c.txt"),
		.fileModified("data/sibling.txt", nil)
	]

	func testReplayCoalesceDropsAllDescendantsOfRemovedFolder() {
		let coalesced = FileSystemDeltaPreparation.coalesce(rawDeltas)
		XCTAssertEqual(coalesced, [
			.folderRemoved("data/old"),
			.fileModified("data/sibling.txt", nil)
		])
	}

	func testPublishCoalescePreservesDescendantRemovalsAndDropsNoise() {
		let published = FileSystemDeltaPreparation.coalesce(
			rawDeltas,
			preservingDescendantRemovals: true
		)
		XCTAssertEqual(published, [
			.folderRemoved("data/old"),
			.fileRemoved("data/old/a.txt"),
			.folderRemoved("data/old/nested"),
			.fileRemoved("data/old/nested/trace.log"),
			.fileModified("data/sibling.txt", nil)
		])
	}

	func testPublishCoalesceKeepsSamePathReplacementPairs() {
		let published = FileSystemDeltaPreparation.coalesce(
			[
				.folderRemoved("data/item"),
				.fileAdded("data/item")
			],
			preservingDescendantRemovals: true
		)
		XCTAssertEqual(published, [
			.folderRemoved("data/item"),
			.fileAdded("data/item")
		])
	}

	func testPublishCoalesceStillCollapsesPerPathModifyStorms() {
		let published = FileSystemDeltaPreparation.coalesce(
			(0..<20).map { _ in FileSystemDelta.fileModified("data/hot.txt", nil) },
			preservingDescendantRemovals: true
		)
		XCTAssertEqual(published, [.fileModified("data/hot.txt", nil)])
	}
}
