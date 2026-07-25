import Foundation

// Define size_t for C interop
typealias size_t = Int

/// High-performance path search index using C implementation for binary search
/// Optimized for >1k files with O(log n + k*m) search complexity
public actor PathSearchIndex {
    // MARK: - Types
    
    public struct Candidate: Sendable {
        public let index: Int
        public let path: String
        public let filename: String

        public init(index: Int, path: String, filename: String) {
            self.index = index
            self.path = path
            self.filename = filename
        }
    }
    
    // MARK: - Private State
    
    private var cIndex: OpaquePointer?  // path_search_index_t*
    private var originalPaths: [String] = []
    private var filenames: [String] = []
    
    // MARK: - Initialization
    
    public init(paths: [String]) async {
        await rebuild(paths: paths)
    }
    
    public init() {
        self.cIndex = nil
    }
    
    /// `isolated` because `cIndex` is actor-isolated state of a non-`Sendable`
    /// type (`OpaquePointer?`): a `nonisolated deinit` may not touch it. The
    /// C index is owned exclusively by this actor — `rebuild(paths:)` is the
    /// only other site that destroys it, and it runs on the same executor —
    /// so serializing the final `path_search_destroy` on that executor keeps
    /// the destroy/create pairing exactly-once. The trade-off is that the
    /// free may be enqueued rather than run inline at last-release.
    isolated deinit {
        if let index = cIndex {
            path_search_destroy(index)
        }
    }
    
    // MARK: - Public API
    
    /// Search for paths matching the given pattern
    /// - Parameters:
    ///   - pattern: Search pattern (supports wildcards and regex)
    ///   - limit: Maximum number of results to return
    /// - Returns: Array of matching candidates with indices
    public func search(_ pattern: String, limit: Int = 300) async -> [Candidate] {
        guard let index = cIndex else { return [] }
        
        // Call C implementation
        let result = pattern.withCString { patternCStr in
            path_search_find(index, patternCStr, limit)
        }
        
        guard let searchResult = result else { return [] }
        defer { search_result_destroy(searchResult) }
        
        // Convert C results to Swift candidates
        var candidates: [Candidate] = []
        let resultPtr = UnsafePointer<search_result_t>(searchResult)
        let count = Int(resultPtr.pointee.count)
        candidates.reserveCapacity(count)
        
        guard let indices = resultPtr.pointee.indices else { return [] }
        
        for i in 0..<count {
            let idx = Int(indices[i])
            if idx < originalPaths.count {
                candidates.append(Candidate(
                    index: idx,
                    path: originalPaths[idx],
                    filename: filenames[idx]
                ))
            }
        }
        
        return candidates
    }
    
    /// Rebuild the index with new paths
    public func rebuild(paths: [String]) async {
        // Clean up old index
        if let oldIndex = cIndex {
            path_search_destroy(oldIndex)
            cIndex = nil
        }
        
        guard !paths.isEmpty else {
            originalPaths = []
            filenames = []
            return
        }
        
        // Store original paths
        originalPaths = paths
        
        // Extract filenames
        filenames = paths.map { path in
            URL(fileURLWithPath: path).lastPathComponent
        }
        
        // Create C string array
        let cPaths = paths.map { strdup($0) }
        defer {
            cPaths.forEach { free($0) }
        }
        
        // Create index using C implementation
        let cPathsPointers = cPaths.map { UnsafePointer<CChar>($0) }
        cPathsPointers.withUnsafeBufferPointer { buffer in
            cIndex = path_search_create(buffer.baseAddress, paths.count)
        }
    }
    
    /// Get path at specific index
    public func path(at index: Int) -> String? {
        guard index >= 0 && index < originalPaths.count else { return nil }
        return originalPaths[index]
    }
    
    /// Get filename at specific index
    public func filename(at index: Int) -> String? {
        guard index >= 0 && index < filenames.count else { return nil }
        return filenames[index]
    }
    
    /// Get total number of indexed paths
    public var count: Int {
        originalPaths.count
    }
}

// MARK: - LRU Cache Actor

/// Thread-safe LRU cache implementation using actors
public actor LRUCacheActor<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        var timestamp: Date
    }
    
    private var cache: [Key: Entry] = [:]
    private let capacity: Int
    
    public init(capacity: Int) {
        self.capacity = capacity
    }
    
    public func value(for key: Key) -> Value? {
        if var entry = cache[key] {
            entry.timestamp = Date()
            cache[key] = entry
            return entry.value
        }
        return nil
    }
    
    public func set(_ value: Value, for key: Key) {
        cache[key] = Entry(value: value, timestamp: Date())
        
        // Evict oldest if over capacity
        if cache.count > capacity {
            let oldest = cache.min { $0.value.timestamp < $1.value.timestamp }
            if let oldestKey = oldest?.key {
                cache.removeValue(forKey: oldestKey)
            }
        }
    }
    
    public func clear() {
        cache.removeAll()
    }
}

// MARK: - C Bridge Functions

// Import the C functions
@_silgen_name("path_search_create")
func path_search_create(_ paths: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int) -> OpaquePointer?

@_silgen_name("path_search_destroy")
func path_search_destroy(_ index: OpaquePointer?)

@_silgen_name("path_search_find")
func path_search_find(_ index: OpaquePointer?, _ pattern: UnsafePointer<CChar>?, _ limit: Int) -> OpaquePointer?

@_silgen_name("search_result_destroy")
func search_result_destroy(_ result: OpaquePointer?)

// C struct definitions for bridging
struct search_result_t {
    var indices: UnsafeMutablePointer<size_t>?
    var count: size_t
    var capacity: size_t
}