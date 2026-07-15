import Foundation
@testable import WorkspaceIgnore

// Package-tests copy of RepoPromptTests/Helpers/TestFS.swift (InMemoryFS /
// SpyFS doubles for the TestFS seam) — test targets can't share helpers
// across the package boundary; the app copy stays for RepoFileManagerTests.

class InMemoryFS: TestFS {
    struct Node {
        var isDir: Bool
        var children: Set<String> = []
        var modificationDate: Date = Date()
        var data: Data = Data()
    }
    
    private var tree: [String: Node] = [:]
    private var trashedOriginalPaths = Set<String>()
    private let lock = NSRecursiveLock()

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
    
    init() {}
    
    func addFile(_ path: String) {
        withLock {
            insert(path, isDir: false)
        }
    }
    
    func addFolder(_ path: String) {
        withLock {
            insert(path, isDir: true)
        }
    }
    
    func write(_ path: String, data: Data = Data()) {
        withLock {
            insert(path, isDir: false, data: data)
        }
    }
    
    func writeGitignore(at path: String, _ content: String) {
        let gitignorePath = path.hasSuffix("/") ? path + ".gitignore" : path + "/.gitignore"
        write(gitignorePath, data: content.data(using: .utf8) ?? Data())
    }
    
    func writeRepoIgnore(at path: String, _ content: String) {
        let repoIgnorePath = path.hasSuffix("/") ? path + ".repo_ignore" : path + "/.repo_ignore"
        write(repoIgnorePath, data: content.data(using: .utf8) ?? Data())
    }

    func writeCursorignore(at path: String, _ content: String) {
        let cursorignorePath = path.hasSuffix("/") ? path + ".cursorignore" : path + "/.cursorignore"
        write(cursorignorePath, data: content.data(using: .utf8) ?? Data())
    }
    
    func remove(_ path: String) {
        withLock {
            removeSubtreeFromTree(at: normalizePath(path))
        }
    }
    
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        withLock {
            let normalized = normalizePath(path)
            if let node = tree[normalized] {
                isDirectory?.pointee = ObjCBool(node.isDir)
                return true
            }
            isDirectory?.pointee = false
            return false
        }
    }
    
    func contentsOfDirectory(at url: URL,
                             includingPropertiesForKeys keys: [URLResourceKey]?,
                             options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        try withLock {
            let path = normalizePath(url.path)
            
            guard let node = tree[path], node.isDir else {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileReadNoSuchFileError,
                              userInfo: [NSFilePathErrorKey: path])
            }
            
            let skipHidden = mask.contains(.skipsHiddenFiles)
            
            return node.children.compactMap { childName in
                if skipHidden && childName.hasPrefix(".") {
                    return nil
                }
                let childPath = path == "/" ? "/\(childName)" : "\(path)/\(childName)"
                return URL(fileURLWithPath: childPath)
            }
        }
    }
    
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try withLock {
            let normalized = normalizePath(path)
            
            guard let node = tree[normalized] else {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileReadNoSuchFileError,
                              userInfo: [NSFilePathErrorKey: path])
            }
            
            return [
                .type: node.isDir ? FileAttributeType.typeDirectory : FileAttributeType.typeRegular,
                .modificationDate: node.modificationDate,
                .size: node.data.count
            ]
        }
    }
    
    func createDirectory(atPath path: String,
                         withIntermediateDirectories createIntermediates: Bool,
                         attributes: [FileAttributeKey: Any]?) throws {
        try withLock {
            let normalized = normalizePath(path)
            
            if createIntermediates {
                createParentDirs(for: normalized)
            }
            
            if tree[normalized] != nil {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteFileExistsError,
                              userInfo: [NSFilePathErrorKey: path])
            }
            
            insert(normalized, isDir: true)
        }
    }
    
    func createDirectory(at url: URL,
                         withIntermediateDirectories createIntermediates: Bool,
                         attributes: [FileAttributeKey: Any]?) throws {
        try createDirectory(atPath: url.path,
                            withIntermediateDirectories: createIntermediates,
                            attributes: attributes)
    }
    
    func removeItem(at url: URL) throws {
        remove(url.path)
    }
    
    func moveItemToTrash(at url: URL) throws -> URL? {
        try withLock {
            let normalized = normalizePath(url.path)
            guard tree[normalized] != nil else {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileReadNoSuchFileError,
                              userInfo: [NSFilePathErrorKey: normalized])
            }
            
            let trashedSubtree = Set(tree.keys.filter { $0 == normalized || $0.hasPrefix(normalized + "/") })
            trashedOriginalPaths.formUnion(trashedSubtree.isEmpty ? [normalized] : trashedSubtree)
            removeSubtreeFromTree(at: normalized)
            
            return URL(fileURLWithPath: "/.Trash/\(lastComponent(of: normalized))")
        }
    }
    
    func trashedPathsSnapshot() -> Set<String> {
        withLock {
            trashedOriginalPaths
        }
    }
    
    func resetTrashTracking() {
        withLock {
            trashedOriginalPaths.removeAll()
        }
    }
    
    func isWritableFile(atPath path: String) -> Bool {
        // In our virtual FS, all existing files are writable
        var isDir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }
    
    func enumerator(at url: URL,
                    includingPropertiesForKeys keys: [URLResourceKey]?,
                    options mask: FileManager.DirectoryEnumerationOptions,
                    errorHandler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
        // For simplicity, return nil - FileSystemService doesn't rely on enumerator in test mode
        return nil
    }
    
    func contents(atPath path: String) -> Data? {
        withLock {
            let normalized = normalizePath(path)
            return tree[normalized]?.data
        }
    }
    
    private func removeSubtreeFromTree(at normalizedPath: String) {
        if let node = tree[normalizedPath], node.isDir {
            let childrenToRemove = tree.keys.filter { $0.hasPrefix(normalizedPath + "/") }
            for child in childrenToRemove {
                tree.removeValue(forKey: child)
            }
        }
        
        tree.removeValue(forKey: normalizedPath)
        
        if let parent = parentPath(of: normalizedPath) {
            tree[parent]?.children.remove(lastComponent(of: normalizedPath))
        }
    }
    
    private func insert(_ path: String, isDir: Bool, data: Data = Data()) {
        let normalized = normalizePath(path)
        
        if !normalized.isEmpty {
            createParentDirs(for: normalized)
        }
        
        if var existing = tree[normalized] {
            // Preserve existing children when re-inserting the same directory
            existing.isDir = isDir
            if !isDir {
                existing.data = data
            }
            tree[normalized] = existing
        } else {
            tree[normalized] = Node(isDir: isDir, data: data)
            if let parent = parentPath(of: normalized) {
                tree[parent]?.children.insert(lastComponent(of: normalized))
            }
        }
    }
    
    private func createParentDirs(for path: String) {
        var currentPath = ""
        let components = path.split(separator: "/").map(String.init)
        
        for (index, component) in components.enumerated() {
            if index == components.count - 1 { break }
            
            currentPath = currentPath.isEmpty ? "/\(component)" : "\(currentPath)/\(component)"
            if tree[currentPath] == nil {
                tree[currentPath] = Node(isDir: true)
                
                if let parent = parentPath(of: currentPath) {
                    tree[parent]?.children.insert(component)
                }
            }
        }
    }
    
    private func normalizePath(_ path: String) -> String {
        var normalized = path
        
        if normalized.hasSuffix("/") && normalized != "/" {
            normalized = String(normalized.dropLast())
        }
        
        if !normalized.hasPrefix("/") {
            normalized = "/" + normalized
        }
        
        let components = normalized.split(separator: "/").filter { !$0.isEmpty }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }
    
    private func parentPath(of path: String) -> String? {
        if path == "/" { return nil }
        let lastSlash = path.lastIndex(of: "/")!
        let parent = String(path[..<lastSlash])
        return parent.isEmpty ? "/" : parent
    }
    
    private func lastComponent(of path: String) -> String {
        return path.split(separator: "/").last.map(String.init) ?? ""
    }
}

class SpyFS: InMemoryFS {
    private let spyLock = NSLock()
    private var enumeratedDirs = Set<String>()
    private var checkedPaths = Set<String>()
    private var statPaths = Set<String>()

    private func withSpyLock<T>(_ body: () throws -> T) rethrows -> T {
        spyLock.lock()
        defer { spyLock.unlock() }
        return try body()
    }

    func enumeratedDirsCount() -> Int {
        withSpyLock {
            enumeratedDirs.count
        }
    }

    func enumeratedDirsSnapshot() -> Set<String> {
        withSpyLock {
            enumeratedDirs
        }
    }
    
    override func contentsOfDirectory(at url: URL,
                                      includingPropertiesForKeys keys: [URLResourceKey]?,
                                      options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        withSpyLock {
            enumeratedDirs.insert(url.path)
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
    
    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        withSpyLock {
            checkedPaths.insert(path)
        }
        return super.fileExists(atPath: path, isDirectory: isDirectory)
    }
    
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        withSpyLock {
            statPaths.insert(path)
        }
        return try super.attributesOfItem(atPath: path)
    }
    
    func resetSpyData() {
        withSpyLock {
            enumeratedDirs.removeAll()
            checkedPaths.removeAll()
            statPaths.removeAll()
        }
    }
}

/// A filesystem that tracks concurrent directory enumeration calls for parallelism testing
class ConcurrencyTrackingFS: InMemoryFS {
    private let lock = NSLock()
    private var _currentConcurrency = 0
    private var _maxObservedConcurrency = 0
    private var _totalEnumerations = 0
    
    /// Artificial delay to make concurrent calls overlap
    var enumerationDelay: TimeInterval = 0.01
    
    /// Current number of concurrent contentsOfDirectory calls
    var currentConcurrency: Int {
        lock.lock()
        defer { lock.unlock() }
        return _currentConcurrency
    }
    
    /// Maximum observed concurrency during the test
    var maxObservedConcurrency: Int {
        lock.lock()
        defer { lock.unlock() }
        return _maxObservedConcurrency
    }
    
    /// Total number of directory enumerations performed
    var totalEnumerations: Int {
        lock.lock()
        defer { lock.unlock() }
        return _totalEnumerations
    }
    
    override func contentsOfDirectory(at url: URL,
                                      includingPropertiesForKeys keys: [URLResourceKey]?,
                                      options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        // Increment concurrency counter
        lock.lock()
        _currentConcurrency += 1
        _totalEnumerations += 1
        if _currentConcurrency > _maxObservedConcurrency {
            _maxObservedConcurrency = _currentConcurrency
        }
        lock.unlock()
        
        // Add artificial delay to increase chance of overlap
        if enumerationDelay > 0 {
            Thread.sleep(forTimeInterval: enumerationDelay)
        }
        
        // Get the actual result
        let result = try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        
        // Decrement concurrency counter
        lock.lock()
        _currentConcurrency -= 1
        lock.unlock()
        
        return result
    }
    
    func resetConcurrencyTracking() {
        lock.lock()
        _currentConcurrency = 0
        _maxObservedConcurrency = 0
        _totalEnumerations = 0
        lock.unlock()
    }
}
