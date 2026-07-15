import XCTest
@testable import WorkspaceFileSystem
@testable import WorkspaceIgnore

final class FileSystemServiceCacheTests: XCTestCase {
    
    // MARK: - LRU Cache Performance Tests
    
    func testLRUCacheAccessOrderPerformance() {
        // This test demonstrates the O(n) performance issue with the current implementation
        // When we access an item, we search for it in the array and move it to the end
        
        var cacheAccessOrder = [String]()
        var cache = [String: String]()
        let cacheSize = 1000
        
        // Fill cache
        for i in 0..<cacheSize {
            let key = "path\(i)"
            cacheAccessOrder.append(key)
            cache[key] = "value\(i)"
        }
        
        measure {
            // Simulate many cache hits with LRU updates
            for _ in 0..<1000 {
                let randomIndex = Int.random(in: 0..<cacheSize)
                let key = "path\(randomIndex)"
                
                // This is O(n) operation - the performance issue!
                if let index = cacheAccessOrder.firstIndex(of: key) {
                    cacheAccessOrder.remove(at: index)
                    cacheAccessOrder.append(key)
                }
            }
        }
    }
    
    // MARK: - Mock Cache Implementation for Testing
    
    class MockPerFolderCache {
        private var cache = [String: IgnoreRules]()
        private var accessOrder = [String]()
        private var noIgnoreCache = Set<String>()
        private let capacity: Int
        
        init(capacity: Int = 100) {
            self.capacity = capacity
        }
        
        func get(_ key: String) -> IgnoreRules? {
            if let rules = cache[key] {
                // Update LRU - this is the O(n) problem
                if let index = accessOrder.firstIndex(of: key) {
                    accessOrder.remove(at: index)
                    accessOrder.append(key)
                }
                return rules
            }
            return nil
        }
        
        func set(_ key: String, rules: IgnoreRules) {
            if let index = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: index)
            }
            
            accessOrder.append(key)
            cache[key] = rules
            
            // Evict if over capacity
            if accessOrder.count > capacity {
                let evicted = accessOrder.removeFirst()
                cache.removeValue(forKey: evicted)
                noIgnoreCache.remove(evicted)
            }
        }
        
        func markNoIgnoreFile(_ path: String) {
            noIgnoreCache.insert(path)
        }
        
        func hasNoIgnoreFile(_ path: String) -> Bool {
            return noIgnoreCache.contains(path)
        }
        
        func clear() {
            cache.removeAll()
            accessOrder.removeAll()
            noIgnoreCache.removeAll()
        }
        
        var count: Int { cache.count }
    }
    
    func testMockCacheBasicBehavior() {
        let cache = MockPerFolderCache(capacity: 3)
        let rules1 = IgnoreRules()
        let rules2 = IgnoreRules()
        let rules3 = IgnoreRules()
        let rules4 = IgnoreRules()
        
        // Test basic set/get
        cache.set("path1", rules: rules1)
        cache.set("path2", rules: rules2)
        cache.set("path3", rules: rules3)
        
        XCTAssertNotNil(cache.get("path1"))
        XCTAssertNotNil(cache.get("path2"))
        XCTAssertNotNil(cache.get("path3"))
        XCTAssertEqual(cache.count, 3)
        
        // Test eviction
        cache.set("path4", rules: rules4)
        XCTAssertNil(cache.get("path1")) // Should be evicted
        XCTAssertNotNil(cache.get("path4"))
        XCTAssertEqual(cache.count, 3)
    }
    
    func testMockCacheLRUBehavior() {
        let cache = MockPerFolderCache(capacity: 3)
        let rules1 = IgnoreRules()
        let rules2 = IgnoreRules()
        let rules3 = IgnoreRules()
        let rules4 = IgnoreRules()
        
        // Fill cache
        cache.set("path1", rules: rules1)
        cache.set("path2", rules: rules2)
        cache.set("path3", rules: rules3)
        
        // Access path1 to make it most recently used
        _ = cache.get("path1")
        
        // Add new item - path2 should be evicted (least recently used)
        cache.set("path4", rules: rules4)
        
        XCTAssertNotNil(cache.get("path1")) // Still in cache
        XCTAssertNil(cache.get("path2")) // Evicted
        XCTAssertNotNil(cache.get("path3"))
        XCTAssertNotNil(cache.get("path4"))
    }
    
    func testMockCacheNoIgnoreFileTracking() {
        let cache = MockPerFolderCache()
        
        // Test no-ignore-file tracking
        cache.markNoIgnoreFile("src/utils")
        cache.markNoIgnoreFile("src/models")
        
        XCTAssertTrue(cache.hasNoIgnoreFile("src/utils"))
        XCTAssertTrue(cache.hasNoIgnoreFile("src/models"))
        XCTAssertFalse(cache.hasNoIgnoreFile("src/views"))
        
        // Test clear
        cache.clear()
        XCTAssertFalse(cache.hasNoIgnoreFile("src/utils"))
    }
    
    // MARK: - Better LRU Implementation Using LinkedHashMap Pattern
    
    class ImprovedPerFolderCache {
        private class Node {
            let key: String
            var rules: IgnoreRules
            var prev: Node?
            var next: Node?
            
            init(key: String, rules: IgnoreRules) {
                self.key = key
                self.rules = rules
            }
        }
        
        private var cache = [String: Node]()
        private var head: Node?
        private var tail: Node?
        private var noIgnoreCache = Set<String>()
        private let capacity: Int
        
        init(capacity: Int = 100) {
            self.capacity = capacity
        }
        
        func get(_ key: String) -> IgnoreRules? {
            if let node = cache[key] {
                // Move to front (most recently used)
                moveToFront(node)
                return node.rules
            }
            return nil
        }
        
        func set(_ key: String, rules: IgnoreRules) {
            if let existingNode = cache[key] {
                // Update existing
                existingNode.rules = rules
                moveToFront(existingNode)
            } else {
                // Add new
                let newNode = Node(key: key, rules: rules)
                cache[key] = newNode
                addToFront(newNode)
                
                // Evict if necessary
                if cache.count > capacity {
                    removeLeastRecentlyUsed()
                }
            }
        }
        
        private func moveToFront(_ node: Node) {
            guard node !== head else { return }
            
            // Remove from current position
            node.prev?.next = node.next
            if node === tail {
                tail = node.prev
            } else {
                node.next?.prev = node.prev
            }
            
            // Add to front
            node.prev = nil
            node.next = head
            head?.prev = node
            head = node
        }
        
        private func addToFront(_ node: Node) {
            if head == nil {
                head = node
                tail = node
            } else {
                node.next = head
                head?.prev = node
                head = node
            }
        }
        
        private func removeLeastRecentlyUsed() {
            guard let lru = tail else { return }
            
            if lru === head {
                head = nil
                tail = nil
            } else {
                tail = lru.prev
                tail?.next = nil
            }
            
            cache.removeValue(forKey: lru.key)
            noIgnoreCache.remove(lru.key)
        }
        
        func markNoIgnoreFile(_ path: String) {
            noIgnoreCache.insert(path)
        }
        
        func hasNoIgnoreFile(_ path: String) -> Bool {
            return noIgnoreCache.contains(path)
        }
        
        func clear() {
            cache.removeAll()
            head = nil
            tail = nil
            noIgnoreCache.removeAll()
        }
        
        var count: Int { cache.count }
    }
    
    func testImprovedCachePerformance() {
        let cache = ImprovedPerFolderCache(capacity: 1000)
        
        // Fill cache
        for i in 0..<1000 {
            let rules = IgnoreRules()
            cache.set("path\(i)", rules: rules)
        }
        
        measure {
            // This should be much faster - O(1) for each operation
            for _ in 0..<10000 {
                let randomIndex = Int.random(in: 0..<1000)
                _ = cache.get("path\(randomIndex)")
            }
        }
    }
    
    // MARK: - Circular Reference Tests
    
    func testNoCircularReferences() {
        // Test that cloned IgnoreRules don't create circular references
        let parent = IgnoreRules()
        parent.addIgnoreFile(content: "*.tmp", priority: 1)
        
        var clones: [IgnoreRules] = []
        
        // Create many clones
        for _ in 0..<100 {
            let clone = parent.clone()
            clone.addIgnoreFile(content: "*.log", priority: 2)
            clones.append(clone)
        }
        
        // Test that clones are independent
        XCTAssertEqual(parent.depth, 2) // Default + one added
        XCTAssertEqual(clones[0].depth, 3) // Default + parent's + one added
        
        // Clear references
        clones.removeAll()
        
        // Parent should still be valid
        XCTAssertTrue(parent.isIgnored(relativePath: "file.tmp", isDirectory: false))
    }
}