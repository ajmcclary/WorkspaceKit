import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin          // for stat()
#else
import Glibc
#endif

/// Shared defaults and legacy key handling for app-wide ignore preferences.
///
/// Kept outside `IgnoreRulesManager` so JSON-backed settings, legacy mirrors,
/// and runtime ignore-rule loading agree on the canonical defaults/version.
public enum IgnoreSettingsDefaults {
	public static let globalIgnoreDefaultsKey = "globalIgnoreDefaults"
	public static let globalIgnoreDefaultsVersionKey = "globalIgnoreDefaultsVersion"
	/// Bump when we add new "required by default" patterns.
	public static let currentGlobalIgnoreDefaultsVersion = 2

	/// Canonical default patterns (do NOT include `.git`; that is always ignored separately).
	/// These mirror our "big dirs" heuristic plus a few common temp files.
	public static let canonicalGlobalIgnoreDefaults: String = """
	# RepoPrompt global ignore defaults (v\(currentGlobalIgnoreDefaultsVersion))
	**/node_modules/
	**/.npm/
	**/.pnpm-store/
	**/.yarn/
	**/.cache/
	**/bower_components/

	**/__pycache__/
	**/.pytest_cache/
	**/.mypy_cache/

	**/.gradle/
	**/.m2/
	**/.nuget/
	**/.cargo/
	**/.stack-work/
	**/.ccache/

	**/.idea/
	**/.vscode/
	**/.bundle/
	**/.gem/

	# Virtual environments
	**/.venv/
	**/venv/

	# Common temp/junk files
	**/*.swp
	**/*~
	**/*.tmp
	**/*.temp
	**/*.bak
	"""

	public static func resolvedGlobalIgnoreDefaults(defaults: UserDefaults = .standard) -> String {
		let storedObject = defaults.object(forKey: globalIgnoreDefaultsKey)
		let stored = defaults.string(forKey: globalIgnoreDefaultsKey)
		let storedVersion = defaults.object(forKey: globalIgnoreDefaultsVersionKey) as? Int ?? 0

		guard storedObject != nil, let stored else {
			defaults.set(canonicalGlobalIgnoreDefaults, forKey: globalIgnoreDefaultsKey)
			defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
			return canonicalGlobalIgnoreDefaults
		}

		guard storedVersion < currentGlobalIgnoreDefaultsVersion else {
			return stored
		}

		guard !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			defaults.set(canonicalGlobalIgnoreDefaults, forKey: globalIgnoreDefaultsKey)
			defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
			return canonicalGlobalIgnoreDefaults
		}

		let have = normalizedPatterns(stored)
		let required = normalizedPatterns(canonicalGlobalIgnoreDefaults)
		let missing = required.subtracting(have)

		guard !missing.isEmpty else {
			defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
			return stored
		}

		let upgraded = stored.trimmingCharacters(in: .whitespacesAndNewlines)
			+ "\n\n# (Auto-upgraded to v\(currentGlobalIgnoreDefaultsVersion))\n"
			+ missing.sorted().joined(separator: "\n")
			+ "\n"
		defaults.set(upgraded, forKey: globalIgnoreDefaultsKey)
		defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
		return upgraded
	}

	private static func normalizedPatterns(_ text: String) -> Set<String> {
		Set(
			text
				.components(separatedBy: .newlines)
				.map { $0.trimmingCharacters(in: .whitespaces) }
				.filter { !$0.isEmpty && !$0.hasPrefix("#") }
		)
	}
}

/// A lightweight manager that builds `IgnoreRules` on demand, with no caching.
public actor IgnoreRulesManager {
	public static let shared = IgnoreRulesManager()

	#if DEBUG
	private var fileManagerOverride: (any TestFS)?

	public func setFileManagerOverride(_ fm: (any TestFS)?) {
		self.fileManagerOverride = fm
	}
	#endif

	private let ioSemaphore = TaskSemaphore(4)               // Max 4 concurrent file reads
	// Compile-result cache keyed by (dev, ino, mtime) to avoid duplicate work across symlinks.
	private struct FileMetaKey: Hashable {
		let dev: dev_t
		let ino: ino_t
		let seconds: Int
		let nanoseconds: Int
		let changeSeconds: Int
		let changeNanoseconds: Int
	}
	private var compiledCache = LRUCache<FileMetaKey, Task<CompiledIgnoreRules, Error>>(
		capacity: 500
	)  // metadata → task

	private init() {}

	#if DEBUG
	/// Detect if we're running under XCTest to make ignore behavior deterministic
	private static let isRunningTests: Bool = {
		ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
	}()
	#endif

	// MARK: - File metadata helper
	/// Cache only when the filesystem supplied an identity and change times.
	private func fileMetaKey(for url: URL) -> FileMetaKey? {
		var st = stat()
		guard stat(url.path, &st) == 0 else { return nil }
		#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
		let modified = st.st_mtimespec
		let changed = st.st_ctimespec
		#else
		let modified = st.st_mtim
		let changed = st.st_ctim
		#endif
		return FileMetaKey(dev: st.st_dev, ino: st.st_ino,
			seconds: modified.tv_sec, nanoseconds: modified.tv_nsec,
			changeSeconds: changed.tv_sec, changeNanoseconds: changed.tv_nsec)
	}

	/// Loads .gitignore and/or .repo_ignore content from disk, merges them into a single IgnoreRules.
	public func getIgnoreRules(
		for path: String,
		respectGitignore: Bool = true,
		respectRepoIgnore: Bool = true,
		respectCursorignore: Bool = true
	) async throws -> IgnoreRules {
		// This standalone entry point authorizes the supplied directory. Verify
		// the opened regular file's kernel path before reading a linked ignore file.
		#if DEBUG
		if let override = fileManagerOverride, !(override is FileManager) {
			func read(_ name: String) -> String? {
				override.contents(atPath: (path as NSString).appendingPathComponent(name))
					.flatMap { String(data: $0, encoding: .utf8) }
			}
			return Self.rootRules(git: respectGitignore ? read(".gitignore") : nil,
				repo: respectRepoIgnore ? read(".repo_ignore") : nil,
				cursor: respectCursorignore ? read(".cursorignore") : nil)
		}
		#endif
		let directory = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
		guard directory >= 0 else { return Self.rootRules(git: nil, repo: nil, cursor: nil) }
		defer { close(directory) }
		#if canImport(Darwin)
		func descriptorPath(_ fd: Int32) throws -> String {
			var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
			guard fcntl(fd, F_GETPATH, &buffer) == 0 else {
				throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
			}
			return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
		}
		let rootPath = try descriptorPath(directory)
		let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
		#endif
		func read(_ name: String) throws -> String? {
			#if canImport(Darwin)
			let fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOCTTY)
			#else
			let fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
			#endif
			guard fd >= 0 else {
				if errno == ENOENT || errno == ELOOP { return nil }
				throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
			}
			let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
			defer { try? handle.close() }
			var info = stat()
			guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
			#if canImport(Darwin)
			guard try descriptorPath(fd).hasPrefix(prefix), try descriptorPath(directory) == rootPath else { return nil }
			#endif
			guard let text = String(data: try handle.readToEnd() ?? Data(), encoding: .utf8) else {
				throw CocoaError(.fileReadInapplicableStringEncoding)
			}
			return text
		}
		return try Self.rootRules(git: respectGitignore ? read(".gitignore") : nil,
			repo: respectRepoIgnore ? read(".repo_ignore") : nil,
			cursor: respectCursorignore ? read(".cursorignore") : nil)
	}

	/// A workspace service supplies text from files opened under its own root and link policy.
	package nonisolated static func rootRules(git: String?, repo: String?, cursor: String?) -> IgnoreRules {
		let rules = IgnoreRules()
		if let git { rules.addIgnoreFile(content: git, priority: 1) }
		#if DEBUG
		let defaults = isRunningTests ? IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults : IgnoreSettingsDefaults.resolvedGlobalIgnoreDefaults()
		#else
		let defaults = IgnoreSettingsDefaults.resolvedGlobalIgnoreDefaults()
		#endif
		rules.addIgnoreFile(content: defaults, priority: 2)
		if let repo { rules.addIgnoreFile(content: repo, priority: 3) }
		if let cursor { rules.addIgnoreFile(content: cursor, priority: 4) }
		return rules
	}

	/// Asynchronously compile a `.gitignore` / `.repo_ignore` file.
	/// The first caller starts the compilation task; subsequent callers await
	/// the same task, ensuring the file is compiled exactly once.
	public func compiledIgnoreFile(at url: URL) async throws -> CompiledIgnoreRules {
		guard let key = fileMetaKey(for: url) else { return try compileIgnoreFile(at: url) }
		
		// Fast path: if we already have a task in-flight or completed, just await it.
		if let existing = compiledCache[key] {
			return try await existing.value
		}
		
		// Create a single shared compilation task.
		let task = Task<CompiledIgnoreRules, Error> {
			// Bounded parallelism
			await ioSemaphore.acquire()
			do {
				// Perform the (blocking) file read on the current executor – it's fine
				// because we have limited the total number of concurrent reads.
				let compiled = try compileIgnoreFile(at: url)
				
				// Release the permit before returning
				await ioSemaphore.release()
				return compiled
			} catch {
				// Make sure we always release the permit
				await ioSemaphore.release()
				throw error
			}
		}
		
		// Store the task so subsequent callers share it.
		compiledCache[key] = task
		
		do {
			let result = try await task.value
			return result
		} catch {
			// On failure remove from cache so a later attempt can retry.
			compiledCache.removeValue(forKey: key)
			throw error
		}
	}

	/// Synchronous compatibility entry point. Reads the current file directly.
	public func compileIgnoreFile(at url: URL) throws -> CompiledIgnoreRules {
		let content = try String(contentsOf: url, encoding: .utf8)
		return GitignoreCompiler.compile(content: content)
	}
}
