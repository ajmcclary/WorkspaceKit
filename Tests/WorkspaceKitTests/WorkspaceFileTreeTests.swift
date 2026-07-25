import Foundation
import Testing
@testable import WorkspaceKit

/// Characterization tests pinning the behavior the contracts and the macOS
/// adapter shipped with when they moved out of CodeEditorKit's
/// CodeEditorWorkspace target (workspace decomposition step 5).
@Suite("WorkspaceFileNode + WorkspaceFileTree")
struct WorkspaceFileTreeTests {
    @Test("node id defaults to the URL's absoluteString")
    func nodeIdentityDefault() {
        let url = URL(fileURLWithPath: "/tmp/example")
        let node = WorkspaceFileNode(name: "example", url: url, isDirectory: true)
        #expect(node.id == url.absoluteString)
        #expect(node.children.isEmpty)
    }

    @Test("explicit node id wins over the URL default")
    func nodeIdentityExplicit() {
        let url = URL(fileURLWithPath: "/tmp/example")
        let node = WorkspaceFileNode(name: "example", url: url, isDirectory: false, id: "custom")
        #expect(node.id == "custom")
    }

#if canImport(AppKit)
    @Test("root reflects the workspace directory")
    @MainActor
    func rootNode() throws {
        let dir = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = MacOSWorkspaceFileManager(rootURL: dir)
        #expect(manager.root.name == dir.lastPathComponent)
        #expect(manager.root.isDirectory)
        #expect(manager.fileURL(for: manager.root) == dir)
        #expect(manager.isDirectory(manager.root))
    }

    @Test("children load lazily, sorted, skipping hidden files; files return []")
    @MainActor
    func lazyChildren() throws {
        let dir = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = MacOSWorkspaceFileManager(rootURL: dir)

        // localizedStandardCompare sorts Finder-style: case-insensitive
        // alphabetical, so "Zebra" lands after the lowercase names.
        let children = manager.children(of: manager.root)
        #expect(children.map(\.name) == ["alpha.txt", "beta.txt", "Zebra"])

        let zebra = try #require(children.first { $0.name == "Zebra" })
        #expect(zebra.isDirectory)
        #expect(manager.children(of: zebra).map(\.name) == ["nested.txt"])

        let alpha = try #require(children.first { $0.name == "alpha.txt" })
        #expect(!alpha.isDirectory)
        #expect(manager.children(of: alpha).isEmpty)
    }

    @Test("refresh picks up files created after the first load")
    @MainActor
    func refreshReloads() async throws {
        let dir = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = MacOSWorkspaceFileManager(rootURL: dir)

        _ = manager.children(of: manager.root)
        let newFile = dir.appendingPathComponent("gamma.txt")
        try Data("late".utf8).write(to: newFile)

        // Cached: still the original three until refreshed.
        #expect(manager.children(of: manager.root).count == 3)
        try await manager.refresh(node: manager.root)
        #expect(manager.children(of: manager.root).map(\.name).contains("gamma.txt"))
    }

    private func makeTempTree() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorkspaceKitTests-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("Zebra"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: dir.appendingPathComponent("alpha.txt"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("beta.txt"))
        try Data("h".utf8).write(to: dir.appendingPathComponent(".hidden"))
        try Data("n".utf8).write(to: dir.appendingPathComponent("Zebra/nested.txt"))
        return dir
    }
#endif
}
