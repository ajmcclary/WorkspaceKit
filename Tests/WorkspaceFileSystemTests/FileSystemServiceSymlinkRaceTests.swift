import XCTest
import Darwin
import Synchronization
@testable import WorkspaceFileSystem

/// While another thread keeps swapping a directory inside the root with a
/// symlink to a directory outside it, no create, edit, move or delete may
/// write, leave or remove anything outside the root. Containment is checked
/// on the same descriptors the operation uses, so there is no window between
/// the check and the write.
final class FileSystemServiceSymlinkRaceTests: XCTestCase {

	private var sandboxURL: URL!
	private var root: String { sandboxURL.appendingPathComponent("root").path }
	private var outside: String { sandboxURL.appendingPathComponent("outside").path }

	override func setUpWithError() throws {
		sandboxURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FSSymlinkRace-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(atPath: root + "/race", withIntermediateDirectories: true)
		try FileManager.default.createDirectory(atPath: outside + "/race-out", withIntermediateDirectories: true)
		try FileManager.default.createSymbolicLink(atPath: root + "/raceAlt", withDestinationPath: outside + "/race-out")
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: sandboxURL)
	}

	private func makeService() async throws -> FileSystemService {
		try await FileSystemService(path: root, respectGitignore: false, respectRepoIgnore: false, respectCursorignore: false)
	}

	/// Swaps `root/race` (real directory) and `root/raceAlt` (symlink to
	/// outside) as fast as possible until `body` returns.
	private func whileSwapping(_ body: () async throws -> Void) async rethrows -> Int {
		let stop = Atomic<Bool>(false)
		let swaps = Atomic<Int>(0)
		let done = Atomic<Bool>(false)
		let racePath = root + "/race"
		let altPath = root + "/raceAlt"
		let swapper = Thread {
			while !stop.load(ordering: .relaxed) {
				if renamex_np(racePath, altPath, UInt32(RENAME_SWAP)) == 0 {
					swaps.add(1, ordering: .relaxed)
				}
			}
			done.store(true, ordering: .relaxed)
		}
		swapper.start()
		defer {
			stop.store(true, ordering: .relaxed)
			while !done.load(ordering: .relaxed) { usleep(1_000) }
		}
		try await body()
		return swaps.load(ordering: .relaxed)
	}

	private func outsideEntries() throws -> [String] {
		try FileManager.default.contentsOfDirectory(atPath: outside + "/race-out").sorted()
	}

	func testCreateUnderASwappingSymlinkNeverWritesOutside() async throws {
		let service = try await makeService()
		var succeeded = 0
		let swaps = try await whileSwapping {
			for index in 0..<3_000 {
				do {
					try await service.createFile(atRelativePath: "race/f\(index).txt", content: "model content")
					succeeded += 1
				} catch {}
			}
		}
		XCTAssertGreaterThan(swaps, 100, "the swapper did not run")
		XCTAssertEqual(try outsideEntries(), [], "created or left behind outside the root")
		XCTAssertGreaterThan(succeeded, 0, "no create ever succeeded while the real directory was in place")
	}

	func testEditUnderASwappingSymlinkNeverWritesOutside() async throws {
		try Data("inside".utf8).write(to: URL(fileURLWithPath: root + "/race/e.txt"))
		try Data("outside".utf8).write(to: URL(fileURLWithPath: outside + "/race-out/e.txt"))
		let service = try await makeService()
		_ = try await whileSwapping {
			for index in 0..<2_000 {
				try? await service.editFile(atRelativePath: "race/e.txt", newContent: "edit \(index)")
			}
		}
		XCTAssertEqual(try outsideEntries(), ["e.txt"], "temp files left outside the root")
		XCTAssertEqual(try String(contentsOfFile: outside + "/race-out/e.txt", encoding: .utf8), "outside")
	}

	func testMoveUnderASwappingSymlinkNeverMovesIntoOrOutOfTheOutside() async throws {
		let count = 1_500
		for index in 0..<count {
			try Data("in".utf8).write(to: URL(fileURLWithPath: root + "/src-\(index).txt"))
			try Data("out".utf8).write(to: URL(fileURLWithPath: outside + "/race-out/o-\(index).txt"))
		}
		let service = try await makeService()
		_ = try await whileSwapping {
			for index in 0..<count {
				try? await service.moveFile(atRelativePath: "src-\(index).txt", toRelativePath: "race/m-\(index).txt")
				try? await service.moveFile(atRelativePath: "race/o-\(index).txt", toRelativePath: "stolen-\(index).txt")
			}
		}
		let entries = try outsideEntries()
		XCTAssertEqual(entries, (0..<count).map { "o-\($0).txt" }.sorted(), "moved into or out of the outside directory")
	}

	func testDeleteUnderASwappingSymlinkNeverDeletesOutside() async throws {
		let count = 1_500
		for index in 0..<count {
			try Data("in".utf8).write(to: URL(fileURLWithPath: root + "/race/d-\(index).txt"))
			try Data("out".utf8).write(to: URL(fileURLWithPath: outside + "/race-out/d-\(index).txt"))
		}
		let service = try await makeService()
		_ = try await whileSwapping {
			for index in 0..<count {
				_ = try? await service.deleteFile(atRelativePath: "race/d-\(index).txt")
			}
		}
		XCTAssertEqual(try outsideEntries().count, count, "a delete removed a file outside the root")
	}
}
