import Foundation
import XCTest
import Combine
@testable import WorkspacePathLookup

// (An unused FileSystemService test-bootstrap block was dropped when these
// tests moved to WorkspacePathLookup — it had no callers.)

struct MockFile: FileRecord {
    let name: String
    let relativePath: String
    let fullPath: String
    let rootFolderPath: String
    
    init(name: String, relativePath: String, rootPath: String) {
        self.name = name
        self.relativePath = relativePath
        self.rootFolderPath = rootPath
        self.fullPath = (rootPath as NSString).appendingPathComponent(relativePath)
    }
}


struct MockFolder: FolderRecord {
    let name: String
	let displayName: String
    let relativePath: String
    let fullPath: String
    let rootPath: String
    
    /// Internal storage for files associated with this folder (used only in test setup)
    var _files: [MockFile] = []
    
    init(name: String, relativePath: String, rootPath: String, displayName: String? = nil, files: [FileRecord] = []) {
        self.name = name
		self.displayName = displayName ?? name
        self.relativePath = relativePath
        self.rootPath = rootPath
        self.fullPath = relativePath.isEmpty ? rootPath : (rootPath as NSString).appendingPathComponent(relativePath)
        self._files = files.compactMap { $0 as? MockFile }
    }
}


// MARK: - Test Helpers

struct PathMatcherTestHelper {
    
    /// Creates a test snapshot with the given files and folders
    static func makeSnapshot(
        files: [(path: String, root: String)],
        folders: [(path: String, root: String)] = [],
        extraFolders: [MockFolder] = [],
        selectedFiles: [String] = []
    ) async -> PathMatchSnapshot {
        
        // Build file records
        var filesByFullPath: [String: FileRecord] = [:]
        for (path, root) in files {
            let name = (path as NSString).lastPathComponent
            let file = MockFile(name: name, relativePath: path, rootPath: root)
            filesByFullPath[file.fullPath] = file
        }
        
        // Build folder records
        var foldersByFullPath: [String: FolderRecord] = [:]
        
        // Add explicit folders
        for (path, root) in folders {
            let name = (path as NSString).lastPathComponent
            let folder = MockFolder(name: name, relativePath: path, rootPath: root)
            foldersByFullPath[folder.fullPath] = folder
        }
        
        // Add extra folders with files
        for folder in extraFolders {
            foldersByFullPath[folder.fullPath] = folder
            // Also add their files to the files index (using internal _files storage)
            for file in folder._files {
                filesByFullPath[file.fullPath] = file
            }
        }
        
        // Auto-create parent folders for all files
        for (_, file) in filesByFullPath {
            var currentPath = file.rootFolderPath
            let components = file.relativePath.split(separator: "/").dropLast()
            
            for component in components {
                currentPath = (currentPath as NSString).appendingPathComponent(String(component))
                if foldersByFullPath[currentPath] == nil {
                    let relativePath = currentPath.replacingOccurrences(of: file.rootFolderPath + "/", with: "")
                    let folder = MockFolder(
                        name: String(component),
                        relativePath: relativePath,
                        rootPath: file.rootFolderPath
                    )
                    foldersByFullPath[currentPath] = folder
                }
            }
        }
        
        // Determine root folders in first-seen order so tie-breaker tests model
        // the app's configured root order instead of Set iteration order.
        var seenRoots: Set<String> = []
        var orderedRoots: [String] = []
        for root in files.map(\.root) + folders.map(\.root) {
            guard seenRoots.insert(root).inserted else { continue }
            orderedRoots.append(root)
        }
        let rootFolders: [FolderRecord] = orderedRoots.map { root in
            MockFolder(name: (root as NSString).lastPathComponent, relativePath: "", rootPath: root)
        }
        
        return PathMatchSnapshot(
            filesByFullPath: filesByFullPath,
            foldersByFullPath: foldersByFullPath,
            rootFolders: rootFolders,
            selectedFileFullPaths: Set(selectedFiles)
        )
    }
    
    /// Asserts that a path resolves to the expected result
    static func assertResolves(
        _ input: String,
        to expectedPath: String?,
        exactMatchOnly: Bool = false,
        in snapshot: PathMatchSnapshot,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        // Use the real PathMatcher with our test service
        let result = PathMatcher.locate(userPath: input, exactMatchOnly: exactMatchOnly, snapshot: snapshot)
        
        if let expectedPath = expectedPath {
            XCTAssertNotNil(result, "Expected path '\(input)' to resolve, but it didn't", file: file, line: line)
            XCTAssertEqual(result?.correctedPath, expectedPath,
                          "Path '\(input)' resolved to '\(result?.correctedPath ?? "nil")' instead of '\(expectedPath)'",
                          file: file, line: line)
        } else {
            XCTAssertNil(result, "Expected path '\(input)' to not resolve, but it resolved to '\(result?.correctedPath ?? "")'",
                        file: file, line: line)
        }
    }
    
    /// Gets the resolved path without asserting (for checking ambiguous cases)
    static func getResolvedPath(
        _ input: String,
        exactMatchOnly: Bool = false,
        in snapshot: PathMatchSnapshot
    ) -> String? {
        let result = PathMatcher.locate(userPath: input, exactMatchOnly: exactMatchOnly, snapshot: snapshot)
        return result?.correctedPath
    }
    
    /// Asserts file creation path resolution
    static func assertCreationPath(
        _ input: String,
        rootPath: String,
        components: [String],
        in snapshot: PathMatchSnapshot,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let result = PathMatcher.findCreationPath(userPath: input, snapshot: snapshot)
        
        XCTAssertNotNil(result, "Creation path for '\(input)' should not be nil", file: file, line: line)
        XCTAssertEqual(result?.rootFolder.fullPath, rootPath, "Root folder mismatch", file: file, line: line)
        XCTAssertEqual(result?.componentsToCreate, components, "Components mismatch", file: file, line: line)
    }
    
    /// Creates a folder with files using a compact notation
    static func folder(name: String, path: String, root: String, containing files: [String]) -> MockFolder {
        let folderFiles = files.map { fileName in
            MockFile(
                name: fileName,
                relativePath: path.isEmpty ? fileName : "\(path)/\(fileName)",
                rootPath: root
            )
        }
        return MockFolder(name: name, relativePath: path, rootPath: root, files: folderFiles)
    }
}
