import XCTest
@testable import WorkspacePathLookup

final class PathMatcherDebugTests: XCTestCase {
    
    func testSnapshotCreation() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/main.swift", "/Users/test/project"),
            ("src/utils/helper.swift", "/Users/test/project"),
            ("README.md", "/Users/test/project")
        ])
        
        // Check that files are in the snapshot
        print("Files in snapshot: \(snapshot.filesByFullPath.count)")
        for (path, file) in snapshot.filesByFullPath {
            print("File: \(path) -> name: \(file.name), relativePath: \(file.relativePath)")
        }
        
        print("\nFolders in snapshot: \(snapshot.foldersByFullPath.count)")
        for (path, folder) in snapshot.foldersByFullPath {
            print("Folder: \(path) -> name: \(folder.name), relativePath: \(folder.relativePath)")
        }
        
        print("\nRoot folders: \(snapshot.rootFolders.count)")
        for root in snapshot.rootFolders {
            print("Root: \(root.fullPath)")
        }
        
        XCTAssertEqual(snapshot.filesByFullPath.count, 3, "Should have 3 files")
        XCTAssertNotNil(snapshot.filesByFullPath["/Users/test/project/src/main.swift"])
        XCTAssertNotNil(snapshot.filesByFullPath["/Users/test/project/README.md"])
    }
    
    func testDirectLookup() async {
        let snapshot = await PathMatcherTestHelper.makeSnapshot(files: [
            ("src/main.swift", "/Users/test/project")
        ])
        
        // Test the absolute path candidates
        let candidates = PathMatcher.absolutePathCandidates(forRelativePath: "src/main.swift", snapshot: snapshot)
        print("Candidates for 'src/main.swift': \(candidates)")
        
        // Check if the file exists in the right place
        let expectedPath = "/Users/test/project/src/main.swift"
        XCTAssertNotNil(snapshot.filesByFullPath[expectedPath], "File should exist at \(expectedPath)")
        
        // Test direct lookup
        let result = PathMatcher.locate(userPath: "src/main.swift", exactMatchOnly: false, snapshot: snapshot)
        XCTAssertNotNil(result, "Should find src/main.swift")
        XCTAssertEqual(result?.correctedPath, "src/main.swift")
    }
}