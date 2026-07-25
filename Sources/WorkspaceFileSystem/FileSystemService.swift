import Foundation
import WorkspaceIgnore
import WorkspacePathsCore
import Combine
import Dispatch
import Synchronization
import CoreServices
#if DEBUG || EDIT_FLOW_PERF
import os
#endif
import CoreFoundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

public enum FileSystemPublishPerf {
	#if DEBUG || EDIT_FLOW_PERF
	public typealias State = OSSignpostIntervalState
	public static let signposter = OSSignposter(subsystem: "com.repoprompt.workspace", category: "fs-publish")
	public static var isEnabled: Bool {
		UserDefaults.standard.bool(forKey: "enableRepoFileReplaySignposts")
	}
	public static func begin(_ name: StaticString) -> State? {
		guard isEnabled else { return nil }
		return signposter.beginInterval(name)
	}
	public static func end(_ name: StaticString, _ state: State?) {
		guard isEnabled, let state else { return }
		signposter.endInterval(name, state)
	}
	#else
	public struct State: Sendable {}
	public static var isEnabled: Bool { false }
	public static func begin(_ name: StaticString) -> State? { nil }
	public static func end(_ name: StaticString, _ state: State?) {}
	#endif
}

public enum FileSystemDelta: Sendable, Equatable {
	case fileAdded(String)
	case fileRemoved(String)
	case folderAdded(String)
	case folderRemoved(String)
	case fileModified(String, Date?)      // observed disk mtime when available
	case folderModified(String, Date? = nil)    // observed disk mtime when available
}

public enum CatalogRegularFileIneligibilityReason: Sendable, Equatable, CustomStringConvertible {
	case invalidRelativePath
	case outsideRoot
	case missingOrDirectory
	case symbolicLink
	case nonRegularFile
	case symlinkComponent
	case outsideCanonicalRoot
	case ignored

	public var description: String {
		switch self {
		case .invalidRelativePath:
			return "invalid relative path"
		case .outsideRoot:
			return "path is outside the workspace root"
		case .missingOrDirectory:
			return "path is missing or is a directory"
		case .symbolicLink:
			return "path is a symbolic link"
		case .nonRegularFile:
			return "path is not a regular file"
		case .symlinkComponent:
			return "path contains a symbolic-link component"
		case .outsideCanonicalRoot:
			return "canonical path is outside the workspace root"
		case .ignored:
			return "path is ignored by workspace policy"
		}
	}
}

public enum CatalogRegularFileEligibility: Sendable, Equatable {
	case eligible
	case ineligible(CatalogRegularFileIneligibilityReason)

	public var isEligible: Bool {
		if case .eligible = self { return true }
		return false
	}
}

public struct FSItemDTO: Sendable {
	public let relativePath: String
	public let isDirectory: Bool
	public let hierarchy: Int

	public init(relativePath: String, isDirectory: Bool, hierarchy: Int) {
		self.relativePath = relativePath
		self.isDirectory = isDirectory
		self.hierarchy = hierarchy
	}
}

public struct FSPreparedChunk: Sendable {
	public let folders: [FSItemDTO]
	public let files: [FSItemDTO]

	public init(folders: [FSItemDTO], files: [FSItemDTO]) {
		self.folders = folders
		self.files = files
	}
}

private struct FSEventCallbackEntry: Sendable {
	public let path: String
	public let flags: FSEventStreamEventFlags
	public let id: FSEventStreamEventId
}

private struct FSEventCallbackPayload: Sendable {
	public let entries: [FSEventCallbackEntry]

	public var count: Int {
		entries.count
	}
}

#if DEBUG
public struct EventTargetIgnoreFastPathDiagnostics: Sendable, Equatable {
	public var unknownRegularFileDecisionCount = 0
	public var parentStateCacheHitCount = 0
	public var parentStateCacheMissCount = 0
	public var exactParentStateCount = 0
	public var unsupportedParentStateCount = 0
	public var directLeafCheckCount = 0
	public var directLeafIgnoredCount = 0
	public var fallbackFullTargetIgnoreCheckCount = 0
	public var fallbackFullTargetIgnoredCount = 0
	public var exactFullTargetIgnoreCheckCount = 0
	public var skippedKnownOrControlTargetIgnoreCheckCount = 0
}

public struct EventPathMappingFastPathDiagnostics: Sendable, Equatable {
	public var rawPathCount = 0
	public var fastStandardRootHitCount = 0
	public var fastCanonicalRootHitCount = 0
	public var fallbackStandardizationCount = 0
	public var rejectedUnsafePathCount = 0
}
#endif

#if DEBUG
public struct PublishedDeltaCoalescingDiagnostics: Sendable, Equatable {
	public let rawDeltaCount: Int
	public let publishedDeltaCount: Int
}

public struct CatalogEligibilityFallbackCounts: Sendable, Equatable {
	public var parentSymlinkComponent = 0
	public var directoryScanFailure = 0
	public var missingEntry = 0
	public var unknownEntryRegularFileMetadata = 0
	public var preparedIgnoreRulesFailure = 0
	public var preparedRuleMiss = 0
	public var invalidLeafName = 0
}

public struct CatalogEligibilityResultReasonCounts: Sendable, Equatable {
	public var eligible = 0
	public var invalidRelativePath = 0
	public var outsideRoot = 0
	public var missingOrDirectory = 0
	public var symbolicLink = 0
	public var nonRegularFile = 0
	public var symlinkComponent = 0
	public var outsideCanonicalRoot = 0
	public var ignored = 0
}

public struct CatalogRegularFileEligibilityBatchDiagnostics: Sendable, Equatable {
	public var rawInputCount = 0
	public var uniqueStandardizedPathCount = 0
	public var resultCount = 0
	public var preparedRelativePathFastPathAttemptCount = 0
	public var preparedRelativePathFastPathUsedCount = 0
	public var preparedRelativePathFastPathFallbackCount = 0
	public var preparedRelativePathFastPathInputCount = 0
	public var preparedRelativePathFastPathGroupedEntryCount = 0
	public var preparedRelativePathFastPathParentReuseHitCount = 0
	public var preparedRelativePathFastPathParentReuseMissCount = 0
	public var parentGroupCount = 0
	public var maxParentGroupSize = 0
	public var standardizeAndGroupDurationMS = 0.0
	public var parentProcessingDurationMS = 0.0
	public var directoryScanGroupCount = 0
	public var directoryScanFailureGroupCount = 0
	public var directoryScanDurationMS = 0.0
	public var directoryEntryCount = 0
	public var entriesMapBuildDurationMS = 0.0
	public var canonicalParentResolveDurationMS = 0.0
	public var preparedIgnoreRulesGroupCount = 0
	public var preparedIgnoreRulesFailureGroupCount = 0
	public var preparedIgnoreRulesDurationMS = 0.0
	public var preparedIgnoreRulesCacheHitDirectoryCount = 0
	public var preparedIgnoreRulesCacheMissDirectoryCount = 0
	public var hierarchicalIgnoreCheckCount = 0
	public var hierarchicalIgnoreNoOpParentGroupCount = 0
	public var hierarchicalIgnoreSkippedLeafCheckCount = 0
	public var hierarchicalIgnoreDurationMS = 0.0
	public var prefixIgnoreCheckCount = 0
	public var prefixIgnoreNoOpParentGroupCount = 0
	public var prefixIgnoreSkippedLeafCheckCount = 0
	public var prefixIgnoreDurationMS = 0.0
	public var prefixDirectLeafFastPathParentGroupCount = 0
	public var prefixDirectLeafFastPathUnsupportedParentGroupCount = 0
	public var prefixDirectLeafFastPathLeafCheckCount = 0
	public var prefixDirectLeafFastPathIgnoredLeafCount = 0
	public var prefixDirectLeafFastPathCandidatePatternCountTotal = 0
	public var prefixDirectLeafFastPathCandidatePatternCountMax = 0
	public var prefixDirectLeafFastPathDurationMS = 0.0
	public var prefixParentRuleShapeGroupCount = 0
	public var prefixParentRuleDepthTotal = 0
	public var prefixParentRuleDepthMax = 0
	public var prefixParentActivePatternCountTotal = 0
	public var prefixParentActivePatternCountMax = 0
	public var prefixParentHasNegativePatternGroupCount = 0
	public var singleFileFallbackUniquePathCount = 0
	public var singleFileFallbackDurationMS = 0.0
	public var fallbackCounts = CatalogEligibilityFallbackCounts()
	public var resultReasonCounts = CatalogEligibilityResultReasonCounts()
}

private enum CatalogEligibilityFallbackReason {
	case parentSymlinkComponent
	case directoryScanFailure
	case missingEntry
	case unknownEntryRegularFileMetadata
	case preparedIgnoreRulesFailure
	case preparedRuleMiss
	case invalidLeafName
}

private final class CatalogRegularFileEligibilityBatchDiagnosticsAccumulator {
	var diagnostics = CatalogRegularFileEligibilityBatchDiagnostics()

	public func recordPrefixParentRuleShape(ignoreRules: IgnoreRules) {
		diagnostics.prefixParentRuleShapeGroupCount += 1
		diagnostics.prefixParentRuleDepthTotal += ignoreRules.depth
		diagnostics.prefixParentRuleDepthMax = max(diagnostics.prefixParentRuleDepthMax, ignoreRules.depth)
		diagnostics.prefixParentActivePatternCountTotal += ignoreRules.activePatternCount
		diagnostics.prefixParentActivePatternCountMax = max(
			diagnostics.prefixParentActivePatternCountMax,
			ignoreRules.activePatternCount
		)
		if ignoreRules.hasAnyNegativePatterns() {
			diagnostics.prefixParentHasNegativePatternGroupCount += 1
		}
	}

	public func recordPrefixDirectLeafFastPathParentGroup(candidatePatternCount: Int) {
		diagnostics.prefixDirectLeafFastPathParentGroupCount += 1
		diagnostics.prefixDirectLeafFastPathCandidatePatternCountTotal += candidatePatternCount
		diagnostics.prefixDirectLeafFastPathCandidatePatternCountMax = max(
			diagnostics.prefixDirectLeafFastPathCandidatePatternCountMax,
			candidatePatternCount
		)
	}

	public func recordPrefixDirectLeafFastPathUnsupportedParentGroup() {
		diagnostics.prefixDirectLeafFastPathUnsupportedParentGroupCount += 1
	}

	public func recordPrefixDirectLeafFastPathLeafCheck(ignored: Bool, durationMS: Double) {
		diagnostics.prefixDirectLeafFastPathLeafCheckCount += 1
		if ignored {
			diagnostics.prefixDirectLeafFastPathIgnoredLeafCount += 1
		}
		diagnostics.prefixDirectLeafFastPathDurationMS += durationMS
		diagnostics.prefixIgnoreDurationMS += durationMS
	}

	public func recordPrefixDirectLeafFastPathBuildDuration(_ durationMS: Double) {
		diagnostics.prefixDirectLeafFastPathDurationMS += durationMS
		diagnostics.prefixIgnoreDurationMS += durationMS
	}

	public func recordResult(_ eligibility: CatalogRegularFileEligibility) {
		switch eligibility {
		case .eligible:
			diagnostics.resultReasonCounts.eligible += 1
		case .ineligible(let reason):
			switch reason {
			case .invalidRelativePath:
				diagnostics.resultReasonCounts.invalidRelativePath += 1
			case .outsideRoot:
				diagnostics.resultReasonCounts.outsideRoot += 1
			case .missingOrDirectory:
				diagnostics.resultReasonCounts.missingOrDirectory += 1
			case .symbolicLink:
				diagnostics.resultReasonCounts.symbolicLink += 1
			case .nonRegularFile:
				diagnostics.resultReasonCounts.nonRegularFile += 1
			case .symlinkComponent:
				diagnostics.resultReasonCounts.symlinkComponent += 1
			case .outsideCanonicalRoot:
				diagnostics.resultReasonCounts.outsideCanonicalRoot += 1
			case .ignored:
				diagnostics.resultReasonCounts.ignored += 1
			}
		}
	}

	public func recordFallback(reason: CatalogEligibilityFallbackReason, durationMS: Double, result: CatalogRegularFileEligibility) {
		diagnostics.singleFileFallbackUniquePathCount += 1
		diagnostics.singleFileFallbackDurationMS += durationMS
		switch reason {
		case .parentSymlinkComponent:
			diagnostics.fallbackCounts.parentSymlinkComponent += 1
		case .directoryScanFailure:
			diagnostics.fallbackCounts.directoryScanFailure += 1
		case .missingEntry:
			diagnostics.fallbackCounts.missingEntry += 1
		case .unknownEntryRegularFileMetadata:
			diagnostics.fallbackCounts.unknownEntryRegularFileMetadata += 1
		case .preparedIgnoreRulesFailure:
			diagnostics.fallbackCounts.preparedIgnoreRulesFailure += 1
		case .preparedRuleMiss:
			diagnostics.fallbackCounts.preparedRuleMiss += 1
		case .invalidLeafName:
			diagnostics.fallbackCounts.invalidLeafName += 1
		}
		recordResult(result)
	}
}
#endif

public enum LoadContentsEvent: Sendable {
	case totalFileCount(Int)                                // emitted at least once, first emission precedes item payloads
	case items([(any FileSystemItem, [String])])            // legacy compatibility
	case preparedItems(FSPreparedChunk)                     // preferred streaming payload
}

/// Actor-based file service that watches an entire directory (recursively) via FSEvents,
/// and provides file manipulation utilities.
public actor FileSystemService {
	/// Injected charset-detection backend (adoption slice 4 seam) — the app
	/// supplies a Cuchardet-backed detector; the default uses Foundation
	/// heuristics only.
	public let charsetDetector: any WorkspaceCharsetDetecting

	private let fileManager = FileManager.default
	private static let maxPendingRawEvents = 50_000
	private static let overflowRescanEventFlags = FSEventStreamEventFlags(
		kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
	)
	
	#if DEBUG
	/// Backing storage for `enableDebugLogging`.
	///
	/// The flag is a standalone boolean: nothing else is published through it
	/// and no invariant ties it to other state, so `.relaxed` ordering is
	/// sufficient — a reader only needs to observe some consistent value. An
	/// `Atomic` (rather than `nonisolated(unsafe)`) keeps the global genuinely
	/// concurrency-safe while preserving the public `var` shape.
	private static let debugLoggingEnabled = Atomic<Bool>(false)

	/// Static flag to enable verbose debug logging (default: false)
	public static var enableDebugLogging: Bool {
		get { debugLoggingEnabled.load(ordering: .relaxed) }
		set { debugLoggingEnabled.store(newValue, ordering: .relaxed) }
	}
	#endif

	private func fileSystemDebugLog(_ message: @autoclosure () -> String) {
		#if DEBUG
		guard Self.enableDebugLogging else { return }
		print(message())
		#endif
	}
	
	#if DEBUG
	/// Test-only override for FileManager
	private var fileManagerOverride: (any TestFS)?
	
	/// Returns the appropriate file manager (test override or default)
	private var fm: any TestFS {
		return fileManagerOverride ?? fileManager
	}

	/// `fm`, boxed so it can be read from another isolation domain (the
	/// off-actor scan helpers). `TestFS` cannot refine `Sendable` — see
	/// `TestFSTransfer` for the invariant that makes this legal.
	private var fmTransfer: TestFSTransfer {
		TestFSTransfer(fm)
	}
	#else
	/// In release builds, always use FileManager.default
	private var fm: FileManager { fileManager }
	#endif
	
	/// Tracks paths we know about, to detect additions/removals
	private var visitedPaths = Set<String>()
	
	/// True => directory, False => file
	private var visitedItems = [String: Bool]()
	
	/// The FSEvent stream reference
	private var fseventStreamRef: FSEventStreamRef?
	
	/// Publishes arrays of deltas whenever changes occur
	private let changePublisher = PassthroughSubject<[FileSystemDelta], Never>()

	/// Live `changesStream()` subscriptions, keyed by stream identity. Combine's
	/// `AnyCancellable` is not `Sendable`, so the cancellable is created and
	/// retained entirely inside this actor and is only ever released here (via
	/// `endChangesStream(_:)`, hopped back from the stream's termination
	/// handler). Nothing non-`Sendable` crosses the actor boundary.
	private var changeStreamSubscriptions: [UUID: AnyCancellable] = [:]
	#if DEBUG
	private var lastPublishedDeltaCoalescingDiagnostics: PublishedDeltaCoalescingDiagnostics?
	private var lastEventTargetIgnoreFastPathDiagnostics: EventTargetIgnoreFastPathDiagnostics?
	private var lastEventPathMappingFastPathDiagnostics: EventPathMappingFastPathDiagnostics?
	#endif
	
	/// Retained pointer to self (to avoid deallocation while FSEvent stream is active)
	private var selfPointer: UnsafeMutableRawPointer?
	
	/// The in-memory IgnoreRules instance for our path
	private var ignoreRules: IgnoreRules
	
	private var ignoreCacheStore = IgnoreCacheStore()
	
	/// Caches the detected encoding for every file we have successfully opened
	private var encodingMap = [String: String.Encoding]()
	
	/// Path we are managing
	public let path: String
	private let rootURL: URL
	private let canonicalRootURL: URL
	/// The root as the kernel reports it (POSIX realpath). Unlike
	/// `resolvingSymlinksInPath()`, realpath keeps the `/private` prefix, which
	/// is the form FSEvents delivers for roots under symlinked locations
	/// (/tmp, /var, …). Event mapping must prefix-match against this form with
	/// pure string operations: the standardization fallbacks strip `/private`
	/// only when the path still exists, so events for just-deleted paths would
	/// otherwise map outside the root and be dropped.
	private let realRootPath: String
	private var canonicalRootPath: String { canonicalRootURL.path }
	private var standardizedRootPath: String { rootURL.path }
	private var respectGitignore: Bool
	private var respectRepoIgnore: Bool
	private var respectCursorignore: Bool
	private var skipSymlinks: Bool
	private var enableHierarchicalIgnores: Bool
	
	// MARK: - Ignore rules change tracking (revision-based for durability)
	/// Monotonic revision incremented each time ignore files change
	private var ignoreRulesRevision: UInt64 = 0
	/// Directories affected by ignore file changes since last consumption
	private var pendingIgnoreChangeDirs: Set<String> = []
	
	// A buffer for raw FSEvents + coalescing logic
	private var pendingFSEvents: [(String, FSEventStreamEventFlags, FSEventStreamEventId)] = []
	private var hasPendingOverflowRescan = false
	private var overflowChangedIgnoreDirs: Set<String> = []
	private var coalescingTask: Task<Void, Never>? = nil
	private let coalescingDelay: TimeInterval = 0.2
	
	// MARK: - Event ID-based scan coalescing (prevents dropped events while deduping bursts)
	/// Maps folder relative path → highest FSEvent ID that requires scanning
	private var pendingScanTargets: [String: FSEventStreamEventId] = [:]
	/// Maps folder relative path → highest FSEvent ID that has already been scanned
	private var lastScannedEventIdByFolder: [String: FSEventStreamEventId] = [:]


	/// Short-lived cache
	/// results during a directory walk to avoid repeated allocations.
	private var pathCompsCache = PathComponentsCache()
	
	/// Maximum number of cached ignore rules (default: 4000)
	private static let ignoreCacheCapacity = 4000

	/// Cache for per-folder ignore rules (key = directory's relative path, "" for root)
	private var perFolderIgnoreCache = LRUCache<String, IgnoreRules>(
		capacity: FileSystemService.ignoreCacheCapacity
	)
	
	/// Bounded marker cache for directories that have no ignore files.
	/// Eviction is safe: it only causes an extra filesystem recheck.
	private var noIgnoreFileCache = LRUCache<String, Bool>(
		capacity: FileSystemService.ignoreCacheCapacity
	)
	
	// MARK: - Parallelism Throttling
	
	/// Maximum concurrent directory scans per actor (prevents CPU saturation)
	private let maxParallelScansPerActor: Int
	
	/// Maximum folders to scan in a single batch (bounds per-tick work)
	private let maxFoldersPerBatch: Int
	
	// MARK: - Safety-Net Verification
	
	/// Minimum interval between safety-net scans for the same folder (seconds)
	private let safetyNetMinInterval: TimeInterval = 300  // 5 minutes
	
	/// Number of file events before triggering a safety-net parent scan
	private let safetyNetEventThreshold: Int = 200
	
	/// Tracks when each folder was last verified via directory scan
	private var lastVerifiedAtByFolder: [String: TimeInterval] = [:]
	
	/// Tracks file event count per folder since last verification
	private var fileEventCountSinceLastScan: [String: Int] = [:]
	
	// MARK: - Init
	
	/// Initializes the FileSystemService for a given path, applying ignore rules, optionally skipping symlinks,
	/// and immediately starting an FSEvents watcher to track changes in that path.
	public init(
		path: String,
		respectGitignore: Bool = true,
		respectRepoIgnore: Bool = true,
		respectCursorignore: Bool = true,
		skipSymlinks: Bool = true,
		enableHierarchicalIgnores: Bool = true,
		charsetDetector: any WorkspaceCharsetDetecting = FoundationOnlyCharsetDetector()
	) async throws {
		self.charsetDetector = charsetDetector
		self.path = path
		self.rootURL = URL(fileURLWithPath: path).standardizedFileURL
		self.canonicalRootURL = rootURL.resolvingSymlinksInPath()
		self.realRootPath = Self.posixRealPath(rootURL.path) ?? canonicalRootURL.path
		self.respectGitignore = respectGitignore
		self.respectRepoIgnore = respectRepoIgnore
		self.respectCursorignore = respectCursorignore
		self.skipSymlinks = skipSymlinks
		self.enableHierarchicalIgnores = enableHierarchicalIgnores
		
		// Configure parallelism caps based on available cores
		let cores = ProcessInfo.processInfo.activeProcessorCount
		self.maxParallelScansPerActor = max(2, min(4, cores / 2))
		self.maxFoldersPerBatch = 256
		
		// Load fresh ignore rules from manager, no caching done by manager
		self.ignoreRules = try await IgnoreRulesManager.shared.getIgnoreRules(
			for: path,
			respectGitignore: respectGitignore,
			respectRepoIgnore: respectRepoIgnore,
			respectCursorignore: respectCursorignore
		)
		
		// Initialize root-level ignore rules in per-folder cache
		cacheIgnoreRules(ignoreRules, for: "")
	}
	
	#if DEBUG
	// MARK: - Testing Support
	
	/// Flag to enable test mode
	private var isTestMode = false

	nonisolated static func deepCopiedEventPathForTesting(_ source: NSString) -> String? {
		deepCopyEventPath(source as CFString)
	}

	nonisolated static func buildOwnedFSEventPayloadForTesting(
		pathObjects: [Any],
		flags: [FSEventStreamEventFlags],
		ids: [FSEventStreamEventId],
		limit: Int? = nil
	) -> (paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId])? {
		let safeCount = min(limit ?? pathObjects.count, pathObjects.count, flags.count, ids.count)
		guard safeCount > 0 else { return nil }

		var copiedPaths: [String] = []
		var copiedFlags: [FSEventStreamEventFlags] = []
		var copiedIDs: [FSEventStreamEventId] = []
		copiedPaths.reserveCapacity(safeCount)
		copiedFlags.reserveCapacity(safeCount)
		copiedIDs.reserveCapacity(safeCount)

		for index in 0..<safeCount {
			let copiedPath: String?
			switch pathObjects[index] {
			case let string as NSString:
				copiedPath = deepCopyEventPath(string as CFString)
			case let string as String:
				copiedPath = deepCopySwiftString(string)
			default:
				copiedPath = nil
			}

			guard let copiedPath else { continue }
			copiedPaths.append(copiedPath)
			copiedFlags.append(flags[index])
			copiedIDs.append(ids[index])
		}

		guard !copiedPaths.isEmpty else { return nil }
		return (copiedPaths, copiedFlags, copiedIDs)
	}

	nonisolated static func fseventCallbackEntryCountForTesting(
		pathObjects: [AnyObject],
		flags: [FSEventStreamEventFlags],
		ids: [FSEventStreamEventId],
		limit: Int? = nil
	) -> Int {
		let safeCount = min(limit ?? pathObjects.count, pathObjects.count, flags.count, ids.count)
		guard safeCount > 0 else { return 0 }
		let cfArray = pathObjects as CFArray
		let eventPaths = UnsafeMutableRawPointer(Unmanaged.passUnretained(cfArray).toOpaque())
		return flags.withUnsafeBufferPointer { flagBuffer in
			guard let flagBase = flagBuffer.baseAddress else { return 0 }
			return ids.withUnsafeBufferPointer { idBuffer in
				guard let idBase = idBuffer.baseAddress else { return 0 }
				return buildOwnedFSEventPayload(
					numEvents: safeCount,
					eventPaths: eventPaths,
					eventFlags: flagBase,
					eventIds: idBase
				)?.entries.count ?? 0
			}
		}
	}

	nonisolated static func buildOwnedFSEventPayloadFromCFArrayForTesting(
		pathObjects: [AnyObject],
		flags: [FSEventStreamEventFlags],
		ids: [FSEventStreamEventId],
		limit: Int? = nil
	) -> (paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId])? {
		let safeCount = min(limit ?? pathObjects.count, pathObjects.count, flags.count, ids.count)
		guard safeCount > 0 else { return nil }
		let cfArray = pathObjects as CFArray
		let eventPaths = UnsafeMutableRawPointer(Unmanaged.passUnretained(cfArray).toOpaque())
		return flags.withUnsafeBufferPointer { flagBuffer in
			guard let flagBase = flagBuffer.baseAddress else { return nil }
			return ids.withUnsafeBufferPointer { idBuffer in
				guard let idBase = idBuffer.baseAddress else { return nil }
				guard let payload = buildOwnedFSEventPayload(
					numEvents: safeCount,
					eventPaths: eventPaths,
					eventFlags: flagBase,
					eventIds: idBase
				) else { return nil }
				return (
					payload.entries.map(\.path),
					payload.entries.map(\.flags),
					payload.entries.map(\.id)
				)
			}
		}
	}
	
	/// Test-only initializer that allows injecting initial state
	public init(
		path: String,
		respectGitignore: Bool = true,
		respectRepoIgnore: Bool = true,
		respectCursorignore: Bool = true,
		skipSymlinks: Bool = true,
		enableHierarchicalIgnores: Bool = true,
		testVisitedPaths: Set<String>? = nil,
		testVisitedItems: [String: Bool]? = nil,
		testIgnoreRules: IgnoreRules? = nil,
		isTestMode: Bool = false,
		fileManagerOverride: (any TestFS)? = nil,
		maxParallelScansOverride: Int? = nil,
		maxFoldersPerBatchOverride: Int? = nil,
		charsetDetector: any WorkspaceCharsetDetecting = FoundationOnlyCharsetDetector()
	) async throws {
		self.charsetDetector = charsetDetector
		self.path = path
		self.rootURL = URL(fileURLWithPath: path).standardizedFileURL
		self.canonicalRootURL = rootURL.resolvingSymlinksInPath()
		self.realRootPath = Self.posixRealPath(rootURL.path) ?? canonicalRootURL.path
		self.respectGitignore = respectGitignore
		self.respectRepoIgnore = respectRepoIgnore
		self.respectCursorignore = respectCursorignore
		self.skipSymlinks = skipSymlinks
		self.enableHierarchicalIgnores = enableHierarchicalIgnores
		self.isTestMode = isTestMode
		self.fileManagerOverride = fileManagerOverride
		
		// Configure parallelism caps (allow test overrides)
		let cores = ProcessInfo.processInfo.activeProcessorCount
		self.maxParallelScansPerActor = maxParallelScansOverride ?? max(2, min(4, cores / 2))
		self.maxFoldersPerBatch = maxFoldersPerBatchOverride ?? 256
		
		// Use test data if provided
		if let paths = testVisitedPaths {
			self.visitedPaths = paths
		}
		if let items = testVisitedItems {
			self.visitedItems = items
		}
		
		#if DEBUG
		// Keep the singleton test override scoped to this service. Passing nil is
		// intentional: earlier InMemoryFS tests must not leak into later real-FS tests.
		//
		// The double is deliberately observed by BOTH this actor and the
		// IgnoreRulesManager actor, so it has to cross an isolation boundary.
		// `TestFSTransfer` carries the documented invariant that makes that
		// legal (see its doc comment); `TestFS` itself cannot refine `Sendable`
		// because `FileManager` conforms to it.
		let overrideTransfer = TestFSTransfer(fileManagerOverride)
		await IgnoreRulesManager.shared.setFileManagerOverride(overrideTransfer.fileSystem)
		#endif

		// Use test ignore rules or load fresh ones
		if let rules = testIgnoreRules {
			self.ignoreRules = rules
		} else {
			self.ignoreRules = try await IgnoreRulesManager.shared.getIgnoreRules(
				for: path,
				respectGitignore: respectGitignore,
				respectRepoIgnore: respectRepoIgnore,
				respectCursorignore: respectCursorignore
			)
		}
		
		// Initialize root-level ignore rules in per-folder cache
		cacheIgnoreRules(ignoreRules, for: "")
	}
	
	/// Test-only tracking of processed events
	private var processedFolders: Set<String> = []
	
	/// Test-only method to simulate FSEvents and capture the resulting deltas
	public func simulateFSEvents(
		_ events: [(absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId)]
	) async -> [FileSystemDelta] {
		// Clear any previous deltas
		processedFolders.removeAll()
		
		// Process the events and get deltas directly
		let formattedEvents = events.map { ($0.absolutePath, $0.flags, $0.eventId) }
		let deltas = await handleBatchedEvents(formattedEvents, testMode: true)
		
		return deltas ?? []
	}
	
	/// Test-only method to get processed folders
	public func getProcessedFolders() -> Set<String> {
		return processedFolders
	}
	
	/// Test-only method to get current state
	public func getTestState() -> (visitedPaths: Set<String>, visitedItems: [String: Bool]) {
		return (visitedPaths, visitedItems)
	}
	
	/// Test-only method to get event ID coalescing state
	public func getCoalescingState() -> (
		pendingScanTargets: [String: FSEventStreamEventId],
		lastScannedEventIdByFolder: [String: FSEventStreamEventId]
	) {
		return (pendingScanTargets, lastScannedEventIdByFolder)
	}

	public func enqueuePendingRawEventsForTesting(
		_ events: [(absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId)]
	) {
		let payload = FSEventCallbackPayload(
			entries: events.map { event in
				FSEventCallbackEntry(path: event.absolutePath, flags: event.flags, id: event.eventId)
			}
		)
		enqueueFSEventHandlingTask(payload)
	}

	public func watcherStateForTesting() -> (
		pendingRawEventCount: Int,
		hasPendingOverflowRescan: Bool,
		overflowChangedIgnoreDirs: Set<String>,
		pendingScanTargets: [String: FSEventStreamEventId],
		lastScannedEventIdByFolder: [String: FSEventStreamEventId],
		lastVerifiedAtByFolder: [String: TimeInterval],
		fileEventCountSinceLastScan: [String: Int]
	) {
		(
			pendingFSEvents.count,
			hasPendingOverflowRescan,
			overflowChangedIgnoreDirs,
			pendingScanTargets,
			lastScannedEventIdByFolder,
			lastVerifiedAtByFolder,
			fileEventCountSinceLastScan
		)
	}
	
	/// Test-only method to get per-folder ignore cache keys
	public func getIgnoreCacheKeys() -> Set<String> {
		return Set(perFolderIgnoreCache.keys)
	}
	
	/// Test-only method to get no-ignore-file cache
	public func getNoIgnoreFileCache() -> Set<String> {
		return Set(noIgnoreFileCache.keys)
	}

	/// Test-only method to get no-ignore-file cache size
	public func getNoIgnoreFileCacheSize() -> Int {
		return noIgnoreFileCache.count
	}

	nonisolated static var ignoreCacheCapacityForTesting: Int {
		ignoreCacheCapacity
	}
	
	/// Test-only method to mock directory contents
	private var mockDirectoryContents: ((String) -> [String])?
	
	public func setMockDirectoryContents(_ provider: @escaping (String) -> [String]) {
		mockDirectoryContents = provider
	}
	
	
	/// Get tracked paths for testing
	public func getTrackedPaths() async -> [String] {
		return Array(visitedPaths)
	}
	
	/// Get per-folder ignore cache size for testing
	public func getPerFolderIgnoreCacheSize() async -> Int {
		return perFolderIgnoreCache.count
	}
	
	/// Public wrapper for scanOneLevelAndDiff for testing
	public func scanOneLevelAndDiff(relativeFolderPath: String) async throws -> [FileSystemDelta] {
		return try await scanOneLevelAndDiff(relativeFolderPath)
	}
	
	/// Get filter hash changed status for testing
	public func getFilterHashChanged() async -> Bool {
		return !pendingIgnoreChangeDirs.isEmpty
	}
	
	/// Get pending ignore change dirs for testing
	public func getPendingIgnoreChangeDirs() async -> Set<String> {
		return pendingIgnoreChangeDirs
	}
	
	/// Test helper to check if a path is ignored using the same hierarchical logic as runtime checks
	public func testIsIgnoredPrefixCheck(relativePath: String) async -> Bool {
		return await isIgnoredHierarchical(relativePath: relativePath)
	}

	public func mapRelativeEventPathForTesting(_ absolutePath: String) -> (isInside: Bool, value: String) {
		switch mapToRelativeEventPath(absolutePath) {
		case .inside(let relative):
			return (true, relative)
		case .outside(let original):
			return (false, original)
		}
	}
	#endif
	
	// MARK: - Ignore rules change consumption
	
	/// Payload describing ignore rules changes since last consumption
	public struct IgnoreRulesChange: Sendable {
		public let revision: UInt64
		public let changedDirs: Set<String>
	}
	
	/// Atomically retrieves and clears pending ignore rules changes.
	/// Returns nil if no ignore files have changed since the last call.
	/// Use this instead of the deprecated `filterHashChanged` property.
	public func takePendingIgnoreRulesChange() -> IgnoreRulesChange? {
		guard !pendingIgnoreChangeDirs.isEmpty else { return nil }
		let change = IgnoreRulesChange(
			revision: ignoreRulesRevision,
			changedDirs: pendingIgnoreChangeDirs
		)
		pendingIgnoreChangeDirs.removeAll()
		return change
	}
	
	// MARK: - Public watchers API
	
	/// Returns a publisher that emits a `[FileSystemDelta]` array whenever changes are detected in the file system.
	public func publisherForChanges() -> AnyPublisher<[FileSystemDelta], Never> {
		changePublisher.eraseToAnyPublisher()
	}

	/// `Sendable` counterpart to `publisherForChanges()` for consumers that live
	/// in another isolation domain.
	///
	/// Combine's `AnyPublisher`/`AnyCancellable` are not `Sendable`, so handing
	/// the publisher itself to (say) a `@MainActor` adapter is a concurrency
	/// error. Instead the subscription is created *and retained* on this actor
	/// and each batch is forwarded through an `AsyncStream<[FileSystemDelta]>`
	/// — `FileSystemDelta` is `Sendable`, and both `AsyncStream` and its
	/// continuation are `Sendable`, so only value types cross the boundary.
	///
	/// Delivery preserves publisher order (the continuation is unbounded and
	/// `yield` is ordered). The subscription is torn down when the consumer
	/// stops iterating (task cancellation or iterator release), which fires
	/// `onTermination`.
	func changesStream() -> AsyncStream<[FileSystemDelta]> {
		let token = UUID()
		let (stream, continuation) = AsyncStream<[FileSystemDelta]>.makeStream()
		changeStreamSubscriptions[token] = changePublisher.sink { deltas in
			continuation.yield(deltas)
		}
		continuation.onTermination = { [weak self] _ in
			guard let self else { return }
			Task { await self.endChangesStream(token) }
		}
		return stream
	}

	/// Releases the Combine subscription backing a `changesStream()` consumer.
	private func endChangesStream(_ token: UUID) {
		changeStreamSubscriptions.removeValue(forKey: token)
	}

	#if DEBUG
	/// Test-only: number of live `changesStream()` subscriptions still retained
	/// by this actor. Internal (not public API) — used to pin the teardown half
	/// of the stream's ownership contract.
	var liveChangesStreamCount: Int {
		changeStreamSubscriptions.count
	}
	#endif

	/// Request to stop watching for changes. This tears down the FSEvent stream.
	public func stopWatchingForChanges() {
		stopFSEventStream()
	}
	
	/// (Re)start the FSEvent stream if needed.
	public func startWatchingForChanges() {
		startFSEventStream()
	}
	
	public func fileExistsOnDisk(relativePath: String) -> Bool {
		let absolutePath = getFullPath(forRelativePath: relativePath)
		return fm.fileExists(atPath: absolutePath, isDirectory: nil)
	}

	private func standardizedCatalogRelativePath(_ rawRelativePath: String) -> String {
		(rawRelativePath as NSString).standardizingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
	}

	public func regularFileExistsOnDisk(relativePath rawRelativePath: String) -> Bool {
		let relativePath = standardizedCatalogRelativePath(rawRelativePath)
		guard !relativePath.isEmpty, !relativePath.hasPrefix("../"), relativePath != ".." else {
			return false
		}
		let absolutePath = getFullPath(forRelativePath: relativePath)
		let standardizedAbsolutePath = (absolutePath as NSString).standardizingPath
		let rootPrefix = standardizedRootPath.hasSuffix("/") ? standardizedRootPath : standardizedRootPath + "/"
		guard standardizedAbsolutePath == standardizedRootPath || standardizedAbsolutePath.hasPrefix(rootPrefix) else {
			return false
		}

		var isDirectory = ObjCBool(false)
		guard fm.fileExists(atPath: standardizedAbsolutePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
			return false
		}
		if let values = try? URL(fileURLWithPath: standardizedAbsolutePath).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
			if values.isSymbolicLink == true { return false }
			if values.isRegularFile == false { return false }
		}
		if skipSymlinks && pathContainsSymlinkComponent(relativePath: relativePath) {
			return false
		}
		return true
	}

	public func catalogEligibleRegularFileExists(relativePath rawRelativePath: String) async -> Bool {
		await catalogRegularFileEligibility(relativePath: rawRelativePath).isEligible
	}

	#if DEBUG
	public func catalogRegularFileEligibilityBatch(relativePaths rawRelativePaths: [String]) async -> [String: CatalogRegularFileEligibility] {
		await catalogRegularFileEligibilityBatchShared(relativePaths: rawRelativePaths, collectDiagnostics: false).results
	}

	public func catalogRegularFileEligibilityBatchWithDiagnosticsForTesting(
		relativePaths rawRelativePaths: [String]
	) async -> (results: [String: CatalogRegularFileEligibility], diagnostics: CatalogRegularFileEligibilityBatchDiagnostics) {
		let output = await catalogRegularFileEligibilityBatchShared(relativePaths: rawRelativePaths, collectDiagnostics: true)
		return (output.results, output.diagnostics ?? CatalogRegularFileEligibilityBatchDiagnostics())
	}

	public func catalogRegularFileEligibilityBatchForPreparedRelativePaths(
		_ preparedRelativePaths: [String]
	) async -> [String: CatalogRegularFileEligibility] {
		await catalogRegularFileEligibilityPreparedBatchShared(
			preparedRelativePaths: preparedRelativePaths,
			collectDiagnostics: false
		).results
	}

	public func catalogRegularFileEligibilityPreparedBatchWithDiagnosticsForTesting(
		preparedRelativePaths: [String]
	) async -> (results: [String: CatalogRegularFileEligibility], diagnostics: CatalogRegularFileEligibilityBatchDiagnostics) {
		let output = await catalogRegularFileEligibilityPreparedBatchShared(
			preparedRelativePaths: preparedRelativePaths,
			collectDiagnostics: true
		)
		return (output.results, output.diagnostics ?? CatalogRegularFileEligibilityBatchDiagnostics())
	}

	private func catalogRegularFileEligibilityPreparedBatchShared(
		preparedRelativePaths: [String],
		collectDiagnostics: Bool
	) async -> (results: [String: CatalogRegularFileEligibility], diagnostics: CatalogRegularFileEligibilityBatchDiagnostics?) {
		let diagnosticsAccumulator = collectDiagnostics ? CatalogRegularFileEligibilityBatchDiagnosticsAccumulator() : nil
		diagnosticsAccumulator?.diagnostics.rawInputCount = preparedRelativePaths.count
		diagnosticsAccumulator?.diagnostics.preparedRelativePathFastPathAttemptCount = 1
		diagnosticsAccumulator?.diagnostics.preparedRelativePathFastPathInputCount = preparedRelativePaths.count

		func fallbackToRawBatch() async -> (results: [String: CatalogRegularFileEligibility], diagnostics: CatalogRegularFileEligibilityBatchDiagnostics?) {
			let fallback = await catalogRegularFileEligibilityBatchShared(
				relativePaths: preparedRelativePaths,
				collectDiagnostics: collectDiagnostics
			)
			guard collectDiagnostics else { return (fallback.results, nil) }
			var diagnostics = fallback.diagnostics ?? CatalogRegularFileEligibilityBatchDiagnostics()
			diagnostics.preparedRelativePathFastPathAttemptCount += 1
			diagnostics.preparedRelativePathFastPathFallbackCount += 1
			diagnostics.preparedRelativePathFastPathInputCount += preparedRelativePaths.count
			return (fallback.results, diagnostics)
		}

		let groupStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
		var groupedPaths: [String: [(relativePath: String, leafName: String)]] = [:]
		groupedPaths.reserveCapacity(min(preparedRelativePaths.count, 256))
		var seenRelativePaths: Set<String> = []
		seenRelativePaths.reserveCapacity(preparedRelativePaths.count)
		var lastParent: String?
		var maxParentGroupSize = 0

		for relativePath in preparedRelativePaths {
			guard catalogPreparedRelativePathIsSafe(relativePath) else {
				return await fallbackToRawBatch()
			}
			guard seenRelativePaths.insert(relativePath).inserted else { continue }
			diagnosticsAccumulator?.diagnostics.uniqueStandardizedPathCount += 1
			diagnosticsAccumulator?.diagnostics.preparedRelativePathFastPathGroupedEntryCount += 1

			let parent: String
			let leafName: String
			if let slashIndex = relativePath.lastIndex(of: "/") {
				leafName = String(relativePath[relativePath.index(after: slashIndex)...])
				let parentSlice = relativePath[..<slashIndex]
				if let reusableParent = lastParent, reusableParent == parentSlice {
					parent = reusableParent
					diagnosticsAccumulator?.diagnostics.preparedRelativePathFastPathParentReuseHitCount += 1
				} else {
					let candidateParent = String(parentSlice)
					if groupedPaths[candidateParent] == nil {
						diagnosticsAccumulator?.diagnostics.preparedRelativePathFastPathParentReuseMissCount += 1
					} else {
						diagnosticsAccumulator?.diagnostics.preparedRelativePathFastPathParentReuseHitCount += 1
					}
					parent = candidateParent
					lastParent = candidateParent
				}
			} else {
				parent = ""
				leafName = relativePath
				if groupedPaths[parent] == nil {
					diagnosticsAccumulator?.diagnostics.preparedRelativePathFastPathParentReuseMissCount += 1
				} else {
					diagnosticsAccumulator?.diagnostics.preparedRelativePathFastPathParentReuseHitCount += 1
				}
				lastParent = parent
			}

			groupedPaths[parent, default: []].append((relativePath: relativePath, leafName: leafName))
			maxParentGroupSize = max(maxParentGroupSize, groupedPaths[parent]?.count ?? 0)
		}

		if let groupStart {
			diagnosticsAccumulator?.diagnostics.standardizeAndGroupDurationMS += (CFAbsoluteTimeGetCurrent() - groupStart) * 1_000
		}
		diagnosticsAccumulator?.diagnostics.preparedRelativePathFastPathUsedCount = 1
		diagnosticsAccumulator?.diagnostics.parentGroupCount = groupedPaths.count
		diagnosticsAccumulator?.diagnostics.maxParentGroupSize = maxParentGroupSize

		var results: [String: CatalogRegularFileEligibility] = [:]
		results.reserveCapacity(seenRelativePaths.count)
		let parentProcessingStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
		for (parent, paths) in groupedPaths {
			let fastResults = await catalogRegularFileEligibilityBatchForParent(
				parent,
				paths: paths,
				diagnosticsAccumulator: diagnosticsAccumulator
			)
			for (relativePath, eligibility) in fastResults {
				results[relativePath] = eligibility
			}
		}
		if let parentProcessingStart {
			diagnosticsAccumulator?.diagnostics.parentProcessingDurationMS += (CFAbsoluteTimeGetCurrent() - parentProcessingStart) * 1_000
		}
		diagnosticsAccumulator?.diagnostics.resultCount = results.count

		return (results, diagnosticsAccumulator?.diagnostics)
	}

	private func catalogRegularFileEligibilityBatchShared(
		relativePaths rawRelativePaths: [String],
		collectDiagnostics: Bool
	) async -> (results: [String: CatalogRegularFileEligibility], diagnostics: CatalogRegularFileEligibilityBatchDiagnostics?) {
		let diagnosticsAccumulator = collectDiagnostics ? CatalogRegularFileEligibilityBatchDiagnosticsAccumulator() : nil
		diagnosticsAccumulator?.diagnostics.rawInputCount = rawRelativePaths.count
		var results: [String: CatalogRegularFileEligibility] = [:]
		results.reserveCapacity(rawRelativePaths.count)

		func setResult(_ eligibility: CatalogRegularFileEligibility, for relativePath: String) {
			results[relativePath] = eligibility
			diagnosticsAccumulator?.recordResult(eligibility)
		}

		// `nonisolated(nonsending)`: a bare nested `async` function is inferred
		// `@concurrent` under Swift 6, which would hop this helper onto the
		// global executor and force the actor-confined `diagnosticsAccumulator`
		// across an isolation boundary. It has always been meant to run on the
		// caller's executor (this actor) — it only awaits another isolated
		// method and mutates actor-confined bookkeeping.
		nonisolated(nonsending) func fallbackEligibility(
			relativePath: String,
			reason: CatalogEligibilityFallbackReason
		) async -> CatalogRegularFileEligibility {
			guard let diagnosticsAccumulator else {
				return await catalogRegularFileEligibility(relativePath: relativePath)
			}
			let start = CFAbsoluteTimeGetCurrent()
			let result = await catalogRegularFileEligibility(relativePath: relativePath)
			diagnosticsAccumulator.recordFallback(
				reason: reason,
				durationMS: (CFAbsoluteTimeGetCurrent() - start) * 1_000,
				result: result
			)
			return result
		}

		let standardizeStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
		let rootPrefix = standardizedRootPath.hasSuffix("/") ? standardizedRootPath : standardizedRootPath + "/"
		var groupedPaths: [String: [(relativePath: String, leafName: String)]] = [:]
		groupedPaths.reserveCapacity(min(rawRelativePaths.count, 256))

		for rawRelativePath in rawRelativePaths {
			let relativePath = standardizedCatalogRelativePath(rawRelativePath)
			guard results[relativePath] == nil else { continue }
			diagnosticsAccumulator?.diagnostics.uniqueStandardizedPathCount += 1

			guard !relativePath.isEmpty, !relativePath.hasPrefix("../"), relativePath != ".." else {
				setResult(.ineligible(.invalidRelativePath), for: relativePath)
				continue
			}

			let absolutePath = getFullPath(forRelativePath: relativePath)
			let standardizedAbsolutePath = (absolutePath as NSString).standardizingPath
			guard standardizedAbsolutePath.hasPrefix(rootPrefix) else {
				setResult(.ineligible(.outsideRoot), for: relativePath)
				continue
			}

			let parent = parentDirectory(of: relativePath)
			let leafName = (relativePath as NSString).lastPathComponent
			guard !leafName.isEmpty, leafName != ".", leafName != ".." else {
				let fallback = await fallbackEligibility(relativePath: relativePath, reason: .invalidLeafName)
				if diagnosticsAccumulator == nil { setResult(fallback, for: relativePath) } else { results[relativePath] = fallback }
				continue
			}
			groupedPaths[parent, default: []].append((relativePath: relativePath, leafName: leafName))
		}
		if let standardizeStart {
			diagnosticsAccumulator?.diagnostics.standardizeAndGroupDurationMS += (CFAbsoluteTimeGetCurrent() - standardizeStart) * 1_000
		}
		diagnosticsAccumulator?.diagnostics.parentGroupCount = groupedPaths.count
		diagnosticsAccumulator?.diagnostics.maxParentGroupSize = groupedPaths.values.map(\.count).max() ?? 0

		let parentProcessingStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
		for (parent, paths) in groupedPaths {
			let fastResults = await catalogRegularFileEligibilityBatchForParent(
				parent,
				paths: paths,
				diagnosticsAccumulator: diagnosticsAccumulator
			)
			for (relativePath, eligibility) in fastResults {
				results[relativePath] = eligibility
			}
		}
		if let parentProcessingStart {
			diagnosticsAccumulator?.diagnostics.parentProcessingDurationMS += (CFAbsoluteTimeGetCurrent() - parentProcessingStart) * 1_000
		}
		diagnosticsAccumulator?.diagnostics.resultCount = results.count

		return (results, diagnosticsAccumulator?.diagnostics)
	}

	private func catalogRegularFileEligibilityBatchForParent(
		_ parent: String,
		paths: [(relativePath: String, leafName: String)],
		diagnosticsAccumulator: CatalogRegularFileEligibilityBatchDiagnosticsAccumulator?
	) async -> [String: CatalogRegularFileEligibility] {
		var results: [String: CatalogRegularFileEligibility] = [:]
		results.reserveCapacity(paths.count)

		func setResult(_ eligibility: CatalogRegularFileEligibility, for relativePath: String) {
			results[relativePath] = eligibility
			diagnosticsAccumulator?.recordResult(eligibility)
		}

		func fallbackEligibility(
			_ path: (relativePath: String, leafName: String),
			reason: CatalogEligibilityFallbackReason
		) async -> CatalogRegularFileEligibility {
			guard let diagnosticsAccumulator else {
				return await catalogRegularFileEligibility(relativePath: path.relativePath)
			}
			let start = CFAbsoluteTimeGetCurrent()
			let result = await catalogRegularFileEligibility(relativePath: path.relativePath)
			diagnosticsAccumulator.recordFallback(
				reason: reason,
				durationMS: (CFAbsoluteTimeGetCurrent() - start) * 1_000,
				result: result
			)
			return result
		}

		func fallbackAll(reason: CatalogEligibilityFallbackReason) async -> [String: CatalogRegularFileEligibility] {
			var fallback: [String: CatalogRegularFileEligibility] = [:]
			fallback.reserveCapacity(paths.count)
			for path in paths {
				fallback[path.relativePath] = await fallbackEligibility(path, reason: reason)
			}
			return fallback
		}

		if skipSymlinks, !parent.isEmpty, pathContainsSymlinkComponent(relativePath: parent) {
			return await fallbackAll(reason: .parentSymlinkComponent)
		}

		let parentAbsolutePath = getFullPath(forRelativePath: parent)
		let standardizedParentAbsolutePath = (parentAbsolutePath as NSString).standardizingPath
		let scan: DirectoryScanResult
		do {
			let scanStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
			scan = try Self.listDirectoryWithIgnoreDetection(standardizedParentAbsolutePath, fm: self.fm)
			if let scanStart {
				diagnosticsAccumulator?.diagnostics.directoryScanDurationMS += (CFAbsoluteTimeGetCurrent() - scanStart) * 1_000
			}
			diagnosticsAccumulator?.diagnostics.directoryScanGroupCount += 1
			diagnosticsAccumulator?.diagnostics.directoryEntryCount += scan.entries.count
		} catch {
			diagnosticsAccumulator?.diagnostics.directoryScanFailureGroupCount += 1
			return await fallbackAll(reason: .directoryScanFailure)
		}

		let entriesStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
		var entriesByName: [String: DirEntry] = [:]
		entriesByName.reserveCapacity(scan.entries.count)
		for entry in scan.entries {
			entriesByName[entry.name] = entry
		}
		if let entriesStart {
			diagnosticsAccumulator?.diagnostics.entriesMapBuildDurationMS += (CFAbsoluteTimeGetCurrent() - entriesStart) * 1_000
		}

		let canonicalStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
		let canonicalParentPath = URL(fileURLWithPath: standardizedParentAbsolutePath).resolvingSymlinksInPath().path
		let canonicalPrefix = canonicalRootPath.hasSuffix("/") ? canonicalRootPath : canonicalRootPath + "/"
		let parentCanonicalInsideRoot = parent.isEmpty
			? canonicalParentPath == canonicalRootPath
			: (canonicalParentPath == canonicalRootPath || canonicalParentPath.hasPrefix(canonicalPrefix))
		if let canonicalStart {
			diagnosticsAccumulator?.diagnostics.canonicalParentResolveDurationMS += (CFAbsoluteTimeGetCurrent() - canonicalStart) * 1_000
		}

		let preparedIgnoreRules: [String: IgnoreRules]?
		do {
			if let diagnosticsAccumulator, enableHierarchicalIgnores {
				var directories = [""]
				var current = ""
				for component in parent.split(separator: "/") {
					current = current.isEmpty ? String(component) : "\(current)/\(component)"
					directories.append(current)
				}
				for directory in directories {
					if perFolderIgnoreCache[directory] != nil {
						diagnosticsAccumulator.diagnostics.preparedIgnoreRulesCacheHitDirectoryCount += 1
					} else {
						diagnosticsAccumulator.diagnostics.preparedIgnoreRulesCacheMissDirectoryCount += 1
					}
				}
			}
			let preparedStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
			preparedIgnoreRules = try await preparedCatalogIgnoreRules(forParent: parent, using: scan)
			if let preparedStart {
				diagnosticsAccumulator?.diagnostics.preparedIgnoreRulesDurationMS += (CFAbsoluteTimeGetCurrent() - preparedStart) * 1_000
			}
			diagnosticsAccumulator?.diagnostics.preparedIgnoreRulesGroupCount += enableHierarchicalIgnores ? 1 : 0
		} catch {
			diagnosticsAccumulator?.diagnostics.preparedIgnoreRulesFailureGroupCount += 1
			return await fallbackAll(reason: .preparedIgnoreRulesFailure)
		}

		let hierarchicalParentState: CatalogPreparedIgnoreParentState?
		if enableHierarchicalIgnores, let preparedIgnoreRules {
			let hierarchicalParentStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
			hierarchicalParentState = catalogPreparedIgnoreParentState(
				parent: parent,
				rulesByDirectory: preparedIgnoreRules
			)
			if let hierarchicalParentStart {
				diagnosticsAccumulator?.diagnostics.hierarchicalIgnoreDurationMS += (CFAbsoluteTimeGetCurrent() - hierarchicalParentStart) * 1_000
			}
		} else {
			hierarchicalParentState = nil
		}
		let prefixParentStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
		let prefixParentState = catalogPrefixIgnoreParentState(parent: parent)
		diagnosticsAccumulator?.recordPrefixParentRuleShape(ignoreRules: ignoreRules)
		if let prefixParentStart {
			diagnosticsAccumulator?.diagnostics.prefixIgnoreDurationMS += (CFAbsoluteTimeGetCurrent() - prefixParentStart) * 1_000
		}
		let hierarchicalLeafCheckIsNoOp = hierarchicalParentState?.directFileLeafCheckIsNoOp == true
		let prefixLeafCheckIsNoOp = prefixParentState.directFileLeafCheckIsNoOp
		let prefixDirectLeafFastPathBlockedByNegation = ignoreRules.hasAnyNegativePatterns()
			|| hierarchicalParentState?.leafRules.hasAnyNegativePatterns() == true
		let prefixDirectLeafMatcher: PositiveOnlyDirectFileLeafMatcher?
		if !prefixParentState.parentIsIgnored, !prefixLeafCheckIsNoOp {
			if prefixDirectLeafFastPathBlockedByNegation {
				prefixDirectLeafMatcher = nil
				diagnosticsAccumulator?.recordPrefixDirectLeafFastPathUnsupportedParentGroup()
			} else {
				let directLeafBuildStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
				prefixDirectLeafMatcher = ignoreRules.makePositiveOnlyDirectFileLeafMatcher(
					parentComponents: prefixParentState.parentComponents
				)
				if let directLeafBuildStart {
					diagnosticsAccumulator?.recordPrefixDirectLeafFastPathBuildDuration(
						(CFAbsoluteTimeGetCurrent() - directLeafBuildStart) * 1_000
					)
				}
				if let prefixDirectLeafMatcher {
					diagnosticsAccumulator?.recordPrefixDirectLeafFastPathParentGroup(
						candidatePatternCount: prefixDirectLeafMatcher.candidatePatternCount
					)
				} else {
					diagnosticsAccumulator?.recordPrefixDirectLeafFastPathUnsupportedParentGroup()
				}
			}
		} else {
			prefixDirectLeafMatcher = nil
		}
		if hierarchicalLeafCheckIsNoOp {
			diagnosticsAccumulator?.diagnostics.hierarchicalIgnoreNoOpParentGroupCount += 1
		}
		if prefixLeafCheckIsNoOp {
			diagnosticsAccumulator?.diagnostics.prefixIgnoreNoOpParentGroupCount += 1
		}

		for path in paths {
			guard let entry = entriesByName[path.leafName] else {
				let fallback = await fallbackEligibility(path, reason: .missingEntry)
				if diagnosticsAccumulator == nil { setResult(fallback, for: path.relativePath) } else { results[path.relativePath] = fallback }
				continue
			}

			if entry.isDir {
				setResult(.ineligible(.missingOrDirectory), for: path.relativePath)
				continue
			}
			if entry.isSym {
				setResult(.ineligible(.symbolicLink), for: path.relativePath)
				continue
			}
			guard let isRegularFile = entry.isRegularFile else {
				let fallback = await fallbackEligibility(path, reason: .unknownEntryRegularFileMetadata)
				if diagnosticsAccumulator == nil { setResult(fallback, for: path.relativePath) } else { results[path.relativePath] = fallback }
				continue
			}
			guard isRegularFile else {
				setResult(.ineligible(.nonRegularFile), for: path.relativePath)
				continue
			}
			guard parentCanonicalInsideRoot else {
				setResult(.ineligible(.outsideCanonicalRoot), for: path.relativePath)
				continue
			}

			let isIgnored: Bool
			if enableHierarchicalIgnores {
				guard let preparedIgnoreRules else {
					let fallback = await fallbackEligibility(path, reason: .preparedRuleMiss)
					if diagnosticsAccumulator == nil { setResult(fallback, for: path.relativePath) } else { results[path.relativePath] = fallback }
					continue
				}
				let preparedIgnored: Bool
				if hierarchicalLeafCheckIsNoOp {
					diagnosticsAccumulator?.diagnostics.hierarchicalIgnoreSkippedLeafCheckCount += 1
					preparedIgnored = false
				} else {
					let hierarchicalStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
					if let hierarchicalParentState {
						preparedIgnored = catalogPathIsIgnoredUsingPreparedParentState(
							leafName: path.leafName,
							parentState: hierarchicalParentState
						)
					} else {
					guard let fullPathPreparedIgnored = catalogPathIsIgnoredUsingPreparedRules(
						relativePath: path.relativePath,
						isDirectory: false,
						rulesByDirectory: preparedIgnoreRules
					) else {
						if let hierarchicalStart {
							diagnosticsAccumulator?.diagnostics.hierarchicalIgnoreDurationMS += (CFAbsoluteTimeGetCurrent() - hierarchicalStart) * 1_000
							diagnosticsAccumulator?.diagnostics.hierarchicalIgnoreCheckCount += 1
						}
						let fallback = await fallbackEligibility(path, reason: .preparedRuleMiss)
						if diagnosticsAccumulator == nil { setResult(fallback, for: path.relativePath) } else { results[path.relativePath] = fallback }
						continue
					}
						preparedIgnored = fullPathPreparedIgnored
					}
					if let hierarchicalStart {
						diagnosticsAccumulator?.diagnostics.hierarchicalIgnoreDurationMS += (CFAbsoluteTimeGetCurrent() - hierarchicalStart) * 1_000
						diagnosticsAccumulator?.diagnostics.hierarchicalIgnoreCheckCount += 1
					}
				}
				let prefixIgnored: Bool
				if prefixParentState.parentIsIgnored {
					prefixIgnored = true
				} else if let prefixDirectLeafMatcher {
					let prefixStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
					prefixIgnored = prefixDirectLeafMatcher.ignores(leafName: path.leafName)
					if let prefixStart {
						diagnosticsAccumulator?.recordPrefixDirectLeafFastPathLeafCheck(
							ignored: prefixIgnored,
							durationMS: (CFAbsoluteTimeGetCurrent() - prefixStart) * 1_000
						)
					}
				} else if prefixLeafCheckIsNoOp {
					diagnosticsAccumulator?.diagnostics.prefixIgnoreSkippedLeafCheckCount += 1
					prefixIgnored = false
				} else {
					let prefixStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
					prefixIgnored = isIgnoredPrefixCheck(
						leafName: path.leafName,
						usingPreparedParentState: prefixParentState
					)
					if let prefixStart {
						diagnosticsAccumulator?.diagnostics.prefixIgnoreDurationMS += (CFAbsoluteTimeGetCurrent() - prefixStart) * 1_000
						diagnosticsAccumulator?.diagnostics.prefixIgnoreCheckCount += 1
					}
				}
				isIgnored = preparedIgnored || prefixIgnored
			} else if prefixParentState.parentIsIgnored {
				isIgnored = true
			} else if let prefixDirectLeafMatcher {
				let prefixStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
				isIgnored = prefixDirectLeafMatcher.ignores(leafName: path.leafName)
				if let prefixStart {
					diagnosticsAccumulator?.recordPrefixDirectLeafFastPathLeafCheck(
						ignored: isIgnored,
						durationMS: (CFAbsoluteTimeGetCurrent() - prefixStart) * 1_000
					)
				}
			} else if prefixLeafCheckIsNoOp {
				diagnosticsAccumulator?.diagnostics.prefixIgnoreSkippedLeafCheckCount += 1
				isIgnored = false
			} else {
				let prefixStart = diagnosticsAccumulator == nil ? nil : CFAbsoluteTimeGetCurrent()
				isIgnored = isIgnoredPrefixCheck(
					leafName: path.leafName,
					usingPreparedParentState: prefixParentState
				)
				if let prefixStart {
					diagnosticsAccumulator?.diagnostics.prefixIgnoreDurationMS += (CFAbsoluteTimeGetCurrent() - prefixStart) * 1_000
					diagnosticsAccumulator?.diagnostics.prefixIgnoreCheckCount += 1
				}
			}
			setResult(isIgnored ? .ineligible(.ignored) : .eligible, for: path.relativePath)
		}

		return results
	}
	#else
	public func catalogRegularFileEligibilityBatch(relativePaths rawRelativePaths: [String]) async -> [String: CatalogRegularFileEligibility] {
		var results: [String: CatalogRegularFileEligibility] = [:]
		results.reserveCapacity(rawRelativePaths.count)

		let rootPrefix = standardizedRootPath.hasSuffix("/") ? standardizedRootPath : standardizedRootPath + "/"
		var groupedPaths: [String: [(relativePath: String, leafName: String)]] = [:]
		groupedPaths.reserveCapacity(min(rawRelativePaths.count, 256))

		for rawRelativePath in rawRelativePaths {
			let relativePath = standardizedCatalogRelativePath(rawRelativePath)
			guard results[relativePath] == nil else { continue }

			guard !relativePath.isEmpty, !relativePath.hasPrefix("../"), relativePath != ".." else {
				results[relativePath] = .ineligible(.invalidRelativePath)
				continue
			}

			let absolutePath = getFullPath(forRelativePath: relativePath)
			let standardizedAbsolutePath = (absolutePath as NSString).standardizingPath
			guard standardizedAbsolutePath.hasPrefix(rootPrefix) else {
				results[relativePath] = .ineligible(.outsideRoot)
				continue
			}

			let parent = parentDirectory(of: relativePath)
			let leafName = (relativePath as NSString).lastPathComponent
			guard !leafName.isEmpty, leafName != ".", leafName != ".." else {
				results[relativePath] = await catalogRegularFileEligibility(relativePath: relativePath)
				continue
			}
			groupedPaths[parent, default: []].append((relativePath: relativePath, leafName: leafName))
		}

		for (parent, paths) in groupedPaths {
			let fastResults = await catalogRegularFileEligibilityBatchForParent(parent, paths: paths)
			for (relativePath, eligibility) in fastResults {
				results[relativePath] = eligibility
			}
		}

		return results
	}

	public func catalogRegularFileEligibilityBatchForPreparedRelativePaths(
		_ preparedRelativePaths: [String]
	) async -> [String: CatalogRegularFileEligibility] {
		var groupedPaths: [String: [(relativePath: String, leafName: String)]] = [:]
		groupedPaths.reserveCapacity(min(preparedRelativePaths.count, 256))
		var seenRelativePaths: Set<String> = []
		seenRelativePaths.reserveCapacity(preparedRelativePaths.count)
		var lastParent: String?

		for relativePath in preparedRelativePaths {
			guard catalogPreparedRelativePathIsSafe(relativePath) else {
				return await catalogRegularFileEligibilityBatch(relativePaths: preparedRelativePaths)
			}
			guard seenRelativePaths.insert(relativePath).inserted else { continue }

			let parent: String
			let leafName: String
			if let slashIndex = relativePath.lastIndex(of: "/") {
				leafName = String(relativePath[relativePath.index(after: slashIndex)...])
				let parentSlice = relativePath[..<slashIndex]
				if let reusableParent = lastParent, reusableParent == parentSlice {
					parent = reusableParent
				} else {
					let candidateParent = String(parentSlice)
					parent = candidateParent
					lastParent = candidateParent
				}
			} else {
				parent = ""
				leafName = relativePath
				lastParent = parent
			}
			groupedPaths[parent, default: []].append((relativePath: relativePath, leafName: leafName))
		}

		var results: [String: CatalogRegularFileEligibility] = [:]
		results.reserveCapacity(seenRelativePaths.count)
		for (parent, paths) in groupedPaths {
			let fastResults = await catalogRegularFileEligibilityBatchForParent(parent, paths: paths)
			for (relativePath, eligibility) in fastResults {
				results[relativePath] = eligibility
			}
		}
		return results
	}

	private func catalogRegularFileEligibilityBatchForParent(
		_ parent: String,
		paths: [(relativePath: String, leafName: String)]
	) async -> [String: CatalogRegularFileEligibility] {
		var results: [String: CatalogRegularFileEligibility] = [:]
		results.reserveCapacity(paths.count)

		func fallbackAll() async -> [String: CatalogRegularFileEligibility] {
			var fallback: [String: CatalogRegularFileEligibility] = [:]
			fallback.reserveCapacity(paths.count)
			for path in paths {
				fallback[path.relativePath] = await catalogRegularFileEligibility(relativePath: path.relativePath)
			}
			return fallback
		}

		if skipSymlinks, !parent.isEmpty, pathContainsSymlinkComponent(relativePath: parent) {
			return await fallbackAll()
		}

		let parentAbsolutePath = getFullPath(forRelativePath: parent)
		let standardizedParentAbsolutePath = (parentAbsolutePath as NSString).standardizingPath
		let scan: DirectoryScanResult
		do {
			scan = try Self.listDirectoryWithIgnoreDetection(standardizedParentAbsolutePath)
		} catch {
			return await fallbackAll()
		}

		var entriesByName: [String: DirEntry] = [:]
		entriesByName.reserveCapacity(scan.entries.count)
		for entry in scan.entries {
			entriesByName[entry.name] = entry
		}

		let canonicalParentPath = URL(fileURLWithPath: standardizedParentAbsolutePath).resolvingSymlinksInPath().path
		let canonicalPrefix = canonicalRootPath.hasSuffix("/") ? canonicalRootPath : canonicalRootPath + "/"
		let parentCanonicalInsideRoot = parent.isEmpty
			? canonicalParentPath == canonicalRootPath
			: (canonicalParentPath == canonicalRootPath || canonicalParentPath.hasPrefix(canonicalPrefix))

		let preparedIgnoreRules: [String: IgnoreRules]?
		do {
			preparedIgnoreRules = try await preparedCatalogIgnoreRules(forParent: parent, using: scan)
		} catch {
			return await fallbackAll()
		}

		let hierarchicalParentState: CatalogPreparedIgnoreParentState?
		if enableHierarchicalIgnores, let preparedIgnoreRules {
			hierarchicalParentState = catalogPreparedIgnoreParentState(
				parent: parent,
				rulesByDirectory: preparedIgnoreRules
			)
		} else {
			hierarchicalParentState = nil
		}
		let prefixParentState = catalogPrefixIgnoreParentState(parent: parent)
		let hierarchicalLeafCheckIsNoOp = hierarchicalParentState?.directFileLeafCheckIsNoOp == true
		let prefixLeafCheckIsNoOp = prefixParentState.directFileLeafCheckIsNoOp
		let prefixDirectLeafFastPathBlockedByNegation = ignoreRules.hasAnyNegativePatterns()
			|| hierarchicalParentState?.leafRules.hasAnyNegativePatterns() == true
		let prefixDirectLeafMatcher = !prefixParentState.parentIsIgnored
			&& !prefixLeafCheckIsNoOp
			&& !prefixDirectLeafFastPathBlockedByNegation
			? ignoreRules.makePositiveOnlyDirectFileLeafMatcher(parentComponents: prefixParentState.parentComponents)
			: nil

		for path in paths {
			guard let entry = entriesByName[path.leafName] else {
				results[path.relativePath] = await catalogRegularFileEligibility(relativePath: path.relativePath)
				continue
			}

			if entry.isDir {
				results[path.relativePath] = .ineligible(.missingOrDirectory)
				continue
			}
			if entry.isSym {
				results[path.relativePath] = .ineligible(.symbolicLink)
				continue
			}
			guard let isRegularFile = entry.isRegularFile else {
				results[path.relativePath] = await catalogRegularFileEligibility(relativePath: path.relativePath)
				continue
			}
			guard isRegularFile else {
				results[path.relativePath] = .ineligible(.nonRegularFile)
				continue
			}
			guard parentCanonicalInsideRoot else {
				results[path.relativePath] = .ineligible(.outsideCanonicalRoot)
				continue
			}

			let isIgnored: Bool
			if enableHierarchicalIgnores {
				guard let preparedIgnoreRules else {
					results[path.relativePath] = await catalogRegularFileEligibility(relativePath: path.relativePath)
					continue
				}
				let preparedIgnored: Bool
				if hierarchicalLeafCheckIsNoOp {
					preparedIgnored = false
				} else if let hierarchicalParentState {
					preparedIgnored = catalogPathIsIgnoredUsingPreparedParentState(
						leafName: path.leafName,
						parentState: hierarchicalParentState
					)
				} else {
					guard let fullPathPreparedIgnored = catalogPathIsIgnoredUsingPreparedRules(
						relativePath: path.relativePath,
						isDirectory: false,
						rulesByDirectory: preparedIgnoreRules
					) else {
						results[path.relativePath] = await catalogRegularFileEligibility(relativePath: path.relativePath)
						continue
					}
					preparedIgnored = fullPathPreparedIgnored
				}
				let prefixIgnored: Bool
				if prefixParentState.parentIsIgnored {
					prefixIgnored = true
				} else if let prefixDirectLeafMatcher {
					prefixIgnored = prefixDirectLeafMatcher.ignores(leafName: path.leafName)
				} else if prefixLeafCheckIsNoOp {
					prefixIgnored = false
				} else {
					prefixIgnored = isIgnoredPrefixCheck(
						leafName: path.leafName,
						usingPreparedParentState: prefixParentState
					)
				}
				isIgnored = preparedIgnored || prefixIgnored
			} else if prefixParentState.parentIsIgnored {
				isIgnored = true
			} else if let prefixDirectLeafMatcher {
				isIgnored = prefixDirectLeafMatcher.ignores(leafName: path.leafName)
			} else if prefixLeafCheckIsNoOp {
				isIgnored = false
			} else {
				isIgnored = isIgnoredPrefixCheck(
					leafName: path.leafName,
					usingPreparedParentState: prefixParentState
				)
			}
			results[path.relativePath] = isIgnored ? .ineligible(.ignored) : .eligible
		}

		return results
	}
	#endif

	@inline(__always)
	private func catalogPreparedRelativePathIsSafe(_ relativePath: String) -> Bool {
		guard !relativePath.isEmpty else { return false }

		var componentLength = 0
		var componentDotCount = 0
		var sawByte = false
		for byte in relativePath.utf8 {
			sawByte = true
			if byte == 0 { return false }
			if byte == 47 {
				if componentLength == 0 { return false }
				if componentDotCount == componentLength, componentDotCount == 1 || componentDotCount == 2 {
					return false
				}
				componentLength = 0
				componentDotCount = 0
			} else {
				componentLength += 1
				if byte == 46 {
					componentDotCount += 1
				}
			}
		}

		guard sawByte, componentLength > 0 else { return false }
		if componentDotCount == componentLength, componentDotCount == 1 || componentDotCount == 2 {
			return false
		}
		return true
	}

	private func preparedCatalogIgnoreRules(
		forParent parent: String,
		using scan: DirectoryScanResult
	) async throws -> [String: IgnoreRules]? {
		guard enableHierarchicalIgnores else { return nil }
		_ = try await ensureRulesChain(for: parent, using: scan)

		var rulesByDirectory: [String: IgnoreRules] = [:]
		rulesByDirectory.reserveCapacity(parent.split(separator: "/").count + 1)
		guard let rootRules = perFolderIgnoreCache[""] else { return nil }
		rulesByDirectory[""] = rootRules

		var current = ""
		for component in parent.split(separator: "/") {
			current = current.isEmpty ? String(component) : "\(current)/\(component)"
			guard let rules = perFolderIgnoreCache[current] else { return nil }
			rulesByDirectory[current] = rules
		}
		return rulesByDirectory
	}

	private struct CatalogPreparedIgnoreParentState {
		let parentComponents: [Substring]
		let lastOutcome: CompiledIgnoreRules.MatchOutcome?
		let lockedRules: IgnoreRules?
		let leafRules: IgnoreRules
		let directFileLeafCheckIsNoOp: Bool
	}

	private struct CatalogPrefixIgnoreParentState {
		let parentComponents: [Substring]
		let parentIsIgnored: Bool
		let directFileLeafCheckIsNoOp: Bool
	}

	private func catalogPreparedIgnoreParentState(
		parent: String,
		rulesByDirectory: [String: IgnoreRules]
	) -> CatalogPreparedIgnoreParentState? {
		let parentComponents = parent.split(separator: "/")
		guard let rootRules = rulesByDirectory[""] else { return nil }
		guard !parentComponents.isEmpty else {
			return CatalogPreparedIgnoreParentState(
				parentComponents: [],
				lastOutcome: nil,
				lockedRules: nil,
				leafRules: rootRules,
				directFileLeafCheckIsNoOp: rootRules.activePatternCount == ignoreRules.activePatternCount
			)
		}

		var lastOutcome: CompiledIgnoreRules.MatchOutcome?
		var lockedRules: IgnoreRules?

		for index in parentComponents.indices {
			let parentPath = index == 0 ? "" : parentComponents[0..<index].joined(separator: "/")

			let rules: IgnoreRules
			if let locked = lockedRules {
				rules = locked
			} else if let prepared = rulesByDirectory[parentPath] {
				rules = prepared
			} else {
				return nil
			}

			let pathComponents = Array(parentComponents[0...index])
			if let outcome = rules.matchOutcome(relativePathComponents: pathComponents, isDirectory: true) {
				lastOutcome = outcome
				switch outcome {
				case .ignore:
					if lockedRules == nil {
						lockedRules = rules
					}
				case .allow:
					lockedRules = nil
				case .noMatch:
					break
				}
			}
		}

		let leafRules: IgnoreRules
		if let locked = lockedRules {
			leafRules = locked
		} else if let prepared = rulesByDirectory[parent] {
			leafRules = prepared
		} else {
			return nil
		}

		return CatalogPreparedIgnoreParentState(
			parentComponents: parentComponents,
			lastOutcome: lastOutcome,
			lockedRules: lockedRules,
			leafRules: leafRules,
			directFileLeafCheckIsNoOp: lastOutcome == nil
				&& lockedRules == nil
				&& leafRules.activePatternCount == rootRules.activePatternCount
		)
	}

	private func catalogPathIsIgnoredUsingPreparedParentState(
		leafName: String,
		parentState: CatalogPreparedIgnoreParentState
	) -> Bool {
		var pathComponents = parentState.parentComponents
		pathComponents.append(leafName[...])

		var lastOutcome = parentState.lastOutcome
		var lockedRules = parentState.lockedRules
		let rules = lockedRules ?? parentState.leafRules
		if let outcome = rules.matchOutcome(relativePathComponents: pathComponents, isDirectory: false) {
			lastOutcome = outcome
			switch outcome {
			case .ignore:
				if lockedRules == nil {
					lockedRules = rules
				}
			case .allow:
				lockedRules = nil
			case .noMatch:
				break
			}
		}

		return lastOutcome == .ignore
	}

	private func catalogPrefixIgnoreParentState(parent: String) -> CatalogPrefixIgnoreParentState {
		let parentComponents = parent.split(separator: "/")
		var pathSoFar = ""

		for (index, component) in parentComponents.enumerated() {
			pathSoFar = index == 0 ? String(component) : "\(pathSoFar)/\(component)"
			let pathComponents = Array(parentComponents[0...index])
			let ignored = ignoreRules.isIgnored(relativePathComponents: pathComponents, isDirectory: true)
			if ignored {
				if ignoreRules.requiresTraversal(for: pathSoFar) {
					continue
				}
				return CatalogPrefixIgnoreParentState(
					parentComponents: parentComponents,
					parentIsIgnored: true,
					directFileLeafCheckIsNoOp: false
				)
			}
		}

		return CatalogPrefixIgnoreParentState(
			parentComponents: parentComponents,
			parentIsIgnored: false,
			directFileLeafCheckIsNoOp: ignoreRules.activePatternCount == 0
		)
	}

	private func isIgnoredPrefixCheck(
		leafName: String,
		usingPreparedParentState parentState: CatalogPrefixIgnoreParentState
	) -> Bool {
		if parentState.parentIsIgnored {
			return true
		}
		var pathComponents = parentState.parentComponents
		pathComponents.append(leafName[...])
		return ignoreRules.isIgnored(relativePathComponents: pathComponents, isDirectory: false)
	}

	private func catalogPathIsIgnoredUsingPreparedRules(
		relativePath: String,
		isDirectory finalIsDirectory: Bool,
		rulesByDirectory: [String: IgnoreRules]
	) -> Bool? {
		let components = relativePath.split(separator: "/").map(String.init)
		guard !components.isEmpty else { return false }

		var pathSoFar = ""
		var lastOutcome: CompiledIgnoreRules.MatchOutcome?
		var lockedRules: IgnoreRules?

		for (index, component) in components.enumerated() {
			let isLastComponent = index == components.count - 1
			let isDirectory = isLastComponent ? finalIsDirectory : true
			pathSoFar = index == 0 ? component : "\(pathSoFar)/\(component)"
			let parentPath = index == 0 ? "" : components[0..<index].joined(separator: "/")

			let rules: IgnoreRules
			if let locked = lockedRules {
				rules = locked
			} else if let prepared = rulesByDirectory[parentPath] {
				rules = prepared
			} else {
				return nil
			}

			let pathComponents = pathSoFar.split(separator: "/")
			if let outcome = rules.matchOutcome(relativePathComponents: pathComponents, isDirectory: isDirectory) {
				lastOutcome = outcome
				switch outcome {
				case .ignore:
					if lockedRules == nil {
						lockedRules = rules
					}
				case .allow:
					lockedRules = nil
				case .noMatch:
					break
				}
			}
		}

		return lastOutcome == .ignore
	}

	public func catalogRegularFileEligibility(relativePath rawRelativePath: String) async -> CatalogRegularFileEligibility {
		let relativePath = standardizedCatalogRelativePath(rawRelativePath)
		guard !relativePath.isEmpty, !relativePath.hasPrefix("../"), relativePath != ".." else {
			return .ineligible(.invalidRelativePath)
		}
		let absolutePath = getFullPath(forRelativePath: relativePath)
		let standardizedAbsolutePath = (absolutePath as NSString).standardizingPath
		let rootPrefix = standardizedRootPath.hasSuffix("/") ? standardizedRootPath : standardizedRootPath + "/"
		guard standardizedAbsolutePath.hasPrefix(rootPrefix) else { return .ineligible(.outsideRoot) }

		var isDirectory = ObjCBool(false)
		guard fm.fileExists(atPath: standardizedAbsolutePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
			return .ineligible(.missingOrDirectory)
		}
		let url = URL(fileURLWithPath: standardizedAbsolutePath)
		if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
			if values.isSymbolicLink == true { return .ineligible(.symbolicLink) }
			if values.isRegularFile == false { return .ineligible(.nonRegularFile) }
		}
		if skipSymlinks && pathContainsSymlinkComponent(relativePath: relativePath) {
			return .ineligible(.symlinkComponent)
		}

		let canonicalPath = url.resolvingSymlinksInPath().path
		let canonicalPrefix = canonicalRootPath.hasSuffix("/") ? canonicalRootPath : canonicalRootPath + "/"
		guard canonicalPath == canonicalRootPath || canonicalPath.hasPrefix(canonicalPrefix) else {
			return .ineligible(.outsideCanonicalRoot)
		}

		let isIgnored: Bool
		if enableHierarchicalIgnores {
			isIgnored = await isIgnoredHierarchical(relativePath: relativePath, isDirectory: false) || isIgnoredPrefixCheck(relativePath: relativePath)
		} else {
			isIgnored = isIgnoredPrefixCheck(relativePath: relativePath)
		}
		return isIgnored ? .ineligible(.ignored) : .eligible
	}

	private func pathContainsSymlinkComponent(relativePath: String) -> Bool {
		var current = rootURL
		for component in relativePath.split(separator: "/") {
			current.appendPathComponent(String(component))
			if ((try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) == true {
				return true
			}
		}
		return false
	}
	
	public func flushPendingEventsNow() async {
		// Cancel any scheduled coalescing delay task
		coalescingTask?.cancel()
		coalescingTask = nil

		// Snapshot and clear pending raw events
		let events = takePendingFSEventsForProcessing()

		// Process immediately and publish deltas (if any)
		if !events.isEmpty {
			_ = await handleBatchedEvents(events)
		}
	}

	#if DEBUG
	public func pendingRawEventCountForDiagnostics() -> Int {
		pendingFSEvents.count
	}

	public func lastPublishedDeltaCoalescingDiagnosticsForTesting() -> PublishedDeltaCoalescingDiagnostics? {
		lastPublishedDeltaCoalescingDiagnostics
	}

	public func lastEventTargetIgnoreFastPathDiagnosticsForTesting() -> EventTargetIgnoreFastPathDiagnostics? {
		lastEventTargetIgnoreFastPathDiagnostics
	}

	public func lastEventPathMappingFastPathDiagnosticsForTesting() -> EventPathMappingFastPathDiagnostics? {
		lastEventPathMappingFastPathDiagnostics
	}

	public func coalescedPublishableDeltasForTesting(_ deltas: [FileSystemDelta]) -> [FileSystemDelta] {
		coalescedPublishableDeltas(from: deltas)
	}
	#endif

	private func coalescedPublishableDeltas(from deltas: [FileSystemDelta]) -> [FileSystemDelta] {
		FileSystemDeltaPreparation.coalesce(
			deltas,
			inRoot: canonicalRootPath,
			preservingDescendantRemovals: true
		)
	}
	
	// MARK: - FSEvent Setup
	
	private func startFSEventStream() {
		guard fseventStreamRef == nil else { return }

		selfPointer = Unmanaged.passRetained(self).toOpaque()

		var streamContext = FSEventStreamContext(
			version: 0,
			info: selfPointer,
			retain: nil,
			release: nil,
			copyDescription: nil
		)

		let flags = FSEventStreamCreateFlags(
			kFSEventStreamCreateFlagUseCFTypes
			| kFSEventStreamCreateFlagFileEvents
			| kFSEventStreamCreateFlagNoDefer
		)

		fseventStreamRef = FSEventStreamCreate(
			kCFAllocatorDefault,
			Self.fseventCallback,
			&streamContext,
			[path] as CFArray,
			FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
			0,
			flags
		)

		guard let stream = fseventStreamRef else {
			// Release the retained self if creation failed to avoid leaks
			if let ptr = selfPointer {
				Unmanaged<FileSystemService>.fromOpaque(ptr).release()
				selfPointer = nil
			}
			print("Failed to create FSEventStream for \(path)")
			return
		}

		FSEventStreamSetDispatchQueue(stream, .main)
		if !FSEventStreamStart(stream) {
			// Clean up to avoid leaks
			FSEventStreamInvalidate(stream)
			FSEventStreamRelease(stream)
			fseventStreamRef = nil
			if let ptr = selfPointer {
				Unmanaged<FileSystemService>.fromOpaque(ptr).release()
				selfPointer = nil
			}
			print("Failed to start FSEventStream for \(path)")
			return
		}
		fileSystemDebugLog("FSEventStream started for path: \(path)")
	}
	
	private func stopFSEventStream() {
		if let stream = fseventStreamRef {
			FSEventStreamStop(stream)
			FSEventStreamFlushSync(stream)
			FSEventStreamInvalidate(stream)
			FSEventStreamRelease(stream)
			fseventStreamRef = nil
			
			if let ptr = selfPointer {
				Unmanaged<FileSystemService>.fromOpaque(ptr).release()
				selfPointer = nil
			}
			
			fileSystemDebugLog("FSEventStream stopped for path: \(path)")
		} else {
			fileSystemDebugLog("stream could not be stopped")
		}

		resetWatcherIngressState()
	}

	nonisolated private static func deepCopySwiftString(_ source: String) -> String {
		String(decoding: Array(source.utf8), as: UTF8.self)
	}

	nonisolated private static func deepCopyEventPath(_ source: CFString) -> String? {
		let length = CFStringGetLength(source)
		if length == 0 { return "" }

		let utf8Encoding = CFStringBuiltInEncodings.UTF8.rawValue
		if let directUTF8 = CFStringGetCStringPtr(source, utf8Encoding) {
			return String(cString: directUTF8)
		}
		let maxBufferSize = max(CFStringGetMaximumSizeForEncoding(length, utf8Encoding) + 1, 1)
		var utf8Buffer = [CChar](repeating: 0, count: maxBufferSize)
		let copiedUTF8 = utf8Buffer.withUnsafeMutableBufferPointer { buffer in
			CFStringGetCString(source, buffer.baseAddress, buffer.count, utf8Encoding)
		}
		if copiedUTF8 {
			return String(cString: utf8Buffer)
		}

		var utf16Buffer = [UniChar](repeating: 0, count: length)
		CFStringGetCharacters(
			source,
			CFRange(location: 0, length: length),
			&utf16Buffer
		)
		return String(utf16CodeUnits: utf16Buffer, count: utf16Buffer.count)
	}

	nonisolated private static func buildOwnedFSEventPayload(
		numEvents: Int,
		eventPaths: UnsafeMutableRawPointer,
		eventFlags: UnsafePointer<FSEventStreamEventFlags>,
		eventIds: UnsafePointer<FSEventStreamEventId>
	) -> FSEventCallbackPayload? {
		let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
		let safeCount = min(numEvents, CFArrayGetCount(cfArray))
		guard safeCount > 0 else { return nil }

		var entries: [FSEventCallbackEntry] = []
		entries.reserveCapacity(safeCount)

		for index in 0..<safeCount {
			guard let rawValue = CFArrayGetValueAtIndex(cfArray, index) else { continue }
			let cfObject = unsafeBitCast(rawValue, to: CFTypeRef.self)
			let copiedPath: String?
			if CFGetTypeID(cfObject) == CFStringGetTypeID() {
				let cfString = unsafeBitCast(rawValue, to: CFString.self)
				copiedPath = deepCopyEventPath(cfString)
			} else if let string = cfObject as? String {
				copiedPath = deepCopySwiftString(string)
			} else {
				#if DEBUG
				if enableDebugLogging {
					print("DEBUG: Dropping unexpected FSEvent path payload at index \(index): \(type(of: cfObject))")
				}
				#endif
				copiedPath = nil
			}

			guard let copiedPath else { continue }
			entries.append(
				FSEventCallbackEntry(
					path: copiedPath,
					flags: eventFlags[index],
					id: eventIds[index]
				)
			)
		}

		guard !entries.isEmpty else { return nil }
		return FSEventCallbackPayload(entries: entries)
	}
	
	/// The static callback that FSEvents uses to report changes. We hand off to Task to enter the actor context.
	private static let fseventCallback: FSEventStreamCallback = {
		(streamRef, context, numEvents, eventPaths, eventFlags, eventIds) in

		// Context must be valid
		guard let context = context else { return }
		let service = Unmanaged<FileSystemService>.fromOpaque(context).takeUnretainedValue()

		let count = Int(numEvents)
		guard count > 0 else { return }

		// Although these are non-optional in the API, guard against unexpected null pointers defensively
		if Int(bitPattern: eventPaths) == 0 { return }
		if Int(bitPattern: eventFlags) == 0 { return }
		if Int(bitPattern: eventIds) == 0 { return }

		guard let payload = buildOwnedFSEventPayload(
			numEvents: count,
			eventPaths: eventPaths,
			eventFlags: eventFlags,
			eventIds: eventIds
		) else { return }
		
		#if DEBUG
		if payload.count != count {
			print("DEBUG: FSEvents vector length mismatch. numEvents=\(count), payloadCount=\(payload.count)")
		}

		// Log raw FSEvents as they arrive
		if enableDebugLogging {
			print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
			print("🔔 RAW FSEVENTS CALLBACK: \(payload.count) events")
			for (index, entry) in payload.entries.enumerated() {
				print("  [\(index)] path: \(entry.path)")
				print("       flags: \(formatFSEventFlags(entry.flags))")
				print("       eventId: \(entry.id)")
			}
			print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		}
		#endif

		// Hand off into the actor context
		Task { [service, payload] in
			await service.enqueueFSEventHandlingTask(payload)
		}
	}
	
	// MARK: - Core event coalescing & handling
	
	private func enqueueFSEventHandlingTask(_ payload: FSEventCallbackPayload) {
		guard payload.count > 0 else { return }

		let payloadMaxEventID = payload.entries.map(\.id).max() ?? 0
		if hasPendingOverflowRescan {
			collapsePendingEventsToRootRescan(upTo: max(pendingFSEvents.first?.2 ?? 0, payloadMaxEventID))
			scheduleCoalescingIfNeeded()
			return
		}

		let projectedCount = pendingFSEvents.count + payload.count
		if projectedCount > Self.maxPendingRawEvents {
			let bufferedMaxEventID = pendingFSEvents.map(\.2).max() ?? 0
			let maxEventID = max(bufferedMaxEventID, payloadMaxEventID)
			overflowChangedIgnoreDirs.formUnion(ignoreChangeDirs(in: pendingFSEvents))
			overflowChangedIgnoreDirs.formUnion(ignoreChangeDirs(in: payload.entries.map { ($0.path, $0.flags, $0.id) }))
			fileSystemDebugLog(
				"FSEvents overflow for \(path): collapsing \(projectedCount) raw events into a root rescan at event \(maxEventID)"
			)
			collapsePendingEventsToRootRescan(upTo: maxEventID)
			scheduleCoalescingIfNeeded()
			return
		}

		pendingFSEvents.reserveCapacity(projectedCount)
		for entry in payload.entries {
			pendingFSEvents.append((entry.path, entry.flags, entry.id))
		}
		scheduleCoalescingIfNeeded()
	}
	
	private func scheduleCoalescingIfNeeded() {
		guard coalescingTask == nil else { return }
		coalescingTask = Task {
			do {
				try await Task.sleep(nanoseconds: UInt64(coalescingDelay * 1_000_000_000))
			} catch {
				return
			}
			let events = takePendingFSEventsForProcessing()
			
			_ = await handleBatchedEvents(events)
			coalescingTask = nil
			
			// Re-arm if more events arrived while handling
			if !pendingFSEvents.isEmpty {
				scheduleCoalescingIfNeeded()
			}
		}
	}

	private func collapsePendingEventsToRootRescan(upTo eventID: FSEventStreamEventId) {
		pendingFSEvents.removeAll(keepingCapacity: false)
		pendingFSEvents.append((standardizedRootPath, Self.overflowRescanEventFlags, eventID))
		hasPendingOverflowRescan = true
	}

	private func takePendingFSEventsForProcessing() -> [(String, FSEventStreamEventFlags, FSEventStreamEventId)] {
		let events = pendingFSEvents
		pendingFSEvents.removeAll(keepingCapacity: false)
		hasPendingOverflowRescan = false
		return events
	}

	private func ignoreChangeDirs(
		in events: [(String, FSEventStreamEventFlags, FSEventStreamEventId)]
	) -> Set<String> {
		var dirs = Set<String>()
		for (absolutePath, _, _) in events {
			guard case .inside(let relativePath) = mapToRelativeEventPath(absolutePath) else { continue }
			guard isIgnoreFile(relativePath) else { continue }
			dirs.insert(parentDirectory(of: relativePath))
		}
		return dirs
	}

	private func resetWatcherIngressState() {
		coalescingTask?.cancel()
		coalescingTask = nil
		pendingFSEvents.removeAll(keepingCapacity: false)
		hasPendingOverflowRescan = false
		overflowChangedIgnoreDirs.removeAll(keepingCapacity: false)
		pendingScanTargets.removeAll(keepingCapacity: false)
		lastScannedEventIdByFolder.removeAll(keepingCapacity: false)
		lastVerifiedAtByFolder.removeAll(keepingCapacity: false)
		fileEventCountSinceLastScan.removeAll(keepingCapacity: false)
	}
	
	// MARK: - FSEvents Flag Parsing

	#if DEBUG
	/// Format FSEventStreamEventFlags into a human-readable string for debugging
	private static func formatFSEventFlags(_ flags: FSEventStreamEventFlags) -> String {
		let raw = UInt32(flags)
		var parts: [String] = []

		func check(_ flag: Int, _ name: String) {
			if (raw & UInt32(flag)) != 0 { parts.append(name) }
		}

		check(kFSEventStreamEventFlagItemCreated, "Created")
		check(kFSEventStreamEventFlagItemRemoved, "Removed")
		check(kFSEventStreamEventFlagItemRenamed, "Renamed")
		check(kFSEventStreamEventFlagItemModified, "Modified")
		check(kFSEventStreamEventFlagItemInodeMetaMod, "InodeMeta")
		check(kFSEventStreamEventFlagItemFinderInfoMod, "FinderInfo")
		check(kFSEventStreamEventFlagItemChangeOwner, "OwnerChange")
		check(kFSEventStreamEventFlagItemXattrMod, "Xattr")
		check(kFSEventStreamEventFlagItemIsFile, "IsFile")
		check(kFSEventStreamEventFlagItemIsDir, "IsDir")
		check(kFSEventStreamEventFlagItemIsSymlink, "IsSymlink")
		check(kFSEventStreamEventFlagMustScanSubDirs, "MustScanSubDirs")
		check(kFSEventStreamEventFlagUserDropped, "UserDropped")
		check(kFSEventStreamEventFlagKernelDropped, "KernelDropped")
		check(kFSEventStreamEventFlagRootChanged, "RootChanged")

		let flagStr = parts.isEmpty ? "None" : parts.joined(separator: "|")
		return "\(raw) [\(flagStr)]"
	}
	#endif

	/// Parsed representation of FSEvents flags for cleaner event handling
	private struct ParsedEvent {
		let isDir: Bool
		let isFile: Bool
		
		let isCreated: Bool
		let isRemoved: Bool
		let isRenamed: Bool
		let isContentChange: Bool   // data or xattrs changed
		let isMetadataChange: Bool  // inode, finder info, owner
		
		// Reliability signals that require more aggressive handling
		let mustScanSubdirs: Bool       // kFSEventStreamEventFlagMustScanSubDirs
		let userOrKernelDropped: Bool   // events were dropped
		let rootChanged: Bool           // mount/unmount or root moved
		
		/// True if this event requires us to scan directories for correctness
		var requiresAggressiveScan: Bool {
			mustScanSubdirs || userOrKernelDropped || rootChanged
		}
	}
	
	/// Parse FSEventStreamEventFlags into a structured representation
	private static func parseEventFlags(
		_ flags: FSEventStreamEventFlags,
		isDirFallback: Bool
	) -> ParsedEvent {
		let raw = UInt32(flags)
		
		// FSEvents constants are Int on macOS, convert to UInt32 for bitwise comparison
		func has(_ flag: Int) -> Bool { (raw & UInt32(flag)) != 0 }
		
		let isDirFlag = has(kFSEventStreamEventFlagItemIsDir)
		let isFileFlag = has(kFSEventStreamEventFlagItemIsFile)
		
		return ParsedEvent(
			isDir: isDirFlag || (!isFileFlag && isDirFallback),
			isFile: isFileFlag || (!isDirFlag && !isDirFallback),
			isCreated: has(kFSEventStreamEventFlagItemCreated),
			isRemoved: has(kFSEventStreamEventFlagItemRemoved),
			isRenamed: has(kFSEventStreamEventFlagItemRenamed),
			isContentChange: has(kFSEventStreamEventFlagItemModified) || has(kFSEventStreamEventFlagItemXattrMod),
			isMetadataChange: has(kFSEventStreamEventFlagItemInodeMetaMod) ||
							has(kFSEventStreamEventFlagItemFinderInfoMod) ||
							has(kFSEventStreamEventFlagItemChangeOwner),
			mustScanSubdirs: has(kFSEventStreamEventFlagMustScanSubDirs),
			userOrKernelDropped: has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped),
			rootChanged: has(kFSEventStreamEventFlagRootChanged)
		)
	}

	private enum EventRegularFileIgnoreDecision: Equatable {
		case ignored
		case visible
		case requiresFallback
	}

	private enum EventDirectLeafIgnoreMode {
		case parentIgnored
		case noOp
		case matcher(PositiveOnlyDirectFileLeafMatcher)
		case unsupported

		var isUnsupported: Bool {
			if case .unsupported = self { return true }
			return false
		}

		var isParentIgnored: Bool {
			if case .parentIgnored = self { return true }
			return false
		}
	}

	private struct EventRegularFileParentIgnoreState {
		let hierarchicalMode: EventDirectLeafIgnoreMode
		let prefixMode: EventDirectLeafIgnoreMode

		func decision(leafName: String) -> EventRegularFileIgnoreDecision {
			if hierarchicalMode.isUnsupported || prefixMode.isUnsupported {
				return .requiresFallback
			}
			if hierarchicalMode.isParentIgnored || prefixMode.isParentIgnored {
				return .ignored
			}

			var matched = false
			if case .matcher(let matcher) = hierarchicalMode, matcher.ignores(leafName: leafName) {
				matched = true
			}
			if case .matcher(let matcher) = prefixMode, matcher.ignores(leafName: leafName) {
				matched = true
			}
			return matched ? .ignored : .visible
		}

		#if DEBUG
		func decision(
			leafName: String,
			diagnostics: inout EventTargetIgnoreFastPathDiagnostics
		) -> EventRegularFileIgnoreDecision {
			if hierarchicalMode.isUnsupported || prefixMode.isUnsupported {
				return .requiresFallback
			}
			if hierarchicalMode.isParentIgnored || prefixMode.isParentIgnored {
				return .ignored
			}

			var matched = false
			if case .matcher(let matcher) = hierarchicalMode {
				diagnostics.directLeafCheckCount += 1
				if matcher.ignores(leafName: leafName) {
					matched = true
				}
			}
			if case .matcher(let matcher) = prefixMode {
				diagnostics.directLeafCheckCount += 1
				if matcher.ignores(leafName: leafName) {
					matched = true
				}
			}
			if matched {
				diagnostics.directLeafIgnoredCount += 1
				return .ignored
			}
			return .visible
		}
		#endif

		var isUnsupported: Bool {
			hierarchicalMode.isUnsupported || prefixMode.isUnsupported
		}
	}

	
	private func fullTargetIgnoreCheck(relativePath: String, isDirectory: Bool) async -> Bool {
		if enableHierarchicalIgnores {
			return await isIgnoredHierarchical(relativePath: relativePath, isDirectory: isDirectory)
		}
		return isIgnoredPrefixCheck(relativePath: relativePath)
	}

	private func parentAndLeafName(forPreparedRelativePath relativePath: String) -> (parent: String, leafName: String)? {
		guard !relativePath.isEmpty else { return nil }
		let parent: String
		let leafName: String
		if let slashIndex = relativePath.lastIndex(of: "/") {
			leafName = String(relativePath[relativePath.index(after: slashIndex)...])
			parent = String(relativePath[..<slashIndex])
		} else {
			parent = ""
			leafName = relativePath
		}
		guard !leafName.isEmpty, leafName != ".", leafName != ".." else { return nil }
		return (parent, leafName)
	}

	private func shouldIgnoreUnknownRegularFileEvent(
		relativePath: String,
		parentStateCache: inout [String: EventRegularFileParentIgnoreState]
	) async -> EventRegularFileIgnoreDecision {
		guard let path = parentAndLeafName(forPreparedRelativePath: relativePath) else {
			let ignored = await fullTargetIgnoreCheck(relativePath: relativePath, isDirectory: false)
			return ignored ? .ignored : .visible
		}

		let parentState: EventRegularFileParentIgnoreState
		if let cached = parentStateCache[path.parent] {
			parentState = cached
		} else {
			let built = await buildEventRegularFileParentIgnoreState(parent: path.parent)
			parentStateCache[path.parent] = built
			parentState = built
		}

		let decision = parentState.decision(leafName: path.leafName)
		guard decision == .requiresFallback else { return decision }

		let ignored = await fullTargetIgnoreCheck(relativePath: relativePath, isDirectory: false)
		return ignored ? .ignored : .visible
	}

	#if DEBUG
	private func shouldIgnoreUnknownRegularFileEvent(
		relativePath: String,
		parentStateCache: inout [String: EventRegularFileParentIgnoreState],
		diagnostics: inout EventTargetIgnoreFastPathDiagnostics
	) async -> EventRegularFileIgnoreDecision {
		diagnostics.unknownRegularFileDecisionCount += 1

		guard let path = parentAndLeafName(forPreparedRelativePath: relativePath) else {
			diagnostics.fallbackFullTargetIgnoreCheckCount += 1
			let ignored = await fullTargetIgnoreCheck(relativePath: relativePath, isDirectory: false)
			if ignored { diagnostics.fallbackFullTargetIgnoredCount += 1 }
			return ignored ? .ignored : .visible
		}

		let parentState: EventRegularFileParentIgnoreState
		if let cached = parentStateCache[path.parent] {
			diagnostics.parentStateCacheHitCount += 1
			parentState = cached
		} else {
			diagnostics.parentStateCacheMissCount += 1
			let built = await buildEventRegularFileParentIgnoreState(parent: path.parent)
			parentStateCache[path.parent] = built
			if built.isUnsupported {
				diagnostics.unsupportedParentStateCount += 1
			} else {
				diagnostics.exactParentStateCount += 1
			}
			parentState = built
		}

		let decision = parentState.decision(leafName: path.leafName, diagnostics: &diagnostics)
		guard decision == .requiresFallback else { return decision }

		diagnostics.fallbackFullTargetIgnoreCheckCount += 1
		let ignored = await fullTargetIgnoreCheck(relativePath: relativePath, isDirectory: false)
		if ignored { diagnostics.fallbackFullTargetIgnoredCount += 1 }
		return ignored ? .ignored : .visible
	}
	#endif

	private func buildEventRegularFileParentIgnoreState(parent: String) async -> EventRegularFileParentIgnoreState {
		let prefixMode = eventPrefixDirectLeafIgnoreMode(parent: parent)
		let hierarchicalMode: EventDirectLeafIgnoreMode

		if !enableHierarchicalIgnores {
			hierarchicalMode = .noOp
		} else {
			do {
				_ = try await ensureRulesChain(for: parent)
				guard let rulesByDirectory = cachedRulesByDirectoryForParent(parent),
					let parentState = catalogPreparedIgnoreParentState(parent: parent, rulesByDirectory: rulesByDirectory) else {
					hierarchicalMode = .unsupported
					return EventRegularFileParentIgnoreState(hierarchicalMode: hierarchicalMode, prefixMode: prefixMode)
				}
				hierarchicalMode = eventHierarchicalDirectLeafIgnoreMode(parentState: parentState)
			} catch {
				hierarchicalMode = .unsupported
			}
		}

		return EventRegularFileParentIgnoreState(hierarchicalMode: hierarchicalMode, prefixMode: prefixMode)
	}

	private func cachedRulesByDirectoryForParent(_ parent: String) -> [String: IgnoreRules]? {
		var rulesByDirectory: [String: IgnoreRules] = [:]
		rulesByDirectory.reserveCapacity(parent.split(separator: "/").count + 1)
		guard let rootRules = perFolderIgnoreCache[""] else { return nil }
		rulesByDirectory[""] = rootRules

		var current = ""
		for component in parent.split(separator: "/") {
			current = current.isEmpty ? String(component) : "\(current)/\(component)"
			guard let rules = perFolderIgnoreCache[current] else { return nil }
			rulesByDirectory[current] = rules
		}
		return rulesByDirectory
	}

	private func eventPrefixDirectLeafIgnoreMode(parent: String) -> EventDirectLeafIgnoreMode {
		let parentState = catalogPrefixIgnoreParentState(parent: parent)
		if parentState.parentIsIgnored {
			return .parentIgnored
		}
		if parentState.directFileLeafCheckIsNoOp {
			return .noOp
		}
		guard !ignoreRules.hasAnyNegativePatterns(),
			let matcher = ignoreRules.makePositiveOnlyDirectFileLeafMatcher(parentComponents: parentState.parentComponents) else {
			return .unsupported
		}
		return .matcher(matcher)
	}

	private func eventHierarchicalDirectLeafIgnoreMode(parentState: CatalogPreparedIgnoreParentState) -> EventDirectLeafIgnoreMode {
		if parentState.leafRules.hasAnyNegativePatterns() {
			return .unsupported
		}
		if parentState.lastOutcome == .ignore {
			return .parentIgnored
		}
		if parentState.directFileLeafCheckIsNoOp {
			return .noOp
		}
		guard let matcher = parentState.leafRules.makePositiveOnlyDirectFileLeafMatcher(
			parentComponents: parentState.parentComponents
		) else {
			return .unsupported
		}
		return .matcher(matcher)
	}

	// MARK: - Temp File Detection for Atomic Saves
	
	/// Common temp file suffixes used by editors for atomic saves
	private static let tempNameSuffixes: [String] = [
		"~",           // vim backup
		".tmp", ".temp",
		".swp", ".swo", ".swx",   // vim swap
		".bak", ".backup", ".orig", ".old",
		"__jb_tmp__", "__jb_old__"  // JetBrains
	]
	
	/// Common temp file prefixes used by editors
	private static let tempNamePrefixes: [String] = [
		".#",       // Emacs
		"._",       // macOS resource fork
		"~$"        // MS Office
	]
	
	/// Check if a path looks like a temporary file used for atomic saves
	private static func isTempSaveName(_ relPath: String) -> Bool {
		let name = (relPath as NSString).lastPathComponent.lowercased()
		
		for suffix in tempNameSuffixes where name.hasSuffix(suffix) {
			return true
		}
		for prefix in tempNamePrefixes where name.hasPrefix(prefix) {
			return true
		}
		
		// Vim-style hidden swap: .filename.swp
		if name.hasPrefix(".") && name.contains(".sw") { return true }
		
		return false
	}
	
	// MARK: - Safety-Net Scanning
	
	/// Get current time for safety-net interval tracking
	@inline(__always)
	private func currentTime() -> TimeInterval {
		CFAbsoluteTimeGetCurrent()
	}
	
	/// Record that a folder was just verified via directory scan
	private func recordFolderVerified(_ folder: String) {
		lastVerifiedAtByFolder[folder] = currentTime()
		fileEventCountSinceLastScan[folder] = 0
	}
	
	/// Check if a folder should receive a safety-net scan based on event count and time
	/// Returns true if we should schedule a scan
	private func shouldScheduleSafetyNetScan(for parent: String) -> Bool {
		guard !parent.isEmpty else { return false }
		
		// Increment event count
		let count = (fileEventCountSinceLastScan[parent] ?? 0) + 1
		fileEventCountSinceLastScan[parent] = count
		
		// Check thresholds
		let lastVerified = lastVerifiedAtByFolder[parent] ?? 0
		let elapsed = currentTime() - lastVerified
		
		let stale = elapsed >= safetyNetMinInterval
		let highChurn = count >= safetyNetEventThreshold
		
		return stale || highChurn
	}
	
	private func handleBatchedEvents(
		_ events: [(String, FSEventStreamEventFlags, FSEventStreamEventId)],
		testMode: Bool = false
	) async -> [FileSystemDelta]? {
		guard !events.isEmpty else { return testMode ? [] : nil }

		#if DEBUG
		if Self.enableDebugLogging {
			print("┌─────────────────────────────────────────────────────────────")
			print("│ 📥 handleBatchedEvents: Processing \(events.count) coalesced events")
			for (path, flags, eventId) in events {
				print("│   path: '\(path)'")
				print("│   flags: \(Self.formatFSEventFlags(flags)), eventId: \(eventId)")
			}
			print("└─────────────────────────────────────────────────────────────")
		}
		if isTestMode && Self.enableDebugLogging {
			print("DEBUG: handleBatchedEvents called with \(events.count) events")
			for (path, flags, _) in events {
				print("DEBUG: Event - path: '\(path)', flags: \(flags)")
			}
		}
		#endif
		
		var foldersToScan = Set<String>()
		var folderMaxEventId: [String: FSEventStreamEventId] = [:] // Track max event ID per folder
		var immediateModifications: [FileSystemDelta] = []
		var changedIgnoreDirs = overflowChangedIgnoreDirs
		var eventRegularFileParentStateCache: [String: EventRegularFileParentIgnoreState] = [:]
		#if DEBUG
		var eventTargetIgnoreFastPathDiagnostics = EventTargetIgnoreFastPathDiagnostics()
		var eventPathMappingFastPathDiagnostics = EventPathMappingFastPathDiagnostics()
		#endif
		overflowChangedIgnoreDirs.removeAll(keepingCapacity: false)
		
		// Helper to track folder with its event ID
		func trackFolder(_ folder: String, eventId: FSEventStreamEventId) {
			foldersToScan.insert(folder)
			folderMaxEventId[folder] = max(folderMaxEventId[folder] ?? 0, eventId)
		}
		
		for (absPath, flags, eventId) in events {
			let relPath: String
			#if DEBUG
			let mappedEventPath = mapToRelativeEventPath(absPath, diagnostics: &eventPathMappingFastPathDiagnostics)
			#else
			let mappedEventPath = mapToRelativeEventPath(absPath)
			#endif
			switch mappedEventPath {
			case .outside(let original):
#if DEBUG
			if isTestMode && Self.enableDebugLogging {
				print("DEBUG: Dropping event outside root: \(original)")
			}
				#endif
				continue
			case .inside(let relative):
				relPath = relative
			}

			if isGitMetadataPath(relPath) {
#if DEBUG
				if isTestMode && Self.enableDebugLogging {
					print("DEBUG: Ignoring .git metadata event at \(relPath)")
				}
#endif
				continue
			}
			
			if isRepoPromptTempPath(relPath) {
				continue
			}
			
#if DEBUG
			if isTestMode && Self.enableDebugLogging {
				print("DEBUG: Converted absolute path '\(absPath)' to relative path '\(relPath)'")
			}
			#endif
			
			let isIgnore = isIgnoreFile(relPath)
			let isControlFile = isSpecialControlFile(relPath)
			
			// Always update filter flag for ignore files.
			if isIgnore {
				changedIgnoreDirs.insert(parentDirectory(of: relPath))
			}

			// Determine whether this event is for a directory, trusting FSEvents when possible.
			let isDirFallback = visitedItems[relPath] ?? fileOrFolderIsDir(relPath)
			let parsed = Self.parseEventFlags(flags, isDirFallback: isDirFallback)
			let isDir = parsed.isDir
			
			// Handle aggressive scan requirements (FSEvents overflow, dropped events, root changes)
			// These are rare but critical - we must rescan to maintain correctness
			if parsed.requiresAggressiveScan {
				// Schedule root scan for comprehensive recovery
				trackFolder("", eventId: eventId)
				#if DEBUG
				if isTestMode && Self.enableDebugLogging {
					print("DEBUG: Aggressive scan required - mustScan=\(parsed.mustScanSubdirs), dropped=\(parsed.userOrKernelDropped), rootChanged=\(parsed.rootChanged)")
				}
				#endif
				continue
			}
			
			// ---------- UPDATED FILTER LOGIC ---------------------------------------
			let isKnown = visitedPaths.contains(relPath)
			let isUnknownRegularFileLike = parsed.isFile && !isDir && !parsed.isRenamed && !parsed.isRemoved
			let shouldIgnore: Bool
			if isKnown || isControlFile {
				#if DEBUG
				eventTargetIgnoreFastPathDiagnostics.skippedKnownOrControlTargetIgnoreCheckCount += 1
				#endif
				shouldIgnore = false
			} else if isUnknownRegularFileLike {
				#if DEBUG
				let decision = await shouldIgnoreUnknownRegularFileEvent(
					relativePath: relPath,
					parentStateCache: &eventRegularFileParentStateCache,
					diagnostics: &eventTargetIgnoreFastPathDiagnostics
				)
				#else
				let decision = await shouldIgnoreUnknownRegularFileEvent(
					relativePath: relPath,
					parentStateCache: &eventRegularFileParentStateCache
				)
				#endif
				shouldIgnore = decision == .ignored
			} else {
				#if DEBUG
				eventTargetIgnoreFastPathDiagnostics.exactFullTargetIgnoreCheckCount += 1
				#endif
				shouldIgnore = await fullTargetIgnoreCheck(relativePath: relPath, isDirectory: isDir)
			}
			
			#if DEBUG
			if isTestMode && Self.enableDebugLogging {
				let isRename = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) != 0
				print("DEBUG: Processing event for '\(relPath)' - isKnown=\(isKnown), isRename=\(isRename), shouldIgnore=\(shouldIgnore), isIgnoreFile=\(isIgnoreFile(relPath))")
			}
			#endif
			
			// Drop only "brand-new + still-ignored + not an ignore-file" paths
			if !isKnown && !isControlFile && shouldIgnore {
				#if DEBUG
				if isTestMode && Self.enableDebugLogging {
					print("DEBUG: FILTERED OUT event for path: \(relPath)")
				}
				#endif
				continue
			}
			// ----------------------------------------------------------------------
			
			// Use parsed flags for cleaner event handling
			let removed = parsed.isRemoved
			let created = parsed.isCreated
			let modified = parsed.isContentChange || parsed.isMetadataChange || created

			#if DEBUG
			if Self.enableDebugLogging {
				print("📋 Event for '\(relPath)':")
				print("   isKnown=\(isKnown), isDir=\(isDir), isRenamed=\(parsed.isRenamed)")
				print("   removed=\(removed), created=\(created), modified=\(modified)")
				if removed && !isKnown {
					print("   ⚠️ REMOVED flag set but path NOT KNOWN - will NOT emit fileRemoved!")
				}
				if removed && !parsed.isRenamed {
					print("   📋 REMOVED flag set but NOT a rename - pure deletion (handled)")
				}
			}
			#endif

			#if DEBUG
			// Debug logging for flag analysis
			if isTestMode && Self.enableDebugLogging && relPath.contains("file.txt") {
				print("DEBUG: Flags for \(relPath): \(flags)")
				print("  ItemModified: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified))")
				print("  ItemCreated: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))")
				print("  ItemRemoved: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved))")
				print("  ItemRenamed: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed))")
				print("  ItemInodeMetaMod: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemInodeMetaMod))")
				print("  ItemFinderInfoMod: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemFinderInfoMod))")
				print("  ItemChangeOwner: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemChangeOwner))")
				print("  ItemXattrMod: \(flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemXattrMod))")
				print("  Calculated modified: \(modified)")
				print("  Calculated removed: \(removed)")
				print("  Is in visitedPaths: \(visitedPaths.contains(relPath))")
			}
			#endif
			
			if !removed && modified {
				// For files already tracked, send immediate modification
				if visitedPaths.contains(relPath) {
					if isDir {
						let mdate = await getItemModificationDateIfAvailable(atRelativePath: relPath)
						immediateModifications.append(.folderModified(relPath, mdate))
					} else {
						let mdate = try? await getFileModificationDate(atRelativePath: relPath)
						immediateModifications.append(.fileModified(relPath, mdate))
					}
					// If it's a tracked folder, also scan it for changes
					if isDir {
						trackFolder(relPath, eventId: eventId)
					}
				} else {
					let parent = parentDirectory(of: relPath)
					trackFolder(parent, eventId: eventId)
				}
			}

			// ── Pure deletion handling (removed WITHOUT rename flag) ────────────────
			// Direct deletions (rm, programmatic) may not have the rename flag
			if removed && !parsed.isRenamed && isKnown {
				let fullPath = getFullPath(forRelativePath: relPath)
				let stillExists = fm.fileExists(atPath: fullPath, isDirectory: nil)

				if !stillExists {
					// File is truly gone - emit removal delta
					#if DEBUG
					if Self.enableDebugLogging {
						print("🗑️ PURE DELETION detected for '\(relPath)' (no rename flag)")
					}
					#endif
					immediateModifications.append(isDir ? .folderRemoved(relPath) : .fileRemoved(relPath))

					// If directory, also remove children
					if isDir {
						let childrenToRemove = visitedPaths.filter { $0.hasPrefix(relPath + "/") }
						for child in childrenToRemove {
							let childIsDir = visitedItems[child] ?? false
							immediateModifications.append(childIsDir ? .folderRemoved(child) : .fileRemoved(child))
							visitedPaths.remove(child)
							visitedItems.removeValue(forKey: child)
						}
					}

					visitedPaths.remove(relPath)
					visitedItems.removeValue(forKey: relPath)
				} else {
					// Anomaly: removed flag but file still exists - schedule parent scan
					let parent = parentDirectory(of: relPath)
					if !parent.isEmpty {
						trackFolder(parent, eventId: eventId)
					}
				}
				continue
			}

			// ── Rename handling ──────────────────────────────────────────────────────
			if parsed.isRenamed {
				let isTempFile = Self.isTempSaveName(relPath)

				// Renamed events sometimes arrive WITHOUT Created/Removed (Finder trash moves, cross-dir moves, etc.)
				if !created && !removed {
					// Ignore temp-save churn
					if isTempFile { continue }

					let fullPath = getFullPath(forRelativePath: relPath)
					var isDirFlag: ObjCBool = false
					let exists = fm.fileExists(atPath: fullPath, isDirectory: &isDirFlag)
					let diskIsDir = exists ? isDirFlag.boolValue : isDir   // fallback to our best guess

					if exists {
						// Path exists at this location: treat as add (if unknown) or modify (if known)
						if isKnown {
							if diskIsDir {
								let mdate = await getItemModificationDateIfAvailable(atRelativePath: relPath)
								immediateModifications.append(.folderModified(relPath, mdate))
								trackFolder(relPath, eventId: eventId)
							} else {
								let mdate = try? await getFileModificationDate(atRelativePath: relPath)
								immediateModifications.append(.fileModified(relPath, mdate))
							}
						} else {
							immediateModifications.append(diskIsDir ? .folderAdded(relPath) : .fileAdded(relPath))
							visitedPaths.insert(relPath)
							visitedItems[relPath] = diskIsDir
							if diskIsDir { trackFolder(relPath, eventId: eventId) }
						}
					} else if isKnown {
						// Path no longer exists here => removal from watched root
						immediateModifications.append(diskIsDir ? .folderRemoved(relPath) : .fileRemoved(relPath))

						if diskIsDir {
							let childrenToRemove = visitedPaths.filter { $0.hasPrefix(relPath + "/") }
							for child in childrenToRemove {
								let childIsDir = visitedItems[child] ?? false
								immediateModifications.append(childIsDir ? .folderRemoved(child) : .fileRemoved(child))
								visitedPaths.remove(child)
								visitedItems.removeValue(forKey: child)
							}
						}

						visitedPaths.remove(relPath)
						visitedItems.removeValue(forKey: relPath)
					}

					// Always verify parent to discover paired destination if it moved within the repo
					let parent = parentDirectory(of: relPath)
					trackFolder(parent, eventId: eventId)
					continue
				}

				// Atomic save detection: Renamed+Created on a known, non-temp path
				// This is the common pattern for editor saves (temp → real file)
				// BUT: trash/move-away also sends Created+Renamed, so verify file exists!
				if created && isKnown && !isTempFile && !isDir {
					let fullPath = getFullPath(forRelativePath: relPath)
					let stillExists = fm.fileExists(atPath: fullPath, isDirectory: nil)

					if stillExists {
						// Treat as file modification (atomic save completed)
						let mdate = try? await getFileModificationDate(atRelativePath: relPath)
						immediateModifications.append(.fileModified(relPath, mdate))
						#if DEBUG
						if isTestMode && Self.enableDebugLogging {
							print("DEBUG: Detected atomic save for '\(relPath)'")
						}
						#endif
						// Skip parent scan for atomic saves - we already know what changed
						continue
					} else {
						// File gone - this is a move-away (trash, mv out), not an atomic save
						#if DEBUG
						if Self.enableDebugLogging {
							print("🗑️ MOVE-AWAY detected for '\(relPath)' (Created+Renamed but file gone)")
						}
						#endif
						immediateModifications.append(.fileRemoved(relPath))
						visitedPaths.remove(relPath)
						visitedItems.removeValue(forKey: relPath)
						continue
					}
				}
				
				// Update state immediately for rename chains, with anomaly detection
				if removed && isKnown {
					#if DEBUG
					if Self.enableDebugLogging {
						print("🗑️ REMOVAL detected for KNOWN path: '\(relPath)' (isDir=\(isDir))")
					}
					#endif
					// Anomaly check: verify the file is actually gone
					// FSEvents can report removal for renames where file still exists
					let fullPath = getFullPath(forRelativePath: relPath)
					let stillExists = fm.fileExists(atPath: fullPath, isDirectory: nil)

					#if DEBUG
					if Self.enableDebugLogging {
						print("   → Disk check: stillExists=\(stillExists) at '\(fullPath)'")
					}
					#endif

					if stillExists {
						// Anomaly: "removed" but file still exists
						// Don't remove from visitedPaths; treat as modification and verify via scan
						#if DEBUG
						if Self.enableDebugLogging {
							print("   ⚠️ ANOMALY: File still exists, treating as modification")
						}
						if isTestMode && Self.enableDebugLogging {
							print("DEBUG: Removal anomaly - '\(relPath)' still exists on disk")
						}
						#endif
						if !isDir {
							let mdate = try? await getFileModificationDate(atRelativePath: relPath)
							immediateModifications.append(.fileModified(relPath, mdate))
						}
						// Schedule parent scan to verify state
						let parent = parentDirectory(of: relPath)
						if !parent.isEmpty {
							trackFolder(parent, eventId: eventId)
						}
						continue
					}

					// Normal removal: generate delta and update state
					#if DEBUG
					if Self.enableDebugLogging {
						print("   ✅ EMITTING: \(isDir ? "folderRemoved" : "fileRemoved")('\(relPath)')")
					}
					#endif
					immediateModifications.append(isDir ? .folderRemoved(relPath) : .fileRemoved(relPath))
					
					// If it's a directory being removed, also remove all its children
					if isDir {
						let childrenToRemove = visitedPaths.filter { $0.hasPrefix(relPath + "/") }
						for child in childrenToRemove {
							let childIsDir = visitedItems[child] ?? false
							immediateModifications.append(childIsDir ? .folderRemoved(child) : .fileRemoved(child))
							visitedPaths.remove(child)
							visitedItems.removeValue(forKey: child)
						}
					}
					visitedPaths.remove(relPath)
					visitedItems.removeValue(forKey: relPath)
					
					// For temp file removals, no need to scan parent
					if isTempFile {
						continue
					}
				} else if created && !isKnown {
					// Skip temp file creations from tracking
					if isTempFile {
						continue
					}
					
					// Anomaly check: verify the file actually exists
					// FSEvents can report creation for renames where file was moved away
					let fullPath = getFullPath(forRelativePath: relPath)
					let actuallyExists = fm.fileExists(atPath: fullPath, isDirectory: nil)
					
					if !actuallyExists {
						// Anomaly: "created" but file doesn't exist
						// Don't add to visitedPaths; schedule parent scan to verify
						#if DEBUG
						if isTestMode && Self.enableDebugLogging {
							print("DEBUG: Creation anomaly - '\(relPath)' doesn't exist on disk")
						}
						#endif
						let parent = parentDirectory(of: relPath)
						if !parent.isEmpty {
							trackFolder(parent, eventId: eventId)
						}
						continue
					}
					
					// Normal creation: generate delta and update state
					immediateModifications.append(isDir ? .folderAdded(relPath) : .fileAdded(relPath))
					visitedPaths.insert(relPath)
					visitedItems[relPath] = isDir
				}
				
				// For directory renames, scan the new directory to find its contents
				if isDir && created {
					trackFolder(relPath, eventId: eventId)
				}
				
				// For non-temp rename anomalies (removed without paired creation),
				// schedule parent verification
				if removed && !isTempFile {
					let parent = parentDirectory(of: relPath)
					if !parent.isEmpty {
						trackFolder(parent, eventId: eventId)
					}
				}
				
				// Continue to skip the generic parent scan for renames
				// (we've already handled what needs to be scanned above)
				continue
			}
			// ─────────────────────────────────────────────────────────────────────────
			
			// Parent scan needed for:
			// - Directory events (contents may have changed)
			// - Unknown paths (need to discover them)
			// NOT needed for known file modifications (already handled above)
			let parent = parentDirectory(of: relPath)

			if parent.hasPrefix("/") {
				continue
			}

			let needsParentScan = isDir || !isKnown

			if needsParentScan {
				if enableHierarchicalIgnores {
					if !(await isIgnoredHierarchicalDir(parent)) {
						trackFolder(parent, eventId: eventId)
					}
				} else if !isIgnoredPrefixCheck(relativePath: parent) {
					trackFolder(parent, eventId: eventId)
				}
			}
		}
		
		var allDeltas: [FileSystemDelta] = []
		allDeltas.append(contentsOf: immediateModifications)
		
		// ── Event ID-based coalescing: filter to only folders needing scan ──
		// Update pendingScanTargets with this batch's event IDs
		for (folder, maxId) in folderMaxEventId {
			pendingScanTargets[folder] = max(pendingScanTargets[folder] ?? 0, maxId)
		}
		
		// Build eligible set: folders that need scanning
		// - nil lastScannedId means "never scanned" → always eligible
		// - Otherwise, only rescan if pendingId > lastScannedId
		let eligibleFolders = Set(foldersToScan.filter { folder in
			guard let pendingId = pendingScanTargets[folder] else {
				return false  // No pending scan target (shouldn't happen, but be defensive)
			}
			guard let lastScannedId = lastScannedEventIdByFolder[folder] else {
				return true  // Never scanned before → always scan at least once
			}
			return pendingId > lastScannedId  // Only rescan if newer events arrived
		})
		
		// Use parallel scanning for better I/O performance
		if !eligibleFolders.isEmpty {
			do {
				#if DEBUG
				if isTestMode {
					// Track all folders being processed
					for folder in eligibleFolders {
						processedFolders.insert(folder)
					}
				}
				#endif
				
				// Ensure all folders have their ignore rules loaded before parallel scan
				if enableHierarchicalIgnores {
					for folderRelPath in eligibleFolders {
						_ = try await ensureRulesChain(for: folderRelPath)
					}
				}
				
				let folderDeltas = try await scanFoldersInParallel(eligibleFolders)
				allDeltas.append(contentsOf: folderDeltas)
				
				// Update tracking for successfully scanned folders
				for folder in eligibleFolders {
					if let pendingId = pendingScanTargets[folder] {
						lastScannedEventIdByFolder[folder] = pendingId
						pendingScanTargets.removeValue(forKey: folder)
					}
					// Record verification time for safety-net tracking
					recordFolderVerified(folder)
				}
			} catch {
				print("Error during parallel folder scanning: \(error)")
				// Fallback to serial scanning if parallel fails
				for folderRelPath in eligibleFolders {
					do {
						let deltas = try await scanOneLevelAndDiff(folderRelPath)
						allDeltas.append(contentsOf: deltas)
						// Update tracking for successfully scanned folder
						if let pendingId = pendingScanTargets[folderRelPath] {
							lastScannedEventIdByFolder[folderRelPath] = pendingId
							pendingScanTargets.removeValue(forKey: folderRelPath)
						}
						// Record verification time for safety-net tracking
						recordFolderVerified(folderRelPath)
					} catch {
						print("Error scanning folder '\(folderRelPath)': \(error)")
						// Leave in pendingScanTargets - will retry when a new FSEvent for this folder arrives
					}
				}
			}
		}
		
		#if DEBUG
		if Self.enableDebugLogging {
			print("┌─────────────────────────────────────────────────────────────")
			print("│ 📤 PUBLISHING \(allDeltas.count) deltas:")
			for delta in allDeltas {
				switch delta {
				case .fileAdded(let path): print("│   ➕ fileAdded: '\(path)'")
				case .fileRemoved(let path): print("│   ➖ fileRemoved: '\(path)'")
				case .folderAdded(let path): print("│   📁➕ folderAdded: '\(path)'")
				case .folderRemoved(let path): print("│   📁➖ folderRemoved: '\(path)'")
				case .fileModified(let path, _): print("│   ✏️ fileModified: '\(path)'")
				case .folderModified(let path, _): print("│   📁✏️ folderModified: '\(path)'")
				}
			}
			if allDeltas.isEmpty {
				print("│   (no deltas to publish)")
			}
			print("└─────────────────────────────────────────────────────────────")
		}
		#endif

		let publishSignpost = FileSystemPublishPerf.begin("coalesceAndPublishFileSystemDeltas")
		let publishableDeltas = coalescedPublishableDeltas(from: allDeltas)
		#if DEBUG
		lastPublishedDeltaCoalescingDiagnostics = PublishedDeltaCoalescingDiagnostics(
			rawDeltaCount: allDeltas.count,
			publishedDeltaCount: publishableDeltas.count
		)
		lastEventTargetIgnoreFastPathDiagnostics = eventTargetIgnoreFastPathDiagnostics
		lastEventPathMappingFastPathDiagnostics = eventPathMappingFastPathDiagnostics
		#endif
		if !publishableDeltas.isEmpty {
			changePublisher.send(publishableDeltas)
		}
		FileSystemPublishPerf.end("coalesceAndPublishFileSystemDeltas", publishSignpost)

		// Flush the split-components cache; next scan will repopulate lazily.
		pathCompsCache.removeAll()
		
		// ------------------------------------------------------------------
		// Rebuild ignore-rule cache if any of the ignore files changed
		// ------------------------------------------------------------------
		if !changedIgnoreDirs.isEmpty {
			// Record the change durably for consumers (don't clear until consumed)
			ignoreRulesRevision &+= 1
			pendingIgnoreChangeDirs.formUnion(changedIgnoreDirs)
			let dirs = changedIgnoreDirs             // capture before escaping
			#if DEBUG
			if isTestMode {
				await rebuildPerFolderIgnoreCache(changedDirs: dirs)
			} else {
				Task { await rebuildPerFolderIgnoreCache(changedDirs: dirs) }
			}
			#else
			Task { await rebuildPerFolderIgnoreCache(changedDirs: dirs) }
			#endif
		}
		
		// Return the published deltas in test mode.
		return testMode ? publishableDeltas : nil
	}
	
	/// Rebuild (or partially invalidate) the per-folder ignore cache when
	/// `.gitignore` / `.repo_ignore` files change.
	///
	/// - Parameter changedDirs: A set of relative directory paths whose ignore
	///   files changed. `nil` or an empty set falls back to the legacy *full*
	///   rebuild behaviour.
	private func rebuildPerFolderIgnoreCache(
		changedDirs: Set<String>? = nil
	) async {
		// Clear all per-path ignore caches to avoid stale decisions
		ignoreCacheStore = IgnoreCacheStore()
		
		// ── Legacy: full rebuild ────────────────────────────────────────────
		guard let dirs = changedDirs, !dirs.isEmpty else {
			perFolderIgnoreCache.removeAll()
			clearNoIgnoreFilesCache()
			do {
				ignoreRules = try await IgnoreRulesManager.shared.getIgnoreRules(
					for: path,
					respectGitignore: respectGitignore,
					respectRepoIgnore: respectRepoIgnore,
					respectCursorignore: respectCursorignore
				)
				cacheIgnoreRules(ignoreRules, for: "")
			} catch {
				print("Failed to rebuild ignore rules: \(error)")
			}
			return
		}
		
		// ── Partial invalidation ────────────────────────────────────────────
		// Root ignore changes affect all derived rules; rebuild everything.
		if dirs.contains("") {
			perFolderIgnoreCache.removeAll()
			clearNoIgnoreFilesCache()
			do {
				ignoreRules = try await IgnoreRulesManager.shared.getIgnoreRules(
					for: path,
					respectGitignore: respectGitignore,
					respectRepoIgnore: respectRepoIgnore,
					respectCursorignore: respectCursorignore
				)
				cacheIgnoreRules(ignoreRules, for: "")
			} catch {
				print("Failed to rebuild root ignore rules: \(error)")
			}
			return
		}

		// 1) Remove affected keys from per-folder ignore cache
		let keysToRemove = perFolderIgnoreCache.keys.filter { key in
			dirs.contains { dir in
				key == dir || key.hasPrefix(dir + "/")
			}
		}
		for k in keysToRemove {
			perFolderIgnoreCache.removeValue(forKey: k)
		}
		
		// 2) Prune the no-ignore file cache
		removeNoIgnoreFilesCached { path in
			dirs.contains { dir in
				path == dir || path.hasPrefix(dir + "/")
			}
		}
		
		// 3) Root changes are handled above; no further action needed here.
	}

	
	// MARK: - New prefix-based ignore check (cached in this actor)

	private func cachedIgnoreRules(for directoryPath: String) -> IgnoreRules? {
		perFolderIgnoreCache[directoryPath]
	}
	
	/// We walk each parent sub-path, caching the result.
	public func isIgnoredPrefixCheck(relativePath: String) -> Bool {
		let comps = pathCompsCache.components(for: relativePath)
		return ignoreCacheStore.isIgnoredPrefixCheck(components: comps,
														ignoreRules: ignoreRules)
	}
	
	/// Check if a path is ignored using hierarchical rules (for delta events)
	private func isIgnoredHierarchical(relativePath: String, isDirectory overrideValue: Bool? = nil) async -> Bool {
		// If hierarchical ignores are disabled, use the simple check
		if !enableHierarchicalIgnores {
			return isIgnoredPrefixCheck(relativePath: relativePath)
		}
		
		// Get the file type
		let isDir = overrideValue ?? (visitedItems[relativePath] ?? fileOrFolderIsDir(relativePath))
		
		// Create a rules provider that uses our cache and can compute rules on demand
		let provider = FileSystemRulesProvider(service: self)
		let evaluator = HierarchicalIgnoreEvaluator(rulesProvider: provider)
		
		do {
			return try await evaluator.isIgnored(relativePath: relativePath, isDirectory: isDir)
		} catch {
			// Fall back to simple check if hierarchical evaluation fails
			return isIgnoredPrefixCheck(relativePath: relativePath)
		}
	}
	
	/// Hierarchical check that treats the target as a directory regardless of current disk state.
	private func isIgnoredHierarchicalDir(_ relativePath: String) async -> Bool {
		if relativePath.isEmpty {
			return false
		}
		if !enableHierarchicalIgnores {
			return isIgnoredPrefixCheck(relativePath: relativePath)
		}
		
		return await isIgnoredHierarchical(relativePath: relativePath, isDirectory: true)
	}
	
	/// Rules provider implementation for the hierarchical evaluator
	private final class FileSystemRulesProvider: HierarchicalIgnoreEvaluator.RulesProvider {
		private let service: FileSystemService
		
		init(service: FileSystemService) {
			self.service = service
		}
		
		func rulesForDirectory(_ directoryPath: String) async throws -> IgnoreRules {
			// Check cache first
			if let cached = await service.cachedIgnoreRules(for: directoryPath) {
				#if DEBUG
				IgnoreDebugMetricsRecorder.recordHierarchicalRulesCacheHit()
				#endif
				return cached
			}
			#if DEBUG
			IgnoreDebugMetricsRecorder.recordHierarchicalRulesCacheMiss()
			#endif
			
			// Root directory uses global rules
			if directoryPath.isEmpty {
				return await service.ignoreRules
			}
			
			// Recursively compute parent rules so nested directories inherit correctly
			let parentPathComponents = directoryPath.split(separator: "/").dropLast()
			let parentPath = parentPathComponents.joined(separator: "/")
			let parentRules = try await rulesForDirectory(parentPath)
			
			// Compute rules for this directory
			let dirURL = URL(fileURLWithPath: service.path).appendingPathComponent(directoryPath)
			return try await service.getEffectiveRules(
				for: dirURL,
				parentRelPath: directoryPath,
				parentRules: parentRules
			)
		}
	}
	
	@discardableResult
	private func ensureRulesChain(for relativeDirectory: String, using scanResult: DirectoryScanResult? = nil) async throws -> IgnoreRules {
		if let cached = perFolderIgnoreCache[relativeDirectory] {
			return cached
		}
		
		if relativeDirectory.isEmpty {
			cacheIgnoreRules(ignoreRules, for: relativeDirectory)
			return ignoreRules
		}
		
		let parent = parentDirectory(of: relativeDirectory)
		let parentRules = try await ensureRulesChain(for: parent)
		let absPath = getFullPath(forRelativePath: relativeDirectory)
		
		let scan: DirectoryScanResult
		if let provided = scanResult {
			scan = provided
		} else {
			#if DEBUG
			scan = try Self.listDirectoryWithIgnoreDetection(absPath, fm: self.fm)
			#else
			scan = try Self.listDirectoryWithIgnoreDetection(absPath)
			#endif
		}
		
		let dirURL = URL(fileURLWithPath: absPath)
		return try await getEffectiveRulesOptimized(
			for: dirURL,
			parentRelPath: relativeDirectory,
			parentRules: parentRules,
			hasGitignore: scan.hasGitignore && respectGitignore,
			hasRepoIgnore: scan.hasRepoIgnore && respectRepoIgnore,
			hasCursorignore: scan.hasCursorignore && respectCursorignore
		)
	}
	
	// If you had snapshot/merge logic:
	public func snapshotIgnoreCache() -> [String: Bool] {
		return ignoreCacheStore.snapshotIgnoreCache()
	}
	
	public func snapshotIgnoreCacheWithPathKeys() -> [IgnoreCacheStore.PathKey: Bool] {
		return ignoreCacheStore.snapshotIgnoreCacheWithPathKeys()
	}
	
	public func mergeIgnoreCache(_ localCache: [String: Bool]) {
		ignoreCacheStore.mergeIgnoreCache(localCache)
	}
	
	public func mergeIgnoreCache(_ localCache: [IgnoreCacheStore.PathKey: Bool]) {
		guard !localCache.isEmpty else { return }
		ignoreCacheStore.mergeIgnoreCache(localCache)
	}
	
	// MARK: - Parallel scanning support
	
	/// Result of scanning a single folder (Sendable for cross-task usage)
	private struct ScanResult: Sendable {
		let folderRel: String
		let children: [String: Bool]  // relPath -> isDirectory
		let ignoreFiles: (hasGitignore: Bool, hasRepoIgnore: Bool, hasCursorignore: Bool)
	}
	
	/// Heavy I/O operation that runs outside the actor for parallelism.
	/// Uses POSIX opendir/readdir for better performance than FileManager.contentsOfDirectory.
	private static func enumerateOneLevel(
		absFolder: String,
		relFolder: String,
		skipSymlinks: Bool,
		rules: IgnoreRulesSnapshot,
		preserveChildren: Set<String> = []
	) throws -> ScanResult {
		// Use the lightweight POSIX-based directory scanner
		let scan: DirectoryScanResult
		do {
			scan = try listDirectoryWithIgnoreDetection(absFolder)
		} catch {
			// Return empty result for non-existent or inaccessible paths
			return ScanResult(
				folderRel: relFolder,
				children: [:],
				ignoreFiles: (false, false, false)
			)
		}
		
		var children = [String: Bool]()
		children.reserveCapacity(scan.entries.count)
		
		for entry in scan.entries {
			let name = entry.name
			
			// Skip control directories
			if name == ".git" { continue }
			if Self.isRepoPromptTempFilename(name) { continue }
			
			let childRel = relFolder.isEmpty ? name : "\(relFolder)/\(name)"
			let isDirEntry = entry.isDir
			
			// Skip directory symlinks if configured
			if entry.isSym && skipSymlinks && isDirEntry {
				continue
			}
			
			// Apply ignore rules - but preserve tracked files for this folder
			let requiresTraversal = isDirEntry && rules.requiresTraversal(for: childRel)
			let isIgnored = rules.isIgnored(relativePath: childRel, isDirectory: isDirEntry)
			
			if isIgnored && !preserveChildren.contains(childRel) && !requiresTraversal {
				continue
			}
			
			children[childRel] = isDirEntry
		}
		
		return ScanResult(
			folderRel: relFolder,
			children: children,
			ignoreFiles: (
				hasGitignore: scan.hasGitignore,
				hasRepoIgnore: scan.hasRepoIgnore,
				hasCursorignore: scan.hasCursorignore
			)
		)
	}
	
	/// Scan multiple folders in parallel for better I/O performance.
	/// Uses configurable caps to prevent CPU saturation.
	private func scanFoldersInParallel(_ folders: Set<String>) async throws -> [FileSystemDelta] {
		guard !folders.isEmpty else { return [] }
		
		// In test mode, always use serial scanning to avoid thread safety issues with SpyFS
		#if DEBUG
		if isTestMode {
			var deltas: [FileSystemDelta] = []
			for folder in folders {
				let folderDeltas = try await scanOneLevelAndDiff(folder)
				deltas.append(contentsOf: folderDeltas)
			}
			return deltas
		}
		#endif
		
		// Apply batch cap to limit per-tick work in high-churn scenarios
		let cappedFolders: Set<String>
		if folders.count > maxFoldersPerBatch {
			// Take a subset; remaining folders will be picked up in subsequent batches
			cappedFolders = Set(folders.prefix(maxFoldersPerBatch))
		} else {
			cappedFolders = folders
		}
		
		// For small sets, just use serial scanning
		if cappedFolders.count <= 2 {
			var deltas: [FileSystemDelta] = []
			for folder in cappedFolders {
				let folderDeltas = try await scanOneLevelAndDiff(folder)
				deltas.append(contentsOf: folderDeltas)
			}
			return deltas
		}
		
		// Use parallel scanning for larger sets with BOUNDED CONCURRENCY
		var aggregatedDeltas = [FileSystemDelta]()
		
		// Use configured parallelism cap (prevents CPU saturation)
		let maxParallel = min(cappedFolders.count, maxParallelScansPerActor)
		
		let targetParents = cappedFolders
		var preservedChildrenByFolder: [String: Set<String>] = [:]
		preservedChildrenByFolder.reserveCapacity(targetParents.count)
		for path in self.visitedPaths {
			let parent = self.parentDirectory(of: path)
			if targetParents.contains(parent) {
				preservedChildrenByFolder[parent, default: []].insert(path)
			}
		}
		
		var folderIterator = cappedFolders.makeIterator()
		var inFlight = 0

		// Capture ignoreRules before entering the task group to avoid actor isolation issues
		let fallbackRules = self.ignoreRules.snapshot()
		
		try await withThrowingTaskGroup(of: ScanResult.self) { group in
			// Helper to schedule tasks up to maxParallel
			// Note: captures must be resolved before the closure to avoid actor isolation issues
			func scheduleMoreTasks() {
				while inFlight < maxParallel, let folderRel = folderIterator.next() {
					// Capture everything we need before going off-actor
					let absFolder = getFullPath(forRelativePath: folderRel)
					let rulesForFolder = perFolderIgnoreCache[folderRel]?.snapshot() ?? fallbackRules
					let skipLinks = self.skipSymlinks
					let preservedChildren = preservedChildrenByFolder[folderRel] ?? Set<String>()
					
					inFlight += 1
					group.addTask(priority: .utility) {
						// This runs outside the actor for true parallelism
						return try Self.enumerateOneLevel(
							absFolder: absFolder,
							relFolder: folderRel,
							skipSymlinks: skipLinks,
							rules: rulesForFolder,
							preserveChildren: preservedChildren
						)
					}
				}
			}
			
			// Prime with initial batch
			scheduleMoreTasks()
			
			// Process results as they complete
			for try await scan in group {
				inFlight -= 1  // Decrement as result arrives
				
				// Back inside actor context - safe to mutate state
				let actualSet = Set(scan.children.keys)
				let oldSet = preservedChildrenByFolder[scan.folderRel] ?? Set<String>()
				
				let newItems = actualSet.subtracting(oldSet)
				let removedItems = oldSet.subtracting(actualSet)
				
			// Generate deltas for new items
			for newItem in newItems {
				// Skip newly discovered ignore files
				if isIgnoreFile(newItem) {
					continue
				}
				let isDir = scan.children[newItem] ?? false
					visitedPaths.insert(newItem)
					visitedItems[newItem] = isDir
					
				if isDir {
					aggregatedDeltas.append(.folderAdded(newItem))
					// If this folder is already queued for its own scan, avoid duplicate subtree walk.
					let hasPendingScan = pendingScanTargets[newItem] != nil
					if !hasPendingScan {
						let deeperDeltas = try await scanSubtreeForNewFolder(newItem)
						aggregatedDeltas.append(contentsOf: deeperDeltas)
					}
				} else {
						aggregatedDeltas.append(.fileAdded(newItem))
					}
				}
				
				// Generate deltas for removed items
				for removedItem in removedItems {
					let wasDir = visitedItems[removedItem] ?? false
					visitedPaths.remove(removedItem)
					visitedItems.removeValue(forKey: removedItem)
					
					if wasDir {
						aggregatedDeltas.append(.folderRemoved(removedItem))
						let subtreeDeltas = removeSubtree(for: removedItem)
						aggregatedDeltas.append(contentsOf: subtreeDeltas)
					} else {
						aggregatedDeltas.append(.fileRemoved(removedItem))
					}
				}
				
				// Schedule more tasks to fill the slot (sliding window)
				scheduleMoreTasks()
			}
		}
		
		return aggregatedDeltas
	}
	
	// MARK: - Single-level scanning & removal
	
	private func scanOneLevelAndDiff(_ folderRelPath: String) async throws -> [FileSystemDelta] {
		let fm = self.fm  // Cache for multiple calls in this method
		let absFolder = getFullPath(forRelativePath: folderRelPath)
		var isDir: ObjCBool = false
		let folderExists = fm.fileExists(atPath: absFolder, isDirectory: &isDir)
		
		// 1) If missing or not a directory => remove entire subtree
		if !folderExists || !isDir.boolValue {
			return removeSubtree(for: folderRelPath)
		}
		
		// 2) Single-level listing using POSIX directory scanning
#if DEBUG
		let scanResult = try Self.listDirectoryWithIgnoreDetection(absFolder, fm: self.fm)
#else
		let scanResult = try Self.listDirectoryWithIgnoreDetection(absFolder)
		#endif
		
		let parentRules = folderRelPath.isEmpty
			? ignoreRules
			: (perFolderIgnoreCache[parentDirectory(of: folderRelPath)] ?? ignoreRules)
		
		let effectiveRules: IgnoreRules
		if enableHierarchicalIgnores {
			effectiveRules = try await ensureRulesChain(for: folderRelPath, using: scanResult)
		} else {
			effectiveRules = parentRules
		}
		
		let globalCacheSnapshot = snapshotIgnoreCacheWithPathKeys()
		var deltaCache: [IgnoreCacheStore.PathKey: Bool] = [:]
		var actualChildren: [String] = []
		actualChildren.reserveCapacity(scanResult.entries.count)
		var childIsDir: [String: Bool] = [:]
		childIsDir.reserveCapacity(scanResult.entries.count)
		
		for entry in scanResult.entries {
			let name = entry.name
			// Never traverse or track .git, regardless of rules.
			if name == ".git" { continue }
			
			let childRel = folderRelPath.isEmpty ? name : "\(folderRelPath)/\(name)"
			let comps = pathCompsCache.components(for: childRel)
			let isDirEntry = entry.isDir
			if entry.isSym && skipSymlinks && isDirEntry {
				continue
			}
			var ignoredAsDir = false
			if isDirEntry {
				ignoredAsDir = IgnoreCacheStore.isIgnored(
					components: comps,
					isDirectory: true,
					readOnlyBase: globalCacheSnapshot,
					localCache: &deltaCache,
					ignoreRules: effectiveRules
				)
			}
			
			let ignoredForItem: Bool
			if isDirEntry {
				ignoredForItem = ignoredAsDir
			} else {
				ignoredForItem = IgnoreCacheStore.isIgnored(
					components: comps,
					isDirectory: false,
					readOnlyBase: globalCacheSnapshot,
					localCache: &deltaCache,
					ignoreRules: effectiveRules
				)
			}
			
			let requiresTraversal = isDirEntry && effectiveRules.requiresTraversal(for: childRel)
			
			if ignoredForItem && !visitedPaths.contains(childRel) && !requiresTraversal {
				continue
			}
			
			actualChildren.append(childRel)
			childIsDir[childRel] = isDirEntry
		}
		
		mergeIgnoreCache(deltaCache)
		
		let actualSet = Set(actualChildren)
		let oldSet = visitedPaths.filter { parentDirectory(of: $0) == folderRelPath }
		
		let newItems = actualSet.subtracting(oldSet)
		let removedItems = oldSet.subtracting(actualSet)
		
		var deltas: [FileSystemDelta] = []
		
		// 3) Handle new items
		for newItem in newItems {
			// Skip newly discovered ignore files - they'll come through FSEvents
			if isIgnoreFile(newItem) {
				continue
			}
			
			let isDir = childIsDir[newItem] ?? fileOrFolderIsDir(newItem)
			visitedPaths.insert(newItem)
			visitedItems[newItem] = isDir
			
			if isDir {
				deltas.append(.folderAdded(newItem))
				
				// Recursively load everything inside this newly added folder unless it is already queued.
				let hasPendingScan = pendingScanTargets[newItem] != nil
				if !hasPendingScan {
					let deeperDeltas = try await scanSubtreeForNewFolder(newItem)
					if !deeperDeltas.isEmpty {
						deltas.append(contentsOf: deeperDeltas)
					}
				}
				
			} else {
				deltas.append(.fileAdded(newItem))
			}
		}
		
		// 4) Handle removed items
		for removedItem in removedItems {
			let wasDir = visitedItems[removedItem] ?? false
			visitedPaths.remove(removedItem)
			visitedItems.removeValue(forKey: removedItem)
			
			if wasDir {
				deltas.append(.folderRemoved(removedItem))
				let subtreeDeltas = removeSubtree(for: removedItem)
				deltas.append(contentsOf: subtreeDeltas)
			} else {
				deltas.append(.fileRemoved(removedItem))
			}
		}
		
		return deltas
	}
	
	/// Recursively enumerates everything in a newly discovered folder, creating .fileAdded / .folderAdded deltas.
	private func scanSubtreeForNewFolder(_ folderRelPath: String) async throws -> [FileSystemDelta] {
		let absFolder = getFullPath(forRelativePath: folderRelPath)
		let subtreeItems = try await gatherPathsUsingEnumerator(
			rootURL: URL(fileURLWithPath: absFolder),
			skipSymlinks: skipSymlinks,
			baseRelativePath: folderRelPath
		)
		
		var subDeltas: [FileSystemDelta] = []
		
		for (subRelPath, isDir) in subtreeItems {
			let fullRel = folderRelPath.isEmpty
			? subRelPath
			: (folderRelPath + "/" + subRelPath)
			
			if visitedPaths.contains(fullRel) {
				continue
			}
			visitedPaths.insert(fullRel)
			visitedItems[fullRel] = isDir
			
			if isDir {
				subDeltas.append(.folderAdded(fullRel))
			} else {
				subDeltas.append(.fileAdded(fullRel))
			}
		}
		
		return subDeltas
	}
	
	/// Removes an entire subtree for a given folder from visitedPaths. Returns .fileRemoved / .folderRemoved deltas.
	private func removeSubtree(for topRelPath: String) -> [FileSystemDelta] {
		let oldSet = visitedPaths.filter {
			$0 == topRelPath || $0.hasPrefix(topRelPath + "/")
		}
		let sortedPaths = oldSet.sorted { $0.count > $1.count } // deeper items first
		var deltas: [FileSystemDelta] = []
		
		for path in sortedPaths {
			let wasDir = visitedItems[path] ?? false
			visitedPaths.remove(path)
			visitedItems.removeValue(forKey: path)
			if wasDir {
				deltas.append(.folderRemoved(path))
			} else {
				deltas.append(.fileRemoved(path))
			}
		}
		return deltas
	}
	
	// MARK: - File and folder manipulation utilities

	/// Atomically move/rename a **file** inside the same root.
	public func moveFile(atRelativePath oldRelPath: String,
					toRelativePath newRelPath: String) async throws {
		let fm = self.fm  // Cache for multiple calls in this method
		
		// --- prepare -----------------------------------------------------
		// ── 0. Validate that both paths are *relative* to `self.path` ──────────
		guard !oldRelPath.hasPrefix("/"),
				!newRelPath.hasPrefix("/") else {
			throw FileSystemError.invalidRelativePath
		}
		
		let oldFull = getFullPath(forRelativePath: oldRelPath)
		let newFull = getFullPath(forRelativePath: newRelPath)
		
		// 1) Source must exist
		guard fm.fileExists(atPath: oldFull, isDirectory: nil) else {
			throw FileSystemError.fileNotFound
		}
		
		// 2) Destination must not exist
		guard !fm.fileExists(atPath: newFull, isDirectory: nil) else {
			throw FileSystemError.fileAlreadyExists
		}
		
		// 3) Ensure parent folder exists (this is fast, keep it in-actor)
		let destDir = (newFull as NSString).deletingLastPathComponent
		try fm.createDirectory(atPath: destDir,
										withIntermediateDirectories: true,
										attributes: nil)
		
		// --- 1. do I/O off-actor ----------------------------------------
		// 4) Perform the move on disk
		do {
			try await Task.detached(priority: .utility) {
				try FileManager.default.moveItem(atPath: oldFull, toPath: newFull)
			}.value                                    // bubbles error
		} catch {
			throw FileSystemError.failedToCreateFile(error)
		}
		
		// --- 2. in-memory bookkeeping (still inside actor) --------------
		// 5) Immediate in‑memory bookkeeping (fixes race window) ───────────────
		let stdOld = (oldRelPath as NSString).standardizingPath
		let stdNew = (newRelPath as NSString).standardizingPath
		
		if let wasDir = visitedItems.removeValue(forKey: stdOld) {
			visitedItems[stdNew] = wasDir          // will be 'false' for files
		}
		visitedPaths.remove(stdOld)
		visitedPaths.insert(stdNew)
		
		// Transfer encoding if we have it
		if let encoding = encodingMap[stdOld] {
			encodingMap.removeValue(forKey: stdOld)
			encodingMap[stdNew] = encoding
		}
		
		// 6) Emit synthetic deltas so the UI updates before FSEvents arrive
		changePublisher.send([.fileRemoved(stdOld), .fileAdded(stdNew)])
	}
	// </add>
	public func loadContentsInChunks(
		of folderURL: URL,
		chunkSize: Int = 200
	) -> AsyncThrowingStream<LoadContentsEvent, Error> {
		AsyncThrowingStream { continuation in
			let loadingTask = Task {
				do {
					try Task.checkCancellation()

					#if DEBUG
					IgnoreDebugMetricsRecorder.resetAndDumpSnapshotIfEnabled(label: "load-start:\(folderURL.standardizedFileURL.path)")
					#endif

					var firstReportedCount: Int?
					var lastEmittedCount: Int?

					let finalTotal = try await walkPosixRecursivelyEmitChunks(
						baseURL: folderURL,
						parentRules: ignoreRules,
						chunkSize: chunkSize
					) { chunk, cumulativeCount in
						if firstReportedCount == nil {
							firstReportedCount = cumulativeCount
							lastEmittedCount = cumulativeCount
							continuation.yield(.totalFileCount(cumulativeCount))
						}
						continuation.yield(.preparedItems(chunk))
					}

					if firstReportedCount == nil {
						continuation.yield(.totalFileCount(finalTotal))
					} else if lastEmittedCount != finalTotal {
						continuation.yield(.totalFileCount(finalTotal))
					}

					#if DEBUG
					IgnoreDebugMetricsRecorder.dumpSnapshotIfEnabled(label: "load-finish:\(folderURL.standardizedFileURL.path)")
					#endif

					continuation.finish()
				} catch is CancellationError {
					continuation.finish(throwing: CancellationError())
				} catch {
					continuation.finish(throwing: error)
				}
			}

			continuation.onTermination = { _ in
				loadingTask.cancel()
			}
		}
	}
	
	/// Load the entire tree (recursively) as an AsyncThrowingStream of items, respecting skipSymlinks & ignore rules.
	private func loadContents(of folder: URL) -> AsyncThrowingStream<(any FileSystemItem, [String]), Error> {
		AsyncThrowingStream { continuation in
			let streamingTask = Task {
				do {
					let rootFullPath = folder.standardizedFileURL.path
					let stream = loadContentsInChunks(of: folder, chunkSize: 200)
					for try await event in stream {
						switch event {
						case .preparedItems(let chunk):
							for folderDTO in chunk.folders {
								let components = folderDTO.relativePath.split(separator: "/").map(String.init)
								let folderItem = Folder(
									name: components.last ?? folderDTO.relativePath,
									path: Self.joinRootAndRelative(root: rootFullPath, relative: folderDTO.relativePath),
									modificationDate: .distantPast
								)
								continuation.yield((folderItem, components))
							}
							for fileDTO in chunk.files {
								let components = fileDTO.relativePath.split(separator: "/").map(String.init)
								let fileItem = File(
									name: components.last ?? fileDTO.relativePath,
									path: Self.joinRootAndRelative(root: rootFullPath, relative: fileDTO.relativePath),
									modificationDate: .distantPast
								)
								continuation.yield((fileItem, components))
							}
						case .items(let legacy):
							for item in legacy {
								continuation.yield(item)
							}
						case .totalFileCount:
							continue
						}
					}
					continuation.finish()
				} catch is CancellationError {
					continuation.finish(throwing: CancellationError())
				} catch {
					continuation.finish(throwing: error)
				}
			}

			continuation.onTermination = { _ in
				streamingTask.cancel()
			}
		}
	}

	private final class DirChain: @unchecked Sendable {
		let id: DirID
		let parent: DirChain?
		
		init(_ id: DirID, parent: DirChain?) {
			self.id = id
			self.parent = parent
		}
		
		func contains(_ needle: DirID) -> Bool {
			var node: DirChain? = self
			while let current = node {
				if current.id == needle { return true }
				node = current.parent
			}
			return false
		}
	}
	
	private struct DirectoryContext: Sendable {
		let absPath: String
		let relPath: String
		let hierarchy: Int
		let rules: IgnoreRulesSnapshot
		let chain: DirChain?
	}

	private struct DirectoryChunkResult: Sendable {
		let folders: [FSItemDTO]
		let files: [FSItemDTO]
		let subdirs: [DirectoryContext]
		let ignoreCacheDelta: [IgnoreCacheStore.PathKey: Bool]
	}
	
	private static func buildDirectoryChunk(
		service: FileSystemService,
		context: DirectoryContext,
		scanResult: DirectoryScanResult,
		skipSymlinks: Bool,
		enableHierarchicalIgnores: Bool,
		respectGitignore: Bool,
		respectRepoIgnore: Bool,
		respectCursorignore: Bool,
		trackCycles: Bool
	) async throws -> DirectoryChunkResult {
		let effectiveRulesSnapshot: IgnoreRulesSnapshot
		if enableHierarchicalIgnores {
			let hasGitignore = scanResult.hasGitignore && respectGitignore
			let hasRepoIgnore = scanResult.hasRepoIgnore && respectRepoIgnore
			let hasCursorignore = scanResult.hasCursorignore && respectCursorignore
			if hasGitignore || hasRepoIgnore || hasCursorignore {
				let dirURL = URL(fileURLWithPath: context.absPath)
				effectiveRulesSnapshot = try await service.getEffectiveRulesSnapshot(
					for: dirURL,
					parentRelPath: context.relPath,
					hasGitignore: hasGitignore,
					hasRepoIgnore: hasRepoIgnore,
					hasCursorignore: hasCursorignore
				)
			} else {
				do {
					try await service.markNoIgnoreFilesUsingCache(context.relPath)
				} catch {
					// Best-effort: skip caching if the ignore chain can't be ensured.
				}
				effectiveRulesSnapshot = context.rules
			}
		} else {
			effectiveRulesSnapshot = context.rules
		}

		var folders: [FSItemDTO] = []
		folders.reserveCapacity(scanResult.entries.count)
		var files: [FSItemDTO] = []
		files.reserveCapacity(scanResult.entries.count)
		var subdirs: [DirectoryContext] = []
		subdirs.reserveCapacity(scanResult.entries.count)
		var localCache: [IgnoreCacheStore.PathKey: Bool] = [:]
		var componentsCache = PathComponentsCache()

		for entry in scanResult.entries {
			let name = entry.name
			if name == ".git" { continue }
			if Self.isRepoPromptTempFilename(name) { continue }
			let relativePath = context.relPath.isEmpty ? name : "\(context.relPath)/\(name)"
			guard !relativePath.isEmpty else { continue }
			let hierarchy = context.hierarchy + 1
			let comps = componentsCache.components(for: relativePath)
			let isDirEntry = entry.isDir
			let absolutePath = Self.joinRootAndRelative(root: context.absPath, relative: name)

			var ignoredAsDir = false
			if isDirEntry {
				ignoredAsDir = IgnoreCacheStore.isIgnored(
					components: comps,
					isDirectory: true,
					ignoreRules: effectiveRulesSnapshot,
					localCache: &localCache
				)
			}

			let ignoredForItem: Bool
			if isDirEntry {
				ignoredForItem = ignoredAsDir
			} else {
				ignoredForItem = IgnoreCacheStore.isIgnored(
					components: comps,
					isDirectory: false,
					ignoreRules: effectiveRulesSnapshot,
					localCache: &localCache
				)
			}

			let requiresTraversal = isDirEntry && effectiveRulesSnapshot.requiresTraversal(for: relativePath)

			if ignoredForItem && !requiresTraversal {
				continue
			}

			if isDirEntry {
				if entry.isSym && skipSymlinks { continue }

				folders.append(
					FSItemDTO(
						relativePath: relativePath,
						isDirectory: true,
						hierarchy: hierarchy
					)
				)

				if trackCycles {
					guard let id = Self.dirID(followingSymlinksAtPath: absolutePath) else {
						continue
					}
					if let chain = context.chain, chain.contains(id) {
						continue
					}
					let childChain = DirChain(id, parent: context.chain)
					subdirs.append(
						DirectoryContext(
							absPath: absolutePath,
							relPath: relativePath,
							hierarchy: hierarchy,
							rules: effectiveRulesSnapshot,
							chain: childChain
						)
					)
				} else {
					subdirs.append(
						DirectoryContext(
							absPath: absolutePath,
							relPath: relativePath,
							hierarchy: hierarchy,
							rules: effectiveRulesSnapshot,
							chain: nil
						)
					)
				}
			} else {
				files.append(
					FSItemDTO(
						relativePath: relativePath,
						isDirectory: false,
						hierarchy: hierarchy
					)
				)
			}
		}

		return DirectoryChunkResult(
			folders: folders,
			files: files,
			subdirs: subdirs,
			ignoreCacheDelta: localCache
		)
	}

	@inline(__always)
	private static func joinRootAndRelative(root: String, relative: String) -> String {
		guard !relative.isEmpty else { return root }
		if root.isEmpty {
			return relative
		}
		if root.hasSuffix("/") {
			return root + relative
		}
		return root + "/" + relative
	}


	private func walkPosixRecursivelyEmitChunks(
		baseURL: URL,
		parentRules: IgnoreRules,
		chunkSize: Int,
		yield: @escaping (FSPreparedChunk, Int) -> Void
	) async throws -> Int {
		let rootFullPath = folderURLRootPath(baseURL)
		let skipSymlinks = self.skipSymlinks
		let rootChain: DirChain?
		#if DEBUG
		let isVirtualFS = isTestMode && !(fm is FileManager)
		if isVirtualFS || skipSymlinks {
			rootChain = nil
		} else if let rootID = Self.dirID(followingSymlinksAtPath: rootFullPath) {
			rootChain = DirChain(rootID, parent: nil)
		} else {
			rootChain = nil
		}
		#else
		if skipSymlinks {
			rootChain = nil
		} else if let rootID = Self.dirID(followingSymlinksAtPath: rootFullPath) {
			rootChain = DirChain(rootID, parent: nil)
		} else {
			rootChain = nil
		}
		#endif
		var directories: [DirectoryContext] = [
			DirectoryContext(
				absPath: rootFullPath,
				relPath: "",
				hierarchy: -1,
				rules: parentRules.snapshot(),
				chain: rootChain
			)
		]

		var chunkFolders: [FSItemDTO] = []
		chunkFolders.reserveCapacity(chunkSize)
		var chunkFiles: [FSItemDTO] = []
		chunkFiles.reserveCapacity(chunkSize)
		var pendingFileCount = 0
		var totalFilesSeen = 0

		@inline(__always)
		func flush(force: Bool = false) {
			guard !chunkFolders.isEmpty || !chunkFiles.isEmpty else { return }
			if !force && (chunkFolders.count + chunkFiles.count) < chunkSize { return }
			let newlyCounted = pendingFileCount
			totalFilesSeen += newlyCounted
			let chunk = FSPreparedChunk(folders: chunkFolders, files: chunkFiles)
			chunkFolders.removeAll(keepingCapacity: true)
			chunkFiles.removeAll(keepingCapacity: true)
			pendingFileCount = 0
			yield(chunk, totalFilesSeen)
		}

		// Use configured parallelism cap for consistent behavior across all scan paths
		let maxConcurrent = maxParallelScansPerActor

		while !directories.isEmpty {
			try Task.checkCancellation()

			let batch = Array(directories.prefix(maxConcurrent))
			directories.removeFirst(batch.count)

			let enableHierarchicalIgnores = self.enableHierarchicalIgnores
			let respectGitignore = self.respectGitignore
			let respectRepoIgnore = self.respectRepoIgnore
			let respectCursorignore = self.respectCursorignore

			// The task-group body is a `sending` closure, so it must not capture
			// the batch accumulators (`chunkFolders`/`chunkFiles`/
			// `pendingFileCount`/`totalFilesSeen`), the `directories` worklist,
			// or the non-Sendable `yield` closure — those are all used again
			// after the group returns. Collect the child results inside the
			// group (capturing only `self` and Sendable values) and apply them
			// on the actor afterwards.
			//
			// Completion order is preserved: `for try await result in group`
			// still yields in completion order and `batchResults` is appended
			// in that same order, so on the SUCCESS path the sequence of
			// visited-path updates, ignore-cache merges, worklist growth and
			// `flush()` calls is exactly what it was. Two differences are real
			// and deliberate:
			//
			//  1. The group fully drains before any result is applied, which
			//     removes the window where actor re-entrancy could observe a
			//     half-applied chunk — but it also defers every `flush()` in a
			//     batch to the end of that batch rather than emitting them as
			//     children complete.
			//  2. On the THROWING path the batch is now all-or-nothing.
			//     Previously a child that threw left the already-applied
			//     results of its completed siblings in place (and their chunks
			//     already yielded); now the throw propagates out of
			//     `withThrowingTaskGroup` before `batchResults` is consumed, so
			//     those sibling results are discarded. The error still
			//     propagates to the same caller either way, and a partially
			//     applied batch was never a state any caller relied on — but it
			//     is a behavior change, not an equivalence.
			let batchResults: [DirectoryChunkResult] = try await withThrowingTaskGroup(
				of: DirectoryChunkResult.self
			) { group in
				for context in batch {
					#if DEBUG
					group.addTask { [self,
						context,
						isVirtualFS,
						skipSymlinks,
						enableHierarchicalIgnores,
						respectGitignore,
						respectRepoIgnore,
						respectCursorignore
					] in
						try await Self.processDirectoryOffActor(
							service: self,
							context: context,
							isVirtualFS: isVirtualFS,
							skipSymlinks: skipSymlinks,
							enableHierarchicalIgnores: enableHierarchicalIgnores,
							respectGitignore: respectGitignore,
							respectRepoIgnore: respectRepoIgnore,
							respectCursorignore: respectCursorignore
						)
					}
					#else
					group.addTask { [self,
						context,
						skipSymlinks,
						enableHierarchicalIgnores,
						respectGitignore,
						respectRepoIgnore,
						respectCursorignore
					] in
						try await Self.processDirectoryOffActor(
							service: self,
							context: context,
							skipSymlinks: skipSymlinks,
							enableHierarchicalIgnores: enableHierarchicalIgnores,
							respectGitignore: respectGitignore,
							respectRepoIgnore: respectRepoIgnore,
							respectCursorignore: respectCursorignore
						)
					}
					#endif
				}

				var collected: [DirectoryChunkResult] = []
				collected.reserveCapacity(batch.count)
				for try await result in group {
					collected.append(result)
				}
				return collected
			}

			for result in batchResults {
				if !result.folders.isEmpty || !result.files.isEmpty {
					chunkFolders.append(contentsOf: result.folders)
					chunkFiles.append(contentsOf: result.files)
					pendingFileCount += result.files.count

					for folder in result.folders {
						visitedPaths.insert(folder.relativePath)
						visitedItems[folder.relativePath] = true
					}
					for file in result.files {
						visitedPaths.insert(file.relativePath)
						visitedItems[file.relativePath] = false
					}

					flush()
				}

				if !result.subdirs.isEmpty {
					directories.append(contentsOf: result.subdirs)
				}

				if !result.ignoreCacheDelta.isEmpty {
					mergeIgnoreCache(result.ignoreCacheDelta)
				}
			}
		}

		flush(force: true)
		return totalFilesSeen
	}
	
#if DEBUG
	private func gatherPathsUsingVirtualFS(
		rootURL: URL,
		baseRelativePath: String,
		fs: any TestFS,
		skipSymlinks: Bool
	) throws -> [String: Bool] {
		var results = [String: Bool]()
		
		func recurse(currentURL: URL, subtreeRelativePath: String) throws {
			let children = try fs.contentsOfDirectory(
				at: currentURL,
				includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
				options: []
			)
			
			for url in children {
				let name = url.lastPathComponent
				if name == "." || name == ".." { continue }
				if Self.isRepoPromptTempFilename(name) { continue }
				
				var isDirFlag: ObjCBool = false
				_ = fs.fileExists(atPath: url.path, isDirectory: &isDirFlag)
				
				let isSym = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
				if skipSymlinks && isDirFlag.boolValue && isSym {
					continue
				}
				
				let relativeWithinSubtree = subtreeRelativePath.isEmpty ? name : "\(subtreeRelativePath)/\(name)"
				let repositoryRelativePath = Self.joinRelativePaths(base: baseRelativePath, child: relativeWithinSubtree)
				
				let comps = pathCompsCache.components(for: repositoryRelativePath)
				let requiresTraversal = isDirFlag.boolValue && ignoreRules.requiresTraversal(for: repositoryRelativePath)
				if ignoreRules.isIgnored(relativePathComponents: comps, isDirectory: isDirFlag.boolValue) && !requiresTraversal {
					continue
				}
				
				results[relativeWithinSubtree] = isDirFlag.boolValue
				
				if isDirFlag.boolValue {
					try recurse(currentURL: url, subtreeRelativePath: relativeWithinSubtree)
				}
			}
		}
		
		try recurse(currentURL: rootURL, subtreeRelativePath: "")
		return results
	}
#endif

	#if DEBUG
	private static func processDirectoryOffActor(
		service: FileSystemService,
		context: DirectoryContext,
		isVirtualFS: Bool,
		skipSymlinks: Bool,
		enableHierarchicalIgnores: Bool,
		respectGitignore: Bool,
		respectRepoIgnore: Bool,
		respectCursorignore: Bool
	) async throws -> DirectoryChunkResult {
		let scanResult: DirectoryScanResult
		do {
			let testMode = await service.isTestMode
			if testMode, let fm = await service.fmTransfer.fileSystem {
				scanResult = try Self.listDirectoryWithIgnoreDetection(context.absPath, fm: fm)
			} else {
				scanResult = try Self.listDirectoryWithIgnoreDetection(context.absPath)
			}
		} catch {
			return DirectoryChunkResult(folders: [], files: [], subdirs: [], ignoreCacheDelta: [:])
		}

		let trackCycles = !skipSymlinks && !isVirtualFS
		return try await buildDirectoryChunk(
			service: service,
			context: context,
			scanResult: scanResult,
			skipSymlinks: skipSymlinks,
			enableHierarchicalIgnores: enableHierarchicalIgnores,
			respectGitignore: respectGitignore,
			respectRepoIgnore: respectRepoIgnore,
			respectCursorignore: respectCursorignore,
			trackCycles: trackCycles
		)
	}
	#else
	private static func processDirectoryOffActor(
		service: FileSystemService,
		context: DirectoryContext,
		skipSymlinks: Bool,
		enableHierarchicalIgnores: Bool,
		respectGitignore: Bool,
		respectRepoIgnore: Bool,
		respectCursorignore: Bool
	) async throws -> DirectoryChunkResult {
		let scanResult: DirectoryScanResult
		do {
			scanResult = try Self.listDirectoryWithIgnoreDetection(context.absPath)
		} catch {
			return DirectoryChunkResult(folders: [], files: [], subdirs: [], ignoreCacheDelta: [:])
		}

		let trackCycles = !skipSymlinks
		return try await buildDirectoryChunk(
			service: service,
			context: context,
			scanResult: scanResult,
			skipSymlinks: skipSymlinks,
			enableHierarchicalIgnores: enableHierarchicalIgnores,
			respectGitignore: respectGitignore,
			respectRepoIgnore: respectRepoIgnore,
			respectCursorignore: respectCursorignore,
			trackCycles: trackCycles
		)
	}
	#endif

	private func folderURLRootPath(_ folderURL: URL) -> String {
		folderURL.standardizedFileURL.path
	}

	/// Loads text-based content for `relativePath`, returning nil if file is recognized as binary or too large.
/// This is a simple entry point that chooses either single-shot read for small files or chunk-based read for large ones.
public func loadContent(ofRelativePath relativePath: String) async throws -> String? {
	// Early, no-IO short-circuit for known-binary extensions
	let relExt = ((relativePath as NSString).pathExtension).lowercased()
	if !relExt.isEmpty, Self.alwaysBinaryExtensions.contains(relExt) {
		return nil
	}

	let fm = self.fm  // Cache for multiple calls in this method
	let fullPath = getFullPath(forRelativePath: relativePath)
	guard fm.fileExists(atPath: fullPath, isDirectory: nil) else {
		throw FileSystemError.fileNotFound
	}

	let attrs    = try fm.attributesOfItem(atPath: fullPath)
	let fileSize = attrs[.size] as? Int64 ?? 0
	let url      = URL(fileURLWithPath: fullPath)
	let ext      = url.pathExtension.lowercased()

	// (1) Whitelist → skip binary probe entirely
	let skipProbe = Self.alwaysTextExtensions.contains(ext)
					|| (ext.isEmpty && Self.alwaysTextFilenames.contains(url.lastPathComponent.lowercased()))

	// (2) Optional heuristic probe on first 8 KB
	if !skipProbe {
		if let handle = try? FileHandle(forReadingFrom: url) {
			let probe = try handle.read(upToCount: 8_192) ?? Data()
			try? handle.close()
			if Self.isProbablyBinary(probe) { return nil }
		}
	}

	// (3) Small files – read once, detect encoding
	if fileSize < 2_000_000 {
		let detected = try readDataAndDetectEncoding(fullPath)
		encodingMap[relativePath] = detected.encoding
		return detected.string
	}

	// (4) Larger files – streamed read
	return try await loadEntireFileContentOptimized(
		ofRelativePath: relativePath,
		chunkSize:     1_048_576,   // 1 MB
		fileSizeLimit: 10_000_000   // 10 MB
	)
}
	
	/// For backward compatibility - delegates to the new implementation
	private func loadContent(of url: URL) async throws -> String? {
		let relativePath = url.relativePath(from: URL(fileURLWithPath: path))
		return try await loadContent(ofRelativePath: relativePath)
	}
	
	public func loadContentWithDate(ofRelativePath relativePath: String) async throws -> (content: String?, modificationDate: Date) {
		//let _ = getFullPath(forRelativePath: relativePath)
		async let content = loadContent(ofRelativePath: relativePath)
		async let modDate = getFileModificationDate(atRelativePath: relativePath)
		return try await (content, modDate)
	}
	
	/// Loads large files in chunks, detecting encoding on‑the‑fly.
	///
	/// Order of precedence:
	///   1. BOM (cheap, deterministic)
	///   2. Cuchardet’s streaming detector
	///   3. Default to UTF‑8          ← no further fall‑backs
	public func loadEntireFileContentOptimized(
		ofRelativePath relativePath: String,
		chunkSize: Int = 1_048_576,          // 1 MB
		fileSizeLimit: Int64 = 10_000_000    // 10 MB
	) async throws -> String? {
		// Early, no-IO short-circuit for known-binary extensions
		let relExt = ((relativePath as NSString).pathExtension).lowercased()
		if !relExt.isEmpty, Self.alwaysBinaryExtensions.contains(relExt) {
			return nil
		}

		let fm = self.fm  // Cache for multiple calls in this method
		
		let fullPath = getFullPath(forRelativePath: relativePath)
		guard fm.fileExists(atPath: fullPath, isDirectory: nil) else {
			throw FileSystemError.fileNotFound
		}
		
		// Size guard
		let attrs = try fm.attributesOfItem(atPath: fullPath)
		let fileSize = attrs[.size] as? Int64 ?? 0
		if fileSize > fileSizeLimit {
			return "[File too large: \(fileSize) bytes]"
		}
		
		let url  = URL(fileURLWithPath: fullPath)
		let ext  = url.pathExtension.lowercased()
		let skipProbe = Self.alwaysTextExtensions.contains(ext)
		|| (ext.isEmpty && Self.alwaysTextFilenames.contains(url.lastPathComponent.lowercased()))
		
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		
		var fullData = Data()
		fullData.reserveCapacity(Int(fileSize))
		
		let detector = charsetDetector.makeStreamingDetector()
		
		// First chunk
		let initialData = try handle.read(upToCount: chunkSize) ?? Data()
		if !skipProbe && Self.isProbablyBinary(initialData) { return nil }
		fullData.append(initialData)
		_ = detector.analyzeNextChunk(initialData)
		
		try Task.checkCancellation()
		
		// Subsequent chunks
		while true {
			let next = try handle.read(upToCount: chunkSize) ?? Data()
			if next.isEmpty { break }          // EOF
			fullData.append(next)
			_ = detector.analyzeNextChunk(next)
			
			if fullData.count > 100_000_000 {
				fullData.append("\n[Truncated large file...]\n".data(using: .utf8)!)
				break
			}
			try Task.checkCancellation()
		}
		
		// Resolve encoding
		let encoding: String.Encoding
		if let bom = Self.detectBOMEncoding(in: initialData) {
			encoding = bom
		} else if let label = detector.finish() {
			encoding = .init(ianaCharsetName: label)
		} else {
			encoding = .utf8           // no secondary heuristics
		}
		
		encodingMap[relativePath] = encoding
		return String(data: fullData, encoding: encoding) ?? "[Binary data or unknown encoding]"
	}
	
	/// Attempt to decode with all post‑UTF‑8 fall‑backs, including region‑specific ones.
	private func tryDecodeWithFallbackEncodings(_ data: Data) -> String? {
		for enc in Self.orderedFallbackEncodings + Self.regionSpecificEncodings {
			if let s = String(data: data, encoding: enc) { return s }
		}
		return nil
	}
	
/// Detect the most probable encoding from an initial data slice.
///
/// Fast-path order:
///   1. Byte-order-mark (BOM)
///   2. Cuchardet on the same bytes
///   3. Strict UTF-8
///   4. Western single-byte fall-backs
///   5. Heuristic UTF-16 without BOM
///   6. Region-specific legacies
public func detectEncodingForInitialChunk(initialData: Data) throws -> String.Encoding {
	guard !initialData.isEmpty else { return .utf8 }

	// 1) Honor BOM immediately
	if let bomEncoding = Self.detectBOMEncoding(in: initialData) {
		return bomEncoding
	}

	// 2) Injected library detector (fast – O(n) on the *same* bytes)
	if let label = charsetDetector.detectedCharacterEncodingLabel(for: initialData) {
		return .init(ianaCharsetName: label)
	}

	// 3) UTF-8 strict
	if String(data: initialData, encoding: .utf8) != nil {
		return .utf8
	}

	// 4) Western single-byte encodings
	for enc in Self.orderedFallbackEncodings where String(data: initialData, encoding: enc) != nil {
		return enc
	}

	// 5) Heuristic UTF-16 without BOM
	if Self.looksLikeUTF16(initialData) {
		for enc in [String.Encoding.utf16LittleEndian, .utf16BigEndian]
			where String(data: initialData, encoding: enc) != nil {
			return enc
		}
	}

	// 6) Region-specific encodings
	for enc in Self.regionSpecificEncodings where String(data: initialData, encoding: enc) != nil {
		return enc
	}

	// Fallback to UTF-8 with replacement
	return .utf8
}
	
	/// Example approach if you want a standalone data-based detection
	public func detectFileEncodingFromData(_ data: Data) async throws -> String.Encoding {
		// 1) BOM check
		if let bom = Self.detectBOMEncoding(in: data) { return bom }
		
		// 2) UTF‑8 strict
		if String(data: data, encoding: .utf8) != nil { return .utf8 }
		
		// 3–4) CP‑1252 / Mac Roman
		for enc in Self.orderedFallbackEncodings where String(data: data, encoding: enc) != nil {
			return enc
		}
		
		// 5) UTF‑16 heuristic without BOM
		if Self.looksLikeUTF16(data) {
			// fully qualify to String.Encoding
			for enc in [String.Encoding.utf16LittleEndian, String.Encoding.utf16BigEndian]
				where String(data: data, encoding: enc) != nil {
				return enc
			}
		}
		
		// 6) Region‑specific encodings
		for enc in Self.regionSpecificEncodings where String(data: data, encoding: enc) != nil {
			return enc
		}
		
		// Last‑resort default
		return .utf8
	}

	public func updateRespectGitignore(_ newValue: Bool) async throws {
		guard self.respectGitignore != newValue else { return }
		self.respectGitignore = newValue
		try await refreshIgnoreRules()
	}

	public func updateRespectRepoIgnore(_ newValue: Bool) async throws {
		guard self.respectRepoIgnore != newValue else { return }
		self.respectRepoIgnore = newValue
		try await refreshIgnoreRules()
	}

	public func updateRespectCursorignore(_ newValue: Bool) async throws {
		guard self.respectCursorignore != newValue else { return }
		self.respectCursorignore = newValue
		try await refreshIgnoreRules()
	}

	public func updateSkipSymlinks(_ newValue: Bool) {
		self.skipSymlinks = newValue
	}
	
	public func updateEnableHierarchicalIgnores(_ newValue: Bool) {
		guard self.enableHierarchicalIgnores != newValue else { return }
		self.enableHierarchicalIgnores = newValue
		invalidateAllIgnoreCaches()
		if !newValue {
			// Clear the per-folder cache when disabling
			Task { await rebuildPerFolderIgnoreCache() }
		}
	}
	
	public func refreshIgnoreRules() async throws {
		self.ignoreRules = try await IgnoreRulesManager.shared.getIgnoreRules(
			for: self.path,
			respectGitignore: self.respectGitignore,
			respectRepoIgnore: self.respectRepoIgnore,
			respectCursorignore: self.respectCursorignore
		)
		invalidateAllIgnoreCaches()
	}
	
	/// Create a new file at `relativePath` with the given content.
	public func createFile(atRelativePath relativePath: String, content: String) async throws {
		let fm = self.fm  // Cache for multiple calls in this method
		// --- prepare -----------------------------------------------------
		let fullPath = getFullPath(forRelativePath: relativePath)
		let fullURL = URL(fileURLWithPath: fullPath)
		
		// Ensure directory exists (this is fast, keep it in-actor)
		let directoryURL = fullURL.deletingLastPathComponent()
		try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
		
		// Check if file already exists
		if fm.fileExists(atPath: fullPath, isDirectory: nil) {
			throw FileSystemError.fileAlreadyExists
		}
		
		// Prepare data with UTF-8 encoding
		guard let data = content.data(using: .utf8) else {
			throw FileSystemError.failedToCreateFile(
				NSError(domain: "encoding", code: -1,
						userInfo: [NSLocalizedDescriptionKey: "Unable to encode text as UTF-8"]))
		}
		
		// --- 1. do I/O off-actor ----------------------------------------
		do {
			try await Task.detached(priority: .utility) {
				try FileSystemService.writeFileRobust(to: fullURL, data: data)
			}.value                                    // bubbles error
			fileSystemDebugLog("File created at \(fullURL.path)")
		} catch {
			throw FileSystemError.failedToCreateFile(error)
		}
		
		// --- 2. in-memory bookkeeping (still inside actor) --------------
		// update encoding cache (new files default to UTF-8)
		encodingMap[relativePath] = .utf8
		
		// update visited* sets
		if !visitedPaths.contains(relativePath) {
			visitedPaths.insert(relativePath)
			visitedItems[relativePath] = false
		}
		
		// emit a *synthetic* delta so the UI updates immediately
		changePublisher.send([.fileAdded(relativePath)])
	}
	
	@discardableResult
	public func deleteFile(atRelativePath relativePath: String) async throws -> [FileSystemDelta] {
		let normalizedRelativePath = Self.trimPathSlashes((relativePath as NSString).standardizingPath)
		guard !normalizedRelativePath.isEmpty,
			normalizedRelativePath != ".",
			!normalizedRelativePath.hasPrefix("../"),
			normalizedRelativePath != ".." else {
			throw FileSystemError.invalidRelativePath
		}
		let fullPath = getFullPath(forRelativePath: normalizedRelativePath)
		let url = URL(fileURLWithPath: fullPath)
		var isDirectory = ObjCBool(false)
		guard fm.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
			throw FileSystemError.fileNotFound
		}
		do {
			try fm.removeItem(at: url)
			fileSystemDebugLog("File deleted at \(url.path)")
		} catch {
			throw FileSystemError.failedToDeleteFile(error)
		}

		let keysToForget = encodingMap.keys.filter {
			$0 == normalizedRelativePath || $0.hasPrefix(normalizedRelativePath + "/")
		}
		for key in keysToForget {
			encodingMap.removeValue(forKey: key)
		}

		var deltas = removeSubtree(for: normalizedRelativePath)
		if deltas.isEmpty {
			deltas = [isDirectory.boolValue ? .folderRemoved(normalizedRelativePath) : .fileRemoved(normalizedRelativePath)]
		}
		if !deltas.isEmpty {
			changePublisher.send(deltas)
		}
		return deltas
	}
	
	@discardableResult
	public func moveItemToTrash(atRelativePath relativePath: String) async throws -> [FileSystemDelta] {
		guard !relativePath.hasPrefix("/") else {
			throw FileSystemError.invalidRelativePath
		}
		
		let normalizedRelativePath = Self.trimPathSlashes((relativePath as NSString).standardizingPath)
		guard !normalizedRelativePath.isEmpty,
			normalizedRelativePath != ".",
			!normalizedRelativePath.hasPrefix("../"),
			normalizedRelativePath != ".." else {
			throw FileSystemError.invalidRelativePath
		}
		
		let url = rootURL.appendingPathComponent(normalizedRelativePath).standardizedFileURL
		let fullPath = url.path
		guard fullPath != standardizedRootPath,
			hasDirectoryPrefix(fullPath, standardizedRootPath) else {
			throw FileSystemError.invalidRelativePath
		}
		
		var isDirectory = ObjCBool(false)
		guard fm.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
			throw FileSystemError.fileNotFound
		}
		
		do {
			_ = try moveURLToTrash(url)
			fileSystemDebugLog("File moved to Trash at \(url.path)")
		} catch {
			throw FileSystemError.failedToDeleteFile(error)
		}
		
		let keysToForget = encodingMap.keys.filter {
			$0 == normalizedRelativePath || $0.hasPrefix(normalizedRelativePath + "/")
		}
		for key in keysToForget {
			encodingMap.removeValue(forKey: key)
		}
		
		var deltas = removeSubtree(for: normalizedRelativePath)
		if deltas.isEmpty {
			deltas = [isDirectory.boolValue ? .folderRemoved(normalizedRelativePath) : .fileRemoved(normalizedRelativePath)]
		}
		if !deltas.isEmpty {
			changePublisher.send(deltas)
		}
		return deltas
	}
	
	private func moveURLToTrash(_ url: URL) throws -> URL? {
		#if DEBUG
		return try fm.moveItemToTrash(at: url)
		#else
		var resultingItemURL: NSURL?
		try fm.trashItem(at: url, resultingItemURL: &resultingItemURL)
		return resultingItemURL as URL?
		#endif
	}
	
	/// Re-written non-blocking version
	public func editFile(atRelativePath relativePath: String, newContent: String) async throws {
		// --- prepare -----------------------------------------------------
		let fullPath = getFullPath(forRelativePath: relativePath)
		let fullURL = URL(fileURLWithPath: fullPath)
		guard fm.fileExists(atPath: fullPath, isDirectory: nil) else {
			throw FileSystemError.fileNotFound
		}
		let enc = encodingMap[relativePath] ?? .utf8
		guard let data = newContent.data(using: enc) else {
			throw FileSystemError.failedToEditFile(
				NSError(domain: "encoding", code: -1,
						userInfo: [NSLocalizedDescriptionKey: "Unable to encode text as \(enc)"]))
		}
		
		// --- 1. do I/O off-actor ----------------------------------------
		do {
			try await Task.detached(priority: .utility) {
				try FileSystemService.writeFileRobust(to: fullURL, data: data)
			}.value                                    // bubbles error
		} catch {
			throw FileSystemError.failedToEditFile(error)
		}
		
		// --- 2. in-memory bookkeeping (still inside actor) --------------
		// refresh encoding cache
		encodingMap[relativePath] = enc
		
		// update visited* sets so later FSEvents don't look "new"
		if !visitedPaths.contains(relativePath) {
			visitedPaths.insert(relativePath)
			visitedItems[relativePath] = false
		}
		
		// emit a *synthetic* delta so the UI updates immediately, with mtime if available
		let mdate = try? await getFileModificationDate(atRelativePath: relativePath)
		changePublisher.send([.fileModified(relativePath, mdate)])
	}
	
	public func checkFilePermissions(atRelativePath relativePath: String) -> Bool {
		let fullPath = getFullPath(forRelativePath: relativePath)
		return fm.isWritableFile(atPath: fullPath)
	}
	
	public func getFileModificationDate(atRelativePath relativePath: String) async throws -> Date {
		let fullPath = getFullPath(forRelativePath: relativePath)
		let attributes = try fm.attributesOfItem(atPath: fullPath)
		return attributes[.modificationDate] as? Date ?? Date()
	}

	public func getItemModificationDateIfAvailable(atRelativePath relativePath: String) async -> Date? {
		let fullPath = getFullPath(forRelativePath: relativePath)
		guard let attributes = try? fm.attributesOfItem(atPath: fullPath) else { return nil }
		return attributes[.modificationDate] as? Date
	}
	
	// MARK: - Internal enumeration & helpers
	
	private func gatherPathsUsingEnumerator(
		rootURL: URL,
		skipSymlinks: Bool,
		baseRelativePath: String
	) async throws -> [String: Bool] {
		#if DEBUG
		if let overrideFS = fileManagerOverride, !(overrideFS is FileManager) {
			return try gatherPathsUsingVirtualFS(
				rootURL: rootURL,
				baseRelativePath: baseRelativePath,
				fs: overrideFS,
				skipSymlinks: skipSymlinks
			)
		}
		#endif
		
		let rootPath = rootURL.path
		#if DEBUG
		let isVirtualFS = isTestMode && !(fm is FileManager)
		if !isVirtualFS {
			let isSym = (try? rootURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
			if isSym && skipSymlinks {
				return [:]
			}
		}
		#else
		if skipSymlinks {
			let isSym = (try? rootURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
			if isSym {
				return [:]
			}
		}
		#endif
		let rootChain: DirChain?
		#if DEBUG
		if isVirtualFS || skipSymlinks {
			rootChain = nil
		} else {
			var chain: DirChain?
			if let rootID = Self.dirID(followingSymlinksAtPath: canonicalRootPath) {
				chain = DirChain(rootID, parent: nil)
			}
			if !baseRelativePath.isEmpty {
				var relSoFar = ""
				for component in baseRelativePath.split(separator: "/") {
					relSoFar = relSoFar.isEmpty ? String(component) : "\(relSoFar)/\(component)"
					let absPath = Self.joinRootAndRelative(root: self.path, relative: relSoFar)
					if let id = Self.dirID(followingSymlinksAtPath: absPath) {
						chain = DirChain(id, parent: chain)
					}
				}
			}
			rootChain = chain
		}
		#else
		if skipSymlinks {
			rootChain = nil
		} else {
			var chain: DirChain?
			if let rootID = Self.dirID(followingSymlinksAtPath: canonicalRootPath) {
				chain = DirChain(rootID, parent: nil)
			}
			if !baseRelativePath.isEmpty {
				var relSoFar = ""
				for component in baseRelativePath.split(separator: "/") {
					relSoFar = relSoFar.isEmpty ? String(component) : "\(relSoFar)/\(component)"
					let absPath = Self.joinRootAndRelative(root: self.path, relative: relSoFar)
					if let id = Self.dirID(followingSymlinksAtPath: absPath) {
						chain = DirChain(id, parent: chain)
					}
				}
			}
			rootChain = chain
		}
		#endif
		let enableHierarchicalIgnores = self.enableHierarchicalIgnores
		let respectGitignore = self.respectGitignore
		let respectRepoIgnore = self.respectRepoIgnore
		let respectCursorignore = self.respectCursorignore
		
		let parentRel = parentDirectory(of: baseRelativePath)
		let fallbackRules = ignoreRules.snapshot()
		let parentRulesSnapshot = perFolderIgnoreCache[parentRel]?.snapshot() ?? fallbackRules
		
		var directories: [DirectoryContext] = [
			DirectoryContext(
				absPath: rootPath,
				relPath: baseRelativePath,
				hierarchy: -1,
				rules: parentRulesSnapshot,
				chain: rootChain
			)
		]
		
		var results = [String: Bool]()
		let basePrefix = baseRelativePath.isEmpty ? "" : (baseRelativePath + "/")
		
		while let context = directories.popLast() {
			#if DEBUG
			let result = try await Self.processDirectoryOffActor(
				service: self,
				context: context,
				isVirtualFS: isVirtualFS,
				skipSymlinks: skipSymlinks,
				enableHierarchicalIgnores: enableHierarchicalIgnores,
				respectGitignore: respectGitignore,
				respectRepoIgnore: respectRepoIgnore,
				respectCursorignore: respectCursorignore
			)
			#else
			let result = try await Self.processDirectoryOffActor(
				service: self,
				context: context,
				skipSymlinks: skipSymlinks,
				enableHierarchicalIgnores: enableHierarchicalIgnores,
				respectGitignore: respectGitignore,
				respectRepoIgnore: respectRepoIgnore,
				respectCursorignore: respectCursorignore
			)
			#endif
			
			if !result.ignoreCacheDelta.isEmpty {
				mergeIgnoreCache(result.ignoreCacheDelta)
			}
			
			for folder in result.folders {
				let repoRelative = folder.relativePath
				let relativeWithinSubtree = basePrefix.isEmpty
					? repoRelative
					: (repoRelative.hasPrefix(basePrefix) ? String(repoRelative.dropFirst(basePrefix.count)) : repoRelative)
				if !relativeWithinSubtree.isEmpty {
					results[relativeWithinSubtree] = true
				}
			}
			
			for file in result.files {
				let repoRelative = file.relativePath
				let relativeWithinSubtree = basePrefix.isEmpty
					? repoRelative
					: (repoRelative.hasPrefix(basePrefix) ? String(repoRelative.dropFirst(basePrefix.count)) : repoRelative)
				if !relativeWithinSubtree.isEmpty {
					results[relativeWithinSubtree] = false
				}
			}
			
			if !result.subdirs.isEmpty {
				directories.append(contentsOf: result.subdirs)
			}
		}
		
		return results
	}
	
	private static func joinRelativePaths(base: String, child: String) -> String {
		if base.isEmpty { return child }
		if child.isEmpty { return base }
		return base + "/" + child
	}
	
	public func getCoreCount() -> Int {
		var count: Int32 = 0
		var size = MemoryLayout<Int32>.size
		sysctlbyname("hw.ncpu", &count, &size, nil, 0)
		return Int(count)
	}

	// MARK: - Binary detection helpers
	// ─────────────────────────────────────────────────────────────────────────────
	/// Binary detection heuristic (Git-style, UTF-8 tolerant)
	///
	/// • Any NUL byte → binary
	/// • Control bytes 0x00–0x1F **except** TAB/LF/CR
	/// • If ≥ 30 % of the bytes in the sample are control bytes → binary
	private static func isProbablyBinary(_ data: Data, sampleSize: Int = 8_192) -> Bool {
		guard !data.isEmpty else { return false }
		let sample = data.prefix(sampleSize)

		// Immediate NUL check
		if sample.contains(0) { return true }

		var ctrl = 0
		var printableOrUtf8 = 0

		for byte in sample {
			switch byte {
			case 0x09, 0x0A, 0x0D, 0x20...0x7E:           // HT, LF, CR, printable ASCII
				printableOrUtf8 += 1
			case 0x01...0x08, 0x0B...0x0C, 0x0E...0x1F:   // Other ASCII control chars
				ctrl += 1
			default:                                     // 0x80–0xFF → UTF-8 part or extended ASCII
				printableOrUtf8 += 1
			}
		}

		let total = ctrl + printableOrUtf8
		guard total > 0 else { return false }
		return Double(ctrl) / Double(total) > 0.30
	}

	// MARK: - Encoding detection helpers & priority tables
	/// Encodings to try **after** UTF‑8 fails, in the exact order mandated
	/// by the research note: Windows‑1252 → Mac Roman → UTF‑16 (LE/BE)
	private static let orderedFallbackEncodings: [String.Encoding] = [
		.windowsCP1252,
		.macOSRoman,
	]
	
	/// Optional, low‑priority locale‑specific single‑byte encodings
	private static let regionSpecificEncodings: [String.Encoding] = [
		.shiftJIS, .japaneseEUC, .iso2022JP,        // Japanese
		// Mainland‑China GB18030
		String.Encoding(rawValue:
			CFStringConvertEncodingToNSStringEncoding(
				CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
			)
		),
		// Traditional‑Chinese Big5
		String.Encoding(rawValue:
			CFStringConvertEncodingToNSStringEncoding(
				CFStringEncoding(CFStringEncodings.big5.rawValue)
			)
		),
		.windowsCP1251, .isoLatin2                  // Cyrillic / Central‑Europe
	]

	// MARK: - Extension / filename whitelists
	/// Extensions that are always treated as binary; we short-circuit before any filesystem queries.
	private static let alwaysBinaryExtensions: Set<String> = [
		// ── Video ───────────────────────────────────────────────────
		"mp4","m4v","mov","avi","mkv","webm","flv","wmv","mpeg","mpg","m2ts","mts","3gp","3g2","ogv",
		"asf","rm","rmvb","vob","ogm","f4v","mpe","m1v","m2v","divx","xvid","dv",
		// ── Audio ───────────────────────────────────────────────────
		"wav","aiff","aif","flac","ogg","oga","opus","m4a","aac","mp3","mid","midi","caf","ape","alac","dsf","dff",
		// ── Images ──────────────────────────────────────────────────
		"png","jpg","jpeg","gif","webp","tif","tiff","bmp","ico","icns","psd","ai","eps","heic","heif",
		"raw","cr2","nef","arw","dng","orf","rw2","svgz",
		// ── 3D / assets ─────────────────────────────────────────────
		"fbx","blend","blend1","3ds","dae","glb",
		// ── Fonts ───────────────────────────────────────────────────
		"ttf","otf","ttc","woff","woff2",
		// ── Archives / packages / disk images ───────────────────────
		"zip","rar","7z","7zip","tar","gz","bz2","bz","xz","zst","tgz","tbz","tbz2","dmg","iso","cab","pkg","msi","crx",
		"jar","war","ear","apk","ipa",
		// ── Object / compiled / binaries ────────────────────────────
		"o","a","so","dylib","dll","exe","bin","class","wasm","pdb","lib","obj",
		// ── Databases / data containers ─────────────────────────────
		"db","sqlite","sqlite3","realm","mdb","accdb","parquet","feather","arrow",
		// ── Documents (binary containers) ───────────────────────────
		"pdf","doc","docx","ppt","pptx","xls","xlsx","rtf","sketch","indd","idml"
	]

	/// Extensions that are **always** treated as plain-text – we skip the binary probe entirely.
	private static let alwaysTextExtensions: Set<String> = [
		// ── General text / docs ─────────────────────────────────────
		"txt","text","md","markdown","rst","mdx",
		// ── Data / config ───────────────────────────────────────────
		"json","jsonc","xml","yaml","yml","toml","ini","cfg","conf","properties",
		"csv","tsv","proto",
		// ── Web assets ──────────────────────────────────────────────
		"html","htm","css","scss","sass","less","styl",
		"js","mjs","jsx","ts","tsx","vue","svelte","astro","pug","jade",
		// ── Programming languages ──────────────────────────────────
		"swift","c","cpp","cc","h","hpp","m","mm",
		"cs","csx",                                 // C-sharp
		"java","kt","kts","groovy","scala","go","rs","dart","zig","nim",
		"py","pyw","pyx","rb","php","phtml","php5","phps","pl","pm",
		"ex","exs","erl","elixir","clj","cljs","cljc","coffee",
		"sh","bash","zsh","fish","cmd","bat","ps1","psm1","lua",
		"sql"
	]

	/// Filenames with **no** extension that are always text.
	private static let alwaysTextFilenames: Set<String> = [
		"makefile","dockerfile","readme","license",
		"gitignore",".gitignore",".ignore",".env",
		".gitattributes",".editorconfig"
	]
	
	/// Detect a Unicode BOM and return the matching encoding, or `nil`.
	private static func detectBOMEncoding(in data: Data) -> String.Encoding? {
		guard data.count >= 2 else { return nil }
		if data.starts(with: [0xEF, 0xBB, 0xBF])            { return .utf8 }                // UTF‑8 BOM
		if data.starts(with: [0x00, 0x00, 0xFE, 0xFF])      { return .utf32BigEndian }
		if data.starts(with: [0xFF, 0xFE, 0x00, 0x00])      { return .utf32LittleEndian }
		if data.starts(with: [0xFE, 0xFF])                  { return .utf16BigEndian }
		if data.starts(with: [0xFF, 0xFE])                  { return .utf16LittleEndian }
		return nil
	}
	
	/// Attempts to detect the file’s encoding and return the decoded text.
	/// The fast-path now uses the length-aware `String(data:encoding:)`
	/// instead of `String(validatingUTF8:)`, eliminating crashes caused by
	/// missing NUL-termination in `Data` buffers.
	private func readDataAndDetectEncoding(_ fullPath: String) throws -> DetectedText {
		let data = try Data(contentsOf: URL(fileURLWithPath: fullPath))
		
		// 0 --> return empty string immediately  ✅
		if data.isEmpty {
			return DetectedText(string: "", encoding: .utf8)
		}
		
		// 1) Fast-path: strict UTF-8 validation over the *whole* buffer
		//    This is safe because the initializer is length-aware.
		if let utf8String = String(data: data, encoding: .utf8) {
			return DetectedText(string: utf8String, encoding: .utf8)
		}
		
		
		// 2) Charset detector (fallback)
		let enc = detectEncodingFull(data, detector: charsetDetector)
		guard let str = String(data: data, encoding: enc) else {
			throw FileSystemError.failedToReadFile
		}
		return DetectedText(string: str, encoding: enc)
	}
	
	/// Quick heuristic: UTF‑16 text usually contains many NUL bytes.
	private static func looksLikeUTF16(_ data: Data) -> Bool {
		let sample = data.prefix(256)
		let zeroCount = sample.filter { $0 == 0 }.count
		return zeroCount > sample.count / 4          // > 25 % zeros ⇒ likely UTF‑16
	}
	
	/// A minimal directory entry representation
	/// A minimal directory entry representation
	private struct DirEntry {
		let name: String
		let isDir: Bool
		let isSym: Bool
		let isRegularFile: Bool?
	}
	
	/// Result of scanning a directory including ignore file detection
	private struct DirectoryScanResult {
		let entries: [DirEntry]
		let hasGitignore: Bool
		let hasRepoIgnore: Bool
		let hasCursorignore: Bool
	}
	
	/// A collection of common directory names we *always* skip
	/// in order to avoid scanning huge or irrelevant caches.
	private static let universalIgnoreDirs: Set<String> = [
		// Version Control
		".git", ".svn", ".hg",
		
		// Node.js / JavaScript
		"node_modules", ".npm", ".pnpm-store", ".yarn", ".cache", "bower_components",
		
		// Python
		"__pycache__", ".pytest_cache", ".mypy_cache", ".venv", "venv",
		// Some folks also skip .ipynb_checkpoints if using Jupyter
		
		// Java / JVM
		".gradle", ".m2", ".idea",
		
		// .NET / C#
		".nuget",
		
		// Rust
		".cargo", // 'target' is also used by Java, so it's already listed above
		
		// C/C++
		".ccache", "gch",

		// Ruby
		".bundle", ".gem",
	]
	
	/// Gets effective ignore rules for a directory, checking for nested .gitignore/.repo_ignore files
	private func getEffectiveRules(
		for dirURL: URL,
		parentRelPath: String,
		parentRules: IgnoreRules
	) async throws -> IgnoreRules {
		// Performance optimization: batch check both files at once
		// This method is only called when hierarchical ignores are enabled
		// We need to check what files exist
		#if DEBUG
		let scanResult = try Self.listDirectoryWithIgnoreDetection(dirURL.path, fm: self.fm)
		#else
		let scanResult = try Self.listDirectoryWithIgnoreDetection(dirURL.path)
		#endif
		return try await getEffectiveRulesOptimized(
			for: dirURL,
			parentRelPath: parentRelPath,
			parentRules: parentRules,
			hasGitignore: scanResult.hasGitignore && respectGitignore,
			hasRepoIgnore: scanResult.hasRepoIgnore && respectRepoIgnore,
			hasCursorignore: scanResult.hasCursorignore && respectCursorignore
		)
	}
	
	/// Optimized version that minimizes file system operations
	private func getEffectiveRulesOptimized(
		for dirURL: URL,
		parentRelPath: String,
		parentRules: IgnoreRules,
		hasGitignore: Bool,
		hasRepoIgnore: Bool,
		hasCursorignore: Bool
	) async throws -> IgnoreRules {
		let hasLocalIgnoreFiles = hasGitignore || hasRepoIgnore || hasCursorignore
		if hasLocalIgnoreFiles {
			removeNoIgnoreFilesCached(parentRelPath)
			perFolderIgnoreCache.removeValue(forKey: parentRelPath)
		}

		// Check cache first
		if let cached = perFolderIgnoreCache[parentRelPath] {
			return cached
		}
		
		// We already know which files exist from the directory scan
		if !hasLocalIgnoreFiles {
			// Check if we've already determined this directory has no ignore files
			if hasNoIgnoreFilesCached(parentRelPath) {
				// Use parent rules and cache them
				cacheIgnoreRules(parentRules, for: parentRelPath)
				return parentRules
			}
			// No ignore files, use parent rules
			markNoIgnoreFilesCached(parentRelPath)
			cacheIgnoreRules(parentRules, for: parentRelPath)
			return parentRules
		}
		
		// Clone parent rules and add new layers
		let effectiveRules = parentRules.clone()
		
		if hasGitignore && respectGitignore {
			let gitignoreURL = dirURL.appendingPathComponent(".gitignore")
			do {
				#if DEBUG
				let content: String
				if fm is FileManager {
					// Use fast production path for real file system
					content = try String(contentsOf: gitignoreURL, encoding: .utf8)
				} else {
					// Test path - use virtual filesystem
					let data = fm.contents(atPath: gitignoreURL.path) ?? Data()
					content = String(data: data, encoding: .utf8) ?? ""
				}
				#else
				let content = try String(contentsOf: gitignoreURL, encoding: .utf8)
				#endif
				let compiled = GitignoreCompiler.compile(content: content, directoryPath: parentRelPath)
				effectiveRules.addCompiledLayer(compiled)
			} catch {
				print("Failed to compile .gitignore at \(gitignoreURL.path): \(error)")
			}
		}
		
		if hasRepoIgnore {
			let repoIgnoreURL = dirURL.appendingPathComponent(".repo_ignore")
			do {
				#if DEBUG
				let content: String
				if fm is FileManager {
					// Use fast production path for real file system
					content = try String(contentsOf: repoIgnoreURL, encoding: .utf8)
				} else {
					// Test path - use virtual filesystem
					let data = fm.contents(atPath: repoIgnoreURL.path) ?? Data()
					content = String(data: data, encoding: .utf8) ?? ""
				}
				#else
				let content = try String(contentsOf: repoIgnoreURL, encoding: .utf8)
				#endif
				let compiled = GitignoreCompiler.compile(content: content, directoryPath: parentRelPath)
				effectiveRules.addCompiledLayer(compiled)
			} catch {
				print("Failed to compile .repo_ignore at \(repoIgnoreURL.path): \(error)")
			}
		}
		
		if hasCursorignore {
			let cursorignoreURL = dirURL.appendingPathComponent(".cursorignore")
			do {
				#if DEBUG
				let content: String
				if fm is FileManager {
					// Use fast production path for real file system
					content = try String(contentsOf: cursorignoreURL, encoding: .utf8)
				} else {
					// Test path - use virtual filesystem
					let data = fm.contents(atPath: cursorignoreURL.path) ?? Data()
					content = String(data: data, encoding: .utf8) ?? ""
				}
				#else
				let content = try String(contentsOf: cursorignoreURL, encoding: .utf8)
				#endif
				let compiled = GitignoreCompiler.compile(content: content, directoryPath: parentRelPath)
				effectiveRules.addCompiledLayer(compiled)
			} catch {
				print("Failed to compile .cursorignore at \(cursorignoreURL.path): \(error)")
			}
		}
		
		// Cache and return
		cacheIgnoreRules(effectiveRules, for: parentRelPath)
		return effectiveRules
	}

	private func getEffectiveRulesSnapshot(
		for dirURL: URL,
		parentRelPath: String,
		hasGitignore: Bool,
		hasRepoIgnore: Bool,
		hasCursorignore: Bool
	) async throws -> IgnoreRulesSnapshot {
		let parentRel = parentDirectory(of: parentRelPath)
		let parentRules: IgnoreRules
		if let cached = perFolderIgnoreCache[parentRel] {
			parentRules = cached
		} else {
			parentRules = try await ensureRulesChain(for: parentRel)
		}
		let effectiveRules = try await getEffectiveRulesOptimized(
			for: dirURL,
			parentRelPath: parentRelPath,
			parentRules: parentRules,
			hasGitignore: hasGitignore,
			hasRepoIgnore: hasRepoIgnore,
			hasCursorignore: hasCursorignore
		)
		return effectiveRules.snapshot()
	}
	
	/// Cache ignore rules with LRU eviction
	private func cacheIgnoreRules(_ rules: IgnoreRules, for path: String) {
		let evicted = perFolderIgnoreCache.set(rules, forKey: path)
		if let evictedKey = evicted {
			removeNoIgnoreFilesCached(evictedKey)
			if evictedKey == "", path != "" {
				let secondEvicted = perFolderIgnoreCache.set(ignoreRules, forKey: "")
				if let secondKey = secondEvicted {
					removeNoIgnoreFilesCached(secondKey)
				}
			}
		}
	}

	private func hasNoIgnoreFilesCached(_ path: String) -> Bool {
		noIgnoreFileCache[path] == true
	}

	private func markNoIgnoreFilesCached(_ path: String) {
		_ = noIgnoreFileCache.set(true, forKey: path)
	}

	private func removeNoIgnoreFilesCached(_ path: String) {
		noIgnoreFileCache.removeValue(forKey: path)
	}

	private func removeNoIgnoreFilesCached(where shouldRemove: (String) -> Bool) {
		for key in noIgnoreFileCache.keys where shouldRemove(key) {
			removeNoIgnoreFilesCached(key)
		}
	}

	private func clearNoIgnoreFilesCache() {
		noIgnoreFileCache.removeAll()
	}

	/// Clear all ignore-related caches and seed the root rules.
	private func invalidateAllIgnoreCaches() {
		ignoreCacheStore = IgnoreCacheStore()
		perFolderIgnoreCache.removeAll()
		clearNoIgnoreFilesCache()
		cacheIgnoreRules(ignoreRules, for: "")
	}
	
	/// Mark a directory as having no ignore files
	private func markNoIgnoreFiles(_ path: String, parentRules: IgnoreRules) {
		markNoIgnoreFilesCached(path)
		cacheIgnoreRules(parentRules, for: path)
	}

	/// Mark a directory as having no ignore files using cached parent rules
	private func markNoIgnoreFilesUsingCache(_ path: String) async throws {
		let parentRel = parentDirectory(of: path)
		let parentRules: IgnoreRules
		if let cached = perFolderIgnoreCache[parentRel] {
			parentRules = cached
		} else {
			parentRules = try await ensureRulesChain(for: parentRel)
		}
		markNoIgnoreFilesCached(path)
		cacheIgnoreRules(parentRules, for: path)
	}
	
	/// Reads a directory using `opendir` and `readdir`, skipping "." and "..".
	/// Mark it static so it doesn't require an instance of `self`.
	private static func listDirectory(_ path: String) throws -> [DirEntry] {
		let result = try listDirectoryWithIgnoreDetection(path)
		return result.entries
	}
	
	#if DEBUG
	/// DEBUG build: use the injected virtual filesystem (`fm`) instead of
	/// POSIX `opendir`, so tests that rely on `InMemoryFS` / `SpyFS` see
	/// their virtual files and ignore rules.
	private static func listDirectoryWithIgnoreDetection(
		_ path: String,
		fm: any TestFS
	) throws -> DirectoryScanResult {
		// If we're running with the real file system, use the same fast
		// POSIX implementation as Release builds so behavior & perf match.
		if fm is FileManager {
			return try listDirectoryWithIgnoreDetection(path)  // POSIX version
		}
		
		// ---------- Unit-test path (virtual FS) ----------
		let dirURL = URL(fileURLWithPath: path)
		let children = try fm.contentsOfDirectory(
			at: dirURL,
			includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
			options: []
		)
		
		var entries: [DirEntry] = []
		var hasGitignore = false
		var hasRepoIgnore = false
		var hasCursorignore = false
		
		for url in children {
			let name = url.lastPathComponent
			guard name != ".", name != ".." else { continue }
			if Self.isRepoPromptTempFilename(name) { continue }
			switch name {
			case ".gitignore":   hasGitignore = true
			case ".repo_ignore": hasRepoIgnore = true
			case ".cursorignore": hasCursorignore = true
			default: break
			}
			
			var isDirFlag: ObjCBool = false
			_ = fm.fileExists(atPath: url.path, isDirectory: &isDirFlag)
			
			// Symbolic-link info is best-effort; SpyFS/InMemoryFS will just
			// return `false`, which is fine for tests.
			let isSym = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
			
			entries.append(DirEntry(
				name: name,
				isDir: isDirFlag.boolValue,
				isSym: isSym,
				isRegularFile: isDirFlag.boolValue || isSym ? false : true
			))
		}
		
		return DirectoryScanResult(
			entries: entries,
			hasGitignore: hasGitignore,
			hasRepoIgnore: hasRepoIgnore,
			hasCursorignore: hasCursorignore
		)
	}
	#endif

	private struct DecodedDirentName {
		let name: String
		let length: Int
	}
	
	@inline(__always)
	private static func isRepoPromptTempFilename(_ name: String) -> Bool {
		return name.hasPrefix(".repoprompt.tmp.")
	}

	private static func decodeDirentName(_ entry: dirent) -> DecodedDirentName? {
		return withUnsafeBytes(of: entry.d_name) { rawBuffer in
			let buffer = rawBuffer.bindMemory(to: UInt8.self)
			let maxCount = buffer.count
			guard maxCount > 0 else { return nil }

			let nameLen = Int(entry.d_namlen)
			var length = 0
			if nameLen > 0 {
				length = min(nameLen, maxCount)
				if length > 0 && buffer[length - 1] == 0 {
					length -= 1
				}
			} else {
				var nulIndex: Int? = nil
				var i = 0
				while i < maxCount {
					if buffer[i] == 0 {
						nulIndex = i
						break
					}
					i += 1
				}
				guard let foundIndex = nulIndex else { return nil }
				length = foundIndex
			}

			guard length > 0 else { return nil }

			let name = String(decoding: buffer.prefix(length), as: UTF8.self)
			return DecodedDirentName(name: name, length: length)
		}
	}

	private static func fileTypeFallback(
		dir: UnsafeMutablePointer<DIR>,
		entry: dirent,
		nameLength: Int
	) -> (isDir: Bool, isSym: Bool, isRegularFile: Bool?) {
		let fd = dirfd(dir)
		guard fd >= 0 else { return (false, false, nil) }

		var nameBuffer = [CChar](repeating: 0, count: nameLength + 1)
		withUnsafeBytes(of: entry.d_name) { rawBuffer in
			let buffer = rawBuffer.bindMemory(to: UInt8.self)
			let count = min(nameLength, buffer.count)
			if count > 0 {
				for i in 0..<count {
					nameBuffer[i] = CChar(bitPattern: buffer[i])
				}
			}
		}

		var st = stat()
		let noFollowResult = nameBuffer.withUnsafeBufferPointer { buffer -> Int32 in
			guard let base = buffer.baseAddress else { return -1 }
			return fstatat(fd, base, &st, AT_SYMLINK_NOFOLLOW)
		}

		guard noFollowResult == 0 else { return (false, false, nil) }
		let noFollowType = st.st_mode & S_IFMT
		let isSym = (noFollowType == S_IFLNK)

		if isSym {
			let followResult = nameBuffer.withUnsafeBufferPointer { buffer -> Int32 in
				guard let base = buffer.baseAddress else { return -1 }
				return fstatat(fd, base, &st, 0)
			}
			if followResult == 0 {
				let followType = st.st_mode & S_IFMT
				return (followType == S_IFDIR, true, nil)
			}
			return (false, true, nil)
		}

		return (noFollowType == S_IFDIR, false, noFollowType == S_IFREG)
	}
	
	/// Enhanced directory listing that also detects ignore files
	private static func listDirectoryWithIgnoreDetection(_ path: String) throws -> DirectoryScanResult {
		// Open the directory
		guard let dir = opendir(path) else {
			throw NSError(
				domain: "listDirectory",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Failed to open directory: \(path)"]
			)
		}
		defer {
			closedir(dir) // Ensure the directory is closed when done
		}
		
		var entries = [DirEntry]()
		var hasGitignore = false
		var hasRepoIgnore = false
		var hasCursorignore = false
		
		// Iterate over directory entries
		while true {
			errno = 0 // Reset errno before each readdir call
			guard let direntPtr = readdir(dir) else {
				if errno != 0 {
					print("Error reading directory entry for path \(path): \(String(cString: strerror(errno)))")
				}
				break // Exit loop on error or end of directory
			}
			
			// Safely copy the dirent structure
			let dirent = direntPtr.pointee
			guard let decoded = decodeDirentName(dirent) else {
				continue
			}
			let fileName = decoded.name
			
			// Skip "." and ".." entries
			if fileName == "." || fileName == ".." {
				continue
			}
			if Self.isRepoPromptTempFilename(fileName) {
				continue
			}
			// Detect ignore files while we're scanning
			if fileName == ".gitignore" {
				hasGitignore = true
			} else if fileName == ".repo_ignore" {
				hasRepoIgnore = true
			} else if fileName == ".cursorignore" {
				hasCursorignore = true
			}
			
			// Determine file type from d_type
			let dType = dirent.d_type
			var isDir = false
			var isSym = false
			var isRegularFile: Bool? = nil
			
			switch Int32(dType) {
			case DT_DIR:
				isDir = true
				isRegularFile = false
			case DT_REG:
				isRegularFile = true
			case DT_LNK:
				let fallback = fileTypeFallback(
					dir: dir,
					entry: dirent,
					nameLength: decoded.length
				)
				isDir = fallback.isDir
				isSym = true
				isRegularFile = nil
			case DT_UNKNOWN:
				let fallback = fileTypeFallback(
					dir: dir,
					entry: dirent,
					nameLength: decoded.length
				)
				isDir = fallback.isDir
				isSym = fallback.isSym
				isRegularFile = fallback.isRegularFile
			default:
				isRegularFile = false
			}
			
			// Add the entry to the results
			entries.append(DirEntry(name: fileName, isDir: isDir, isSym: isSym, isRegularFile: isRegularFile))
		}
		
		return DirectoryScanResult(
			entries: entries,
			hasGitignore: hasGitignore,
			hasRepoIgnore: hasRepoIgnore,
			hasCursorignore: hasCursorignore
		)
	}
	
	/// Reads a directory using `scandir(3)`, skipping "." and "..".
	/// Mark it static so it doesn't require an instance of `self`.
	private static func scandirListDirectory(_ path: String) throws -> [DirEntry] {
		var namelist: UnsafeMutablePointer<UnsafeMutablePointer<dirent>?>? = nil
		
		let count = scandir(path, &namelist, nil, nil)
		guard count >= 0 else {
			throw NSError(
				domain: "scandirListDirectory",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Failed to open directory: \(path)"]
			)
		}
		defer {
			// Free the memory allocated by scandir
			for i in 0..<count {
				free(namelist![Int(i)])
			}
			free(namelist)
		}
		
		var entries = [DirEntry]()
		entries.reserveCapacity(Int(count))
		
		for i in 0..<count {
			// Copy dirent into local var so the pointer remains valid for the entire iteration
			let localDirent = namelist![Int(i)]!.pointee
			
			// Safely convert d_name -> Swift String
			guard let decoded = decodeDirentName(localDirent) else {
				continue
			}
			let rawName = decoded.name
			
			// Skip "." and ".."
			guard rawName != ".", rawName != ".." else {
				continue
			}
			if Self.isRepoPromptTempFilename(rawName) {
				continue
			}
			
			let dType = localDirent.d_type  // This is a UInt8
			var isDir = false
			var isSym = false
			var isRegularFile: Bool? = nil
			
			switch Int32(dType) {
			case DT_DIR:
				isDir = true
				isRegularFile = false
			case DT_REG:
				isRegularFile = true
			case DT_LNK:
				isSym = true
				let fullPath = (path as NSString).appendingPathComponent(rawName)
				var st = stat()
				if stat(fullPath, &st) == 0,
				   (st.st_mode & S_IFMT) == S_IFDIR {
					isDir = true
				}
				isRegularFile = nil
			case DT_UNKNOWN:
				// If d_type is unknown, do a stat() fallback
				let fullPath = (path as NSString).appendingPathComponent(rawName)
				var st = stat()
				if stat(fullPath, &st) == 0 {
					let mode = st.st_mode & S_IFMT
					isDir = mode == S_IFDIR
					isRegularFile = mode == S_IFREG
				}
			default:
				// e.g. DT_FIFO, DT_CHR, etc.
				isRegularFile = false
			}
			
			// Finally, record the entry
			entries.append(DirEntry(name: rawName, isDir: isDir, isSym: isSym, isRegularFile: isRegularFile))
		}
		
		return entries
	}
	
	public func detectFileEncoding(atRelativePath relativePath: String) async throws -> String.Encoding {
		let fullPath = getFullPath(forRelativePath: relativePath)
		let url = URL(fileURLWithPath: fullPath)
		
		guard let data = try? Data(contentsOf: url) else {
			throw FileSystemError.failedToReadFile
		}
		
		var usedLossyConversion = ObjCBool(false)
		let encodingValue = NSString.stringEncoding(
			for: data,
			encodingOptions: [:],
			convertedString: nil,
			usedLossyConversion: &usedLossyConversion
		)
		if encodingValue != 0 {
			let detected = String.Encoding(rawValue: encodingValue)
			return detected
		}
		
		let encodings: [(String.Encoding, String)] = [
			(.utf8, "UTF-8"),
			(.macOSRoman, "Mac OS Roman"),
			(.ascii, "ASCII"),
			(.utf16, "UTF-16"),
			(.utf16BigEndian, "UTF-16 Big Endian"),
			(.utf16LittleEndian, "UTF-16 Little Endian"),
			(.utf32, "UTF-32"),
			(.utf32BigEndian, "UTF-32 Big Endian"),
			(.utf32LittleEndian, "UTF-32 Little Endian"),
			(.windowsCP1252, "Windows-1252"),
			(.isoLatin1, "ISO-8859-1"),
			(.unicode, "Unicode"),
			(.shiftJIS, "Shift JIS"),
			(.nonLossyASCII, "Non-Lossy ASCII")
		]
		
		for (encoding, _) in encodings {
			if let _ = String(data: data, encoding: encoding) {
				return encoding
			}
		}
		
		return .utf8
	}
	
	// MARK: - Helpers
	
	public func getFullPath(forRelativePath relativePath: String) -> String {
		let sanitized: String
		if relativePath.hasPrefix("/") {
			let trimmed = relativePath.drop { $0 == "/" }
			sanitized = String(trimmed)
		} else {
			sanitized = relativePath
		}
		return (self.path as NSString).appendingPathComponent(sanitized)
	}
	
	private enum RelativeEventPath {
		case inside(relative: String)
		case outside(originalAbsolute: String)
	}

	/// Kernel-resolved absolute path (keeps `/private`, unlike Foundation's
	/// symlink resolution). Returns nil when the path does not exist.
	private nonisolated static func posixRealPath(_ path: String) -> String? {
		guard let resolved = realpath(path, nil) else { return nil }
		defer { free(resolved) }
		return String(cString: resolved)
	}
	
	private func fileOrFolderIsDir(_ relativePath: String) -> Bool {
		let full = (path as NSString).appendingPathComponent(relativePath)
		var isDir: ObjCBool = false
		_ = fm.fileExists(atPath: full, isDirectory: &isDir)
		return isDir.boolValue
	}
	
	@inline(__always)
	private nonisolated static func trimPathSlashes<S: StringProtocol>(_ value: S) -> String {
		var start = value.startIndex
		var end = value.endIndex
		while start < end, value[start] == "/" {
			start = value.index(after: start)
		}
		while end > start {
			let previous = value.index(before: end)
			guard value[previous] == "/" else { break }
			end = previous
		}
		return String(value[start..<end])
	}
	
	@inline(__always)
	private func mapToRelativeEventPath(_ absolutePath: String) -> RelativeEventPath {
		guard Self.eventPathIsSafeForRawPrefixMapping(absolutePath) else {
			return mapToRelativeEventPathFallback(absolutePath)
		}
		if hasDirectoryPrefix(absolutePath, standardizedRootPath) {
			let rel = absolutePath.dropFirst(standardizedRootPath.count)
			return .inside(relative: Self.trimPathSlashes(rel))
		}
		if canonicalRootPath != standardizedRootPath,
			hasDirectoryPrefix(absolutePath, canonicalRootPath) {
			let rel = absolutePath.dropFirst(canonicalRootPath.count)
			return .inside(relative: Self.trimPathSlashes(rel))
		}
		if realRootPath != standardizedRootPath,
			realRootPath != canonicalRootPath,
			hasDirectoryPrefix(absolutePath, realRootPath) {
			let rel = absolutePath.dropFirst(realRootPath.count)
			return .inside(relative: Self.trimPathSlashes(rel))
		}
		return mapToRelativeEventPathFallback(absolutePath)
	}

	#if DEBUG
	@inline(__always)
	private func mapToRelativeEventPath(
		_ absolutePath: String,
		diagnostics: inout EventPathMappingFastPathDiagnostics
	) -> RelativeEventPath {
		diagnostics.rawPathCount += 1

		let isSafe = Self.eventPathIsSafeForRawPrefixMapping(absolutePath)
		if isSafe {
			if hasDirectoryPrefix(absolutePath, standardizedRootPath) {
				diagnostics.fastStandardRootHitCount += 1
				let rel = absolutePath.dropFirst(standardizedRootPath.count)
				return .inside(relative: Self.trimPathSlashes(rel))
			}
			if canonicalRootPath != standardizedRootPath,
				hasDirectoryPrefix(absolutePath, canonicalRootPath) {
				diagnostics.fastCanonicalRootHitCount += 1
				let rel = absolutePath.dropFirst(canonicalRootPath.count)
				return .inside(relative: Self.trimPathSlashes(rel))
			}
			if realRootPath != standardizedRootPath,
				realRootPath != canonicalRootPath,
				hasDirectoryPrefix(absolutePath, realRootPath) {
				diagnostics.fastCanonicalRootHitCount += 1
				let rel = absolutePath.dropFirst(realRootPath.count)
				return .inside(relative: Self.trimPathSlashes(rel))
			}
		} else {
			diagnostics.rejectedUnsafePathCount += 1
		}

		diagnostics.fallbackStandardizationCount += 1
		return mapToRelativeEventPathFallback(absolutePath)
	}
	#endif

	private func mapToRelativeEventPathFallback(_ absolutePath: String) -> RelativeEventPath {
		guard !absolutePath.isEmpty else {
			return .outside(originalAbsolute: absolutePath)
		}
		
		let standardizedAbsolute = NSString(string: absolutePath).standardizingPath
		if hasDirectoryPrefix(standardizedAbsolute, standardizedRootPath) {
			let rel = standardizedAbsolute.dropFirst(standardizedRootPath.count)
			return .inside(relative: Self.trimPathSlashes(rel))
		}
		
		let canonicalAbsolute = URL(fileURLWithPath: standardizedAbsolute).resolvingSymlinksInPath().path
		if hasDirectoryPrefix(canonicalAbsolute, canonicalRootPath) {
			let rel = canonicalAbsolute.dropFirst(canonicalRootPath.count)
			return .inside(relative: Self.trimPathSlashes(rel))
		}

		// Deleted paths defeat the existence-checked standardizations above
		// (they only strip `/private` while the path still exists), so fall
		// back to pure prefix matching against the kernel-resolved root.
		if hasDirectoryPrefix(absolutePath, realRootPath) {
			let rel = absolutePath.dropFirst(realRootPath.count)
			return .inside(relative: Self.trimPathSlashes(rel))
		}
		if hasDirectoryPrefix(standardizedAbsolute, realRootPath) {
			let rel = standardizedAbsolute.dropFirst(realRootPath.count)
			return .inside(relative: Self.trimPathSlashes(rel))
		}

		return .outside(originalAbsolute: standardizedAbsolute)
	}

	@inline(__always)
	private nonisolated static func eventPathIsSafeForRawPrefixMapping(_ path: String) -> Bool {
		var byteCount = 0
		var previousWasSlash = false
		var currentComponentLength = 0
		var currentComponentDotCount = 0
		var currentComponentOnlyDots = true

		for byte in path.utf8 {
			if byteCount == 0 {
				guard byte == 47 else { return false }
				previousWasSlash = true
				byteCount += 1
				continue
			}

			if byte == 0 { return false }
			if byte == 47 {
				if previousWasSlash { return false }
				if currentComponentOnlyDots && (currentComponentDotCount == 1 || currentComponentDotCount == 2) {
					return false
				}
				previousWasSlash = true
				currentComponentLength = 0
				currentComponentDotCount = 0
				currentComponentOnlyDots = true
			} else {
				previousWasSlash = false
				currentComponentLength += 1
				if currentComponentOnlyDots, byte == 46 {
					currentComponentDotCount += 1
				} else {
					currentComponentOnlyDots = false
				}
			}
			byteCount += 1
		}

		guard byteCount > 0 else { return false }
		if previousWasSlash {
			return byteCount == 1
		}
		if currentComponentLength > 0,
			currentComponentOnlyDots,
			(currentComponentDotCount == 1 || currentComponentDotCount == 2) {
			return false
		}
		return true
	}
	
	@inline(__always)
	private func hasDirectoryPrefix(_ path: String, _ base: String) -> Bool {
		guard path.hasPrefix(base) else { return false }
		if path.count == base.count { return true }
		let idx = path.index(path.startIndex, offsetBy: base.count)
		return path[idx] == "/"
	}
	
	private func relativePathFor(_ absolutePath: String) -> String {
		switch mapToRelativeEventPath(absolutePath) {
		case .inside(let relative):
			return relative
		case .outside(let original):
			return original
		}
	}
	
	public func parentDirectory(of relativePath: String) -> String {
		guard let slashIndex = relativePath.lastIndex(of: "/") else {
			return ""
		}
		return String(relativePath[..<slashIndex])
	}
	
	private func isSpecialControlFile(_ relPath: String) -> Bool {
		return isIgnoreFile(relPath)
	}

	private func isIgnoreFile(_ relPath: String) -> Bool {
		let filename = (relPath as NSString).lastPathComponent.lowercased()
		return filename == ".gitignore" || filename == ".repo_ignore" || filename == ".cursorignore"
	}
	
	@inline(__always)
	private func isRepoPromptTempPath(_ relPath: String) -> Bool {
		if relPath.hasPrefix(".repoprompt.tmp.") { return true }
		return relPath.contains("/.repoprompt.tmp.")
	}

	private func isGitMetadataPath(_ relPath: String) -> Bool {
		if relPath.isEmpty { return false }
		if relPath == ".git" { return true }
		return relPath.hasPrefix(".git/")
	}
}

// MARK: - FileManager extension
public extension FileManager {
	public func isFolder(atPath path: String) -> Bool {
		var isDir: ObjCBool = false
		self.fileExists(atPath: path, isDirectory: &isDir)
		return isDir.boolValue
	}
}

// MARK: - URL extension
public extension URL {
	public func relativePath(from base: URL) -> String {
		// Delegates to the authoritative boundary-safe helper. The former explicit
		// `basePath == "/"` branch is redundant with RelativePath's trailing-slash rule.
		RelativePath.from(absolutePath: self.path, rootPath: base.path)
	}
}

// MARK: - FileSystemError
// MARK: - Encoding support -----------------------------------------------------

/// Bundles the decoded text with the encoding that produced it.
public struct DetectedText {
	public let string: String
	public let encoding: String.Encoding
}

/// Convert an IANA charset label (e.g. "windows-1252") to `String.Encoding`.
/// Falls back to UTF-8 on unknown labels.
private extension String.Encoding {
	public init(ianaCharsetName name: String) {
		let cfEnc = CFStringConvertIANACharSetNameToEncoding(name as CFString)
		self.init(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
	}
}

// MARK: - Encoding detection helpers & priority tables
/// Run a streaming detector (Cuchardet) over the entire byte sequence.
/// Falls back to Foundation’s heuristic if the detector is unavailable.
private func detectEncodingFull(_ data: Data, detector: any WorkspaceCharsetDetecting) -> String.Encoding {
	// 1) Primary - injected library detector
	if let label = detector.detectedCharacterEncodingLabel(for: data) {
		return .init(ianaCharsetName: label)
	}
	
	// 2) Fallback - Foundation heuristic
	var lossy = ObjCBool(false)
	let guess = NSString.stringEncoding(
		for: data,
		encodingOptions: [:],
		convertedString: nil,
		usedLossyConversion: &lossy
	)
	return guess != 0 ? .init(rawValue: guess) : .utf8
}


public extension FileSystemService {
	/// Physical directory identity (stable for cycle checks).
	public struct DirID: Hashable, Sendable {
		public let dev: UInt64
		public let ino: UInt64
	}
	
	/// `stat()` follows symlinks → this returns the target directory identity.
	@inline(__always)
	public static func dirID(followingSymlinksAtPath path: String) -> DirID? {
		var st = stat()
		guard stat(path, &st) == 0 else { return nil }
		return DirID(dev: UInt64(st.st_dev), ino: UInt64(st.st_ino))
	}
	
	/// Canonicalize a path via `realpath()`. Returns nil on ELOOP, missing targets, etc.
	@inline(__always)
	public static func realpathString(_ path: String) -> String? {
		return path.withCString { cPath in
			guard let resolved = realpath(cPath, nil) else { return nil }
			defer { free(resolved) }
			return String(cString: resolved)
		}
	}
	
	/// Static version so off-actor code can do the same boundary check.
	@inline(__always)
	public static func hasDirectoryPrefix(_ path: String, _ base: String) -> Bool {
		guard path.hasPrefix(base) else { return false }
		if path.count == base.count { return true }
		let idx = path.index(path.startIndex, offsetBy: base.count)
		return path[idx] == "/"
	}

	/// Helper that does the real write *outside* the actor.
	private static func writeFile(
		to url: URL,
		data: Data
	) throws {
		try data.write(to: url, options: .atomic)   // blocking write
	}
	
	/// Robust write that works across external/network volumes:
	/// 1) try atomic write
	/// 2) write to temp in the same directory then move into place (delete destination if needed)
	/// 3) POSIX open(O_CREAT|O_TRUNC)+write+fsync fallback
	private static func writeFileRobust(
		to url: URL,
		data: Data
	) throws {
		// Fast path: try Foundation's atomic write first.
		do {
			try data.write(to: url, options: [.atomic])
			return
		} catch {
			// fall through to robust fallbacks
		}
		
		let fm = FileManager.default
		let dirURL = url.deletingLastPathComponent()
		let tmpURL = dirURL.appendingPathComponent(".repoprompt.tmp.\(UUID().uuidString)")
		
		// Fallback #1: write to temp in the same directory then move/replace.
		do {
			try data.write(to: tmpURL, options: [])
			if fm.fileExists(atPath: url.path) {
				// Removing the destination first avoids exchange/rename restrictions on some filesystems
				// (exFAT/SMB may reject replace semantics).
				try? fm.removeItem(at: url)
			}
			try fm.moveItem(at: tmpURL, to: url)
			return
		} catch {
			// Clean up temp if it remains
			try? fm.removeItem(at: tmpURL)
		}
		
		// Fallback #2: POSIX open/write/fsync.
		try writeFilePOSIX(to: url, data: data)
	}
	
	/// Low-level write that avoids Foundation's atomic/replace semantics entirely.
	private static func writeFilePOSIX(
		to url: URL,
		data: Data
	) throws {
		let path = url.path
		let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
		if fd == -1 {
			let code = errno
			throw NSError(
				domain: NSPOSIXErrorDomain,
				code: Int(code),
				userInfo: [NSLocalizedDescriptionKey: "open() failed for \(path) (\(code))"]
			)
		}
		
		var writeError: Int32 = 0
		data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
			guard var base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
			var remaining = data.count
			while remaining > 0 {
				let n = Darwin.write(fd, base, remaining)
				if n < 0 {
					writeError = errno
					break
				}
				remaining -= n
				base = base.advanced(by: n)
			}
		}
		
		if writeError == 0 {
			if fsync(fd) != 0 {
				writeError = errno
			}
		}
		
		// Always attempt to close; prefer first error if any.
		let closeResult = close(fd)
		if writeError != 0 {
			throw NSError(
				domain: NSPOSIXErrorDomain,
				code: Int(writeError),
				userInfo: [NSLocalizedDescriptionKey: "write/fsync failed for \(path) (\(writeError))"]
			)
		}
		if closeResult != 0 {
			let code = errno
			throw NSError(
				domain: NSPOSIXErrorDomain,
				code: Int(code),
				userInfo: [NSLocalizedDescriptionKey: "close() failed for \(path) (\(code))"]
			)
		}
	}
}

public enum FileSystemError: Error {
	case fileAlreadyExists
	case fileNotFound
	case failedToCreateFile(Error)
	case failedToEditFile(Error)
	case failedToDeleteFile(Error)
	case failedToReadFile
	case failedToEnumerateDirectory
	case fileTooLarge
	case isDirectory
	case failedToCreateDirectory(Error)
	case invalidRelativePath          // ← NEW
}
