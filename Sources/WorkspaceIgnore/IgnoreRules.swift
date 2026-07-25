import Foundation
import Synchronization

/// Holds multiple "layers" of compiled patterns (from .gitignore, .repo_ignore, etc.), combined.
///
/// `Sendable` because every piece of mutable state (the chain tail and the
/// memoized snapshot) lives inside a single `Mutex`, and the chain itself is
/// built from deeply immutable `RulesNode`s. Instances are routinely handed
/// between isolation domains — `IgnoreRulesManager` (an actor) builds one and
/// returns it to `FileSystemService` (another actor) — so this is the real
/// ownership contract, not a convenience.
///
/// The lock is held only long enough to read or swap the tail reference; the
/// pattern-matching walk itself runs outside the critical section, because the
/// node chain reachable from a tail can never change.
public final class IgnoreRules: Sendable {
	
	// MARK: - Internal persistent node
	/// Every stored property is a `let` of a `Sendable` type, so nodes are
	/// deeply immutable once constructed and may be shared across isolation
	/// domains (the `baseNode` global and `clone()`'s shared chain both rely
	/// on that).
	fileprivate final class RulesNode: Sendable {
		let compiled: CompiledIgnoreRules
		let parent: RulesNode?
		/// Number of layers from root to this node (root = 1)
		let depth: Int
		/// Aggregate flag indicating if **any** ancestor has negative patterns
		let hasNegative: Bool
		let traversalPrefixes: Set<String>
		let traversalPatterns: Set<NegationTraversalPattern>
		let traversalDiagnostics: NegationTraversalDiagnostics
		let activePatternCount: Int
		
		init(compiled: CompiledIgnoreRules, parent: RulesNode?) {
			self.compiled = compiled
			self.parent = parent
			self.depth = (parent?.depth ?? 0) + 1
			self.activePatternCount = compiled.activePatternCount + (parent?.activePatternCount ?? 0)
			self.hasNegative = compiled.hasAnyNegativePattern || (parent?.hasNegative ?? false)
			if let parentPrefixes = parent?.traversalPrefixes {
				self.traversalPrefixes = parentPrefixes.union(compiled.negationTraversalPrefixes)
			} else {
				self.traversalPrefixes = compiled.negationTraversalPrefixes
			}
			if let parentPatterns = parent?.traversalPatterns {
				self.traversalPatterns = parentPatterns.union(compiled.negationTraversalPatterns)
			} else {
				self.traversalPatterns = compiled.negationTraversalPatterns
			}
			let basenameOnlyNegationCount = (parent?.traversalDiagnostics.basenameOnlyNegationCount ?? 0)
				+ compiled.traversalDiagnostics.basenameOnlyNegationCount
			self.traversalDiagnostics = NegationTraversalDiagnostics(
				exactPrefixCount: traversalPrefixes.count,
				patternHintCount: traversalPatterns.count,
				broadPatternHintCount: traversalPatterns.filter(\.isBroad).count,
				basenameOnlyNegationCount: basenameOnlyNegationCount
			)
		}
	}
	
	// MARK: - Storage

	private struct State {
		/// Tail of the linked chain (highest priority layer)
		var tail: RulesNode
		var cachedSnapshot: IgnoreRulesSnapshot?
	}

	private let state: Mutex<State>

	/// Snapshot of the current chain tail. Read under the lock, then used
	/// outside it — a `RulesNode` and everything it points at is immutable, so
	/// the walk cannot observe a torn chain.
	private var tail: RulesNode {
		state.withLock { $0.tail }
	}

	// MARK: - Initialisers

	/// Creates a new instance that starts with the shared default ignore layer.
	public init() {
		self.state = Mutex(State(tail: IgnoreRules.baseNode, cachedSnapshot: nil))
	}

	/// Private designated initialiser used by `clone()` to share the same chain.
	private init(tail: RulesNode) {
		self.state = Mutex(State(tail: tail, cachedSnapshot: nil))
	}
	
	// MARK: - Public API
	
	/// Adds an ignore file as a new *highest-priority* layer.
	///
	/// The `priority` parameter is retained for API compatibility; current
	/// implementation always appends, which fulfils all existing call-sites
	/// where `priority` is monotonically increasing.
	public func addIgnoreFile(content: String, priority: Int, directoryPath: String = "") {
		let compiled = GitignoreCompiler.compile(content: content, directoryPath: directoryPath)
		state.withLock { state in
			state.cachedSnapshot = nil
			state.tail = RulesNode(compiled: compiled, parent: state.tail)
		}
	}
	
	/// Return `true` if, after consulting all layers from highest to lowest,
	/// the path should be ignored.  (String-based entry point – kept for
	/// backward compatibility, now delegates to the component-based fast path.)
	public func isIgnored(relativePath: String, isDirectory: Bool) -> Bool {
		let comps = relativePath.split(separator: "/")
		return matchOutcome(relativePathComponents: comps, isDirectory: isDirectory) == .ignore
	}
	
	/// Fast overload that accepts **pre-split** path components to avoid the
	/// repeated allocation from `split(separator:)` in tight loops.
	public func isIgnored(relativePathComponents comps: [Substring], isDirectory: Bool) -> Bool {
		return matchOutcome(relativePathComponents: comps, isDirectory: isDirectory) == .ignore
	}
	
	/// Returns the highest-priority match outcome for the given path, or nil if
	/// no pattern matches. This is used by hierarchical evaluators that need to
	/// understand whether a match was produced by an ignore or negation rule.
	public func matchOutcome(relativePathComponents comps: [Substring], isDirectory: Bool) -> CompiledIgnoreRules.MatchOutcome? {
		var node: RulesNode? = tail
		while let current = node {
			switch current.compiled.outcome(for: comps, isDirectory: isDirectory) {
			case .ignore: return .ignore
			case .allow:  return .allow
			case .noMatch: break          // Keep searching in lower-priority layers
			}
			node = current.parent
		}
		return nil
	}
	
	/// Fast aggregate check used by directory traversal code.
	public func hasAnyNegativePatterns() -> Bool {
		return tail.hasNegative
	}

	/// Builds a transient direct-file leaf matcher for positive-only rules.
	/// Precondition: the caller has already proven the parent directory is not ignored;
	/// directory-only patterns are skipped on that basis because the leaf is a regular file.
	public func makePositiveOnlyDirectFileLeafMatcher(parentComponents: [Substring]) -> PositiveOnlyDirectFileLeafMatcher? {
		let tail = self.tail
		guard !tail.hasNegative else { return nil }
		let parentPath = parentComponents.joined(separator: "/")
		var predicates: [PositiveOnlyDirectFileLeafPredicate] = []
		predicates.reserveCapacity(tail.activePatternCount)

		var candidatePatternCount = 0
		var node: RulesNode? = tail
		while let current = node {
			candidatePatternCount += current.compiled.activePatternCount
			guard current.compiled.appendPositiveOnlyDirectFileLeafPredicates(
				parentPath: parentPath,
				to: &predicates
			) else {
				return nil
			}
			node = current.parent
		}

		return PositiveOnlyDirectFileLeafMatcher(
			predicates: predicates,
			candidatePatternCount: candidatePatternCount
		)
	}
	
	/// Returns true if any negative rule requires us to keep scanning the
	/// directory located at `path` (relative to the repository root).
	public func requiresTraversal(for path: String) -> Bool {
		let tail = self.tail
		#if DEBUG
		let recordIgnoreMetrics = IgnoreDebugMetricsRecorder.isRecordingEnabled
		if recordIgnoreMetrics {
			IgnoreDebugMetricsRecorder.recordTraversalRequiresCheck()
		}
		#endif
		if tail.traversalPrefixes.contains(path) {
			#if DEBUG
			if recordIgnoreMetrics {
				IgnoreDebugMetricsRecorder.recordTraversalExactPrefixHit()
			}
			#endif
			return true
		}
		for pattern in tail.traversalPatterns {
			#if DEBUG
			if recordIgnoreMetrics {
				IgnoreDebugMetricsRecorder.recordTraversalPatternCheck()
			}
			#endif
			if pattern.matches(directoryPath: path) {
				#if DEBUG
				if recordIgnoreMetrics {
					IgnoreDebugMetricsRecorder.recordTraversalPatternHit()
				}
				#endif
				return true
			}
		}
		return false
	}

	public var traversalDiagnostics: NegationTraversalDiagnostics {
		tail.traversalDiagnostics
	}
	
	/// Returns a shallow clone that *shares* all rule layers with the original.
	public func clone() -> IgnoreRules {
		return IgnoreRules(tail: tail)
	}
	
	/// The number of rule layers (including defaults).
	public var depth: Int {
		tail.depth
	}

	/// The aggregate number of active patterns in all layers.
	public var activePatternCount: Int {
		tail.activePatternCount
	}

	/// Returns true when this instance shares the exact same rule chain storage.
	public func sharesRuleStorage(with other: IgnoreRules) -> Bool {
		tail === other.tail
	}


	/// Immutable snapshot safe to send off-actor.
	public func snapshot() -> IgnoreRulesSnapshot {
		state.withLock { state in
			if let cached = state.cachedSnapshot {
				return cached
			}
			let tail = state.tail
			var layers: [CompiledIgnoreRules] = []
			layers.reserveCapacity(tail.depth)
			var node: RulesNode? = tail
			while let current = node {
				layers.append(current.compiled)
				node = current.parent
			}
			let snapshot = IgnoreRulesSnapshot(
				layers: layers,
				hasNegative: tail.hasNegative,
				traversalPrefixes: tail.traversalPrefixes,
				traversalPatterns: tail.traversalPatterns,
				traversalDiagnostics: tail.traversalDiagnostics
			)
			state.cachedSnapshot = snapshot
			return snapshot
		}
	}
	
	// MARK: - Static shared default layer
	
	/// The literal default ignore patterns, extracted from the previous impl.
	private static let defaultIgnoreContent = """
	# Version Control
	.git
	.svn
	
	# System Files
	.DS_Store
	Thumbs.db
	"""
	
	/// Shared immutable node containing the default ignore rules.
	private static let baseNode: RulesNode = {
		let compiled = GitignoreCompiler.compile(content: defaultIgnoreContent)
		return RulesNode(compiled: compiled, parent: nil)
	}()
}

public struct IgnoreRulesSnapshot: Sendable {
	fileprivate let layers: [CompiledIgnoreRules]
	private let hasNegative: Bool
	private let traversalPrefixes: Set<String>
	private let traversalPatterns: Set<NegationTraversalPattern>
	public let traversalDiagnostics: NegationTraversalDiagnostics

	fileprivate init(
		layers: [CompiledIgnoreRules],
		hasNegative: Bool,
		traversalPrefixes: Set<String>,
		traversalPatterns: Set<NegationTraversalPattern>,
		traversalDiagnostics: NegationTraversalDiagnostics
	) {
		self.layers = layers
		self.hasNegative = hasNegative
		self.traversalPrefixes = traversalPrefixes
		self.traversalPatterns = traversalPatterns
		self.traversalDiagnostics = traversalDiagnostics
	}

	public func isIgnored(relativePath: String, isDirectory: Bool) -> Bool {
		let comps = relativePath.split(separator: "/")
		return matchOutcome(relativePathComponents: comps, isDirectory: isDirectory) == .ignore
	}

	public func isIgnored(relativePathComponents comps: [Substring], isDirectory: Bool) -> Bool {
		return matchOutcome(relativePathComponents: comps, isDirectory: isDirectory) == .ignore
	}

	public func matchOutcome(
		relativePathComponents comps: [Substring],
		isDirectory: Bool
	) -> CompiledIgnoreRules.MatchOutcome? {
		for compiled in layers {
			switch compiled.outcome(for: comps, isDirectory: isDirectory) {
			case .ignore: return .ignore
			case .allow: return .allow
			case .noMatch: break
			}
		}
		return nil
	}

	public func hasAnyNegativePatterns() -> Bool {
		return hasNegative
	}

	public func requiresTraversal(for path: String) -> Bool {
		#if DEBUG
		let recordIgnoreMetrics = IgnoreDebugMetricsRecorder.isRecordingEnabled
		if recordIgnoreMetrics {
			IgnoreDebugMetricsRecorder.recordTraversalRequiresCheck()
		}
		#endif
		if traversalPrefixes.contains(path) {
			#if DEBUG
			if recordIgnoreMetrics {
				IgnoreDebugMetricsRecorder.recordTraversalExactPrefixHit()
			}
			#endif
			return true
		}
		for pattern in traversalPatterns {
			#if DEBUG
			if recordIgnoreMetrics {
				IgnoreDebugMetricsRecorder.recordTraversalPatternCheck()
			}
			#endif
			if pattern.matches(directoryPath: path) {
				#if DEBUG
				if recordIgnoreMetrics {
					IgnoreDebugMetricsRecorder.recordTraversalPatternHit()
				}
				#endif
				return true
			}
		}
		return false
	}
}

public extension IgnoreRules {
	/// Appends a **pre-compiled** layer as the new highest-priority node.
	/// This avoids recompiling the same file multiple times when the caller
	/// already has a `CompiledIgnoreRules` instance.
	func addCompiledLayer(_ compiled: CompiledIgnoreRules) {
		state.withLock { state in
			state.cachedSnapshot = nil
			state.tail = RulesNode(compiled: compiled, parent: state.tail)
		}
	}
}
