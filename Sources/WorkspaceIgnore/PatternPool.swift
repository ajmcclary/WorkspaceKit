import Foundation
import Synchronization

/// A global pool that stores **unique** copies of pattern strings so every
/// identical pattern across thousands of ignore files is backed by a single
/// `String` instance. This can save tens of megabytes of RAM on large
/// repositories while remaining bounded across long-lived app sessions.
///
/// Thread-safety: the interned set lives inside a `Mutex`, which is perfectly
/// adequate here because pattern compilation happens far less frequently than
/// pattern matching. Both stored properties are `let` and `Sendable`
/// (`Mutex<Set<Pattern>>` is `Sendable`; `Int` is), so this type is genuinely
/// `Sendable` — no `@unchecked` escape is required and `shared` is a safe
/// global.
public final class PatternPool: Sendable {
    public static let shared = PatternPool()

    // The glob matcher compares bytes, including canonically equivalent spellings.
    private struct Pattern: Hashable, Sendable {
        let text: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }

        func hash(into hasher: inout Hasher) {
            for byte in text.utf8 { hasher.combine(byte) }
        }
    }

    private let internedPatterns = Mutex(Set<Pattern>())
    private let maxEntries: Int

    private init(maxEntries: Int = 16_384) {
        self.maxEntries = max(1, maxEntries)
    }

    /// Return the unique, interned string for the given pattern.
    /// If the pattern has already been seen, the previously stored instance
    /// is returned; otherwise the string is inserted and returned. When the
    /// pool reaches its maximum unique-string count, it is cleared before
    /// inserting the next new string. Clearing only reduces future deduplication;
    /// compiled rules already hold independent `String` values.
    public func intern(_ pattern: String) -> String {
        let key = Pattern(text: pattern)
        return internedPatterns.withLock { set in
            if let existingIndex = set.firstIndex(of: key) {
                return set[existingIndex].text
            }

            if set.count >= maxEntries {
                set.removeAll(keepingCapacity: false)
            }

            let inserted = set.insert(key)
            return inserted.memberAfterInsert.text
        }
    }

    #if DEBUG
    public var countForTesting: Int {
        internedPatterns.withLock { $0.count }
    }

    public var capacityForTesting: Int {
        maxEntries
    }

    public func resetForTesting() {
        internedPatterns.withLock { $0.removeAll(keepingCapacity: false) }
    }
    #endif
}