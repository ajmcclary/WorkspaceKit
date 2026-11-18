import CoreServices
import Foundation
import XCTest
@testable import WorkspaceFileSystem
import WorkspaceIgnore

final class WorkspaceCatalogContainmentTests: XCTestCase {
	private let fm = FileManager.default
	private var temporary: URL!
	private var root: URL!

	override func setUpWithError() throws {
		temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		root = temporary.appendingPathComponent("workspace", isDirectory: true)
		try fm.createDirectory(at: root, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try fm.removeItem(at: temporary)
	}

	private func indexed(_ service: FileSystemService, at directory: URL? = nil) async throws -> Set<String> {
		var paths = Set<String>()
		for try await event in await service.loadContentsInChunks(of: directory ?? root) {
			if case .preparedItems(let chunk) = event {
				paths.formUnion(chunk.files.map(\.relativePath))
			}
		}
		return paths
	}

	func testDirectoryAliasesInInitialScanRescanAndExistenceQueries() async throws {
		let local = root.appendingPathComponent("local")
		let other = temporary.appendingPathComponent("other")
		for dir in [local, other] {
			try fm.createDirectory(at: dir, withIntermediateDirectories: false)
			try Data().write(to: dir.appendingPathComponent("first.txt"))
		}
		try fm.createSymbolicLink(at: root.appendingPathComponent("internal"), withDestinationURL: local)
		try fm.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: other)
		let service = try await FileSystemService(path: root.path, skipSymlinks: false)
		let initial = try await indexed(service)
		XCTAssertTrue(initial.contains("internal/first.txt"))
		XCTAssertFalse(initial.contains("external/first.txt"))
		let outsideChildren = try await indexed(service, at: root.appendingPathComponent("external"))
		XCTAssertTrue(outsideChildren.isEmpty)
		let batch = await service.catalogRegularFileEligibilityBatch(relativePaths: ["internal/first.txt", "external/first.txt", "external"])
		XCTAssertEqual(batch["internal/first.txt"], .eligible)
		XCTAssertEqual(batch["external"], .ineligible(.symbolicLink))
		XCTAssertEqual(batch["external/first.txt"], .ineligible(.outsideCanonicalRoot))
		let absent = await service.catalogRegularFileEligibility(relativePath: "external/absent.txt")
		XCTAssertEqual(absent, batch["external/first.txt"])

		let internalFile = await service.regularFileExistsOnDisk(relativePath: "internal/first.txt")
		let externalFile = await service.regularFileExistsOnDisk(relativePath: "external/first.txt")
		let externalEntry = await service.fileExistsOnDisk(relativePath: "external/first.txt")
		XCTAssertTrue(internalFile)
		XCTAssertFalse(externalFile)
		XCTAssertFalse(externalEntry)

		for dir in [local, other] { try Data().write(to: dir.appendingPathComponent("next.txt")) }
		let scanned = try await service.scanOneLevelAndDiff(relativeFolderPath: "external")
		XCTAssertFalse(scanned.contains(.fileAdded("external/next.txt")))
		let deltas = await service.simulateFSEvents([(absolutePath: root.path,
			flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), eventId: 101)])
		XCTAssertTrue(deltas.contains(.fileAdded("internal/next.txt")))
		XCTAssertFalse(deltas.contains(.fileAdded("external/next.txt")))
		await service.updateSkipSymlinks(true)
		let withoutLinks = try await indexed(service)
		XCTAssertTrue(withoutLinks.contains("local/next.txt"))
		XCTAssertFalse(withoutLinks.contains("internal/next.txt"))
	}

	func testRootAndNestedIgnoreFilesUseTheCurrentLinkPolicy() async throws {
		let sub = root.appendingPathComponent("sub")
		try fm.createDirectory(at: sub, withIntermediateDirectories: false)
		let outside = temporary.appendingPathComponent("outside-rules")
		let inside = root.appendingPathComponent("inside-rules")
		try Data("outside-pattern.txt\n".utf8).write(to: outside)
		try Data("inside-pattern.txt\n".utf8).write(to: inside)
		for directory in [root!, sub] {
			for name in ["inside-pattern.txt", "outside-pattern.txt"] {
				try Data().write(to: directory.appendingPathComponent(name))
			}
			try fm.createSymbolicLink(at: directory.appendingPathComponent(".repo_ignore"), withDestinationURL: outside)
		}
		// Only the nested scope should apply this local pattern.
		try fm.createSymbolicLink(at: sub.appendingPathComponent(".cursorignore"), withDestinationURL: inside)
		let service = try await FileSystemService(path: root.path, skipSymlinks: false)
		let withLinks = try await indexed(service)
		XCTAssertTrue(withLinks.isSuperset(of: ["inside-pattern.txt", "outside-pattern.txt", "sub/outside-pattern.txt"]))
		XCTAssertFalse(withLinks.contains("sub/inside-pattern.txt"))
		await service.updateSkipSymlinks(true)
		let withoutLinks = try await indexed(service)
		XCTAssertTrue(withoutLinks.contains("sub/inside-pattern.txt"))
		try fm.createSymbolicLink(at: root.appendingPathComponent(".gitignore"), withDestinationURL: inside)
		await service.updateSkipSymlinks(false)
		let refreshed = try await indexed(service)
		XCTAssertFalse(refreshed.contains("inside-pattern.txt"))
		let standalone = try await IgnoreRulesManager.shared.getIgnoreRules(for: root.path)
		XCTAssertTrue(standalone.isIgnored(relativePath: "inside-pattern.txt", isDirectory: false))
		XCTAssertFalse(standalone.isIgnored(relativePath: "outside-pattern.txt", isDirectory: false))
	}
}
