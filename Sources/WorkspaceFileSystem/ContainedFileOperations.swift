import Foundation
import Darwin
import WorkspacePathsCore

// Descriptor-relative file operations confined to a workspace root.
//
// Every mutating `FileSystemService` entry point resolves its target here,
// and the operation itself uses the same descriptors the check used, so a
// directory swapped for a symlink between "check" and "write" cannot redirect
// the write (the window a path-based check + path-based write leaves open).
//
// - The root is opened once per operation (`open(root, O_DIRECTORY)`); the
//   root path itself may go through symlinks.
// - Each further component is opened with `openat(dir, name, O_DIRECTORY |
//   O_NOFOLLOW)`; missing directories are created with `mkdirat`.
// - A component that is a symlink is never followed by the kernel. Its target
//   is read with `readlinkat`, turned into a root-relative position, and the
//   walk restarts from the root descriptor at that position (so a link inside
//   the root to another place inside the root keeps working). A target that
//   resolves outside the root is refused.
// - The final component is created, replaced, renamed or removed with
//   `openat(… O_NOFOLLOW | O_EXCL)`, `renameat`, `renameatx_np` and `unlinkat`
//   relative to its parent's descriptor.

/// An open directory descriptor, closed when the last reference goes away.
/// Immutable after init, so sharing it across isolation domains is safe.
final class ContainedDirectory: @unchecked Sendable {
	let fd: Int32

	init(adopting fd: Int32) {
		self.fd = fd
	}

	deinit {
		close(fd)
	}

	/// The kernel's current path of this directory (`F_GETPATH`).
	func currentPath() -> String? {
		var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
		guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
		return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
	}
}

/// The workspace root, opened for one operation.
final class ContainedRoot: @unchecked Sendable {
	let directory: ContainedDirectory
	/// `F_GETPATH` of the root descriptor (kernel spelling, keeps `/private`).
	let realPath: String
	/// Other spellings of the root an absolute symlink target may use.
	private let spellings: [String]

	/// Opens `path` (following symlinks in the root path itself, once).
	init(path: String, alternateSpellings: [String]) throws {
		let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
		guard fd >= 0 else {
			throw FileSystemError.fileNotFound
		}
		directory = ContainedDirectory(adopting: fd)
		guard let real = directory.currentPath() else {
			throw FileSystemError.fileNotFound
		}
		realPath = real
		var all = [real]
		for spelling in [path] + alternateSpellings where !spelling.isEmpty && !all.contains(spelling) {
			all.append(spelling)
		}
		spellings = all
	}

	private static let maxSymlinkHops = 32

	// MARK: - Link targets

	/// A symlink's target, ready to be walked. `.` and `..` are kept: the walk
	/// applies each `..` to the directory it actually reached, the way the
	/// kernel does, so a target such as `la/../x` (with `la` itself a link)
	/// lands where every reader of the link lands. Folding the string first
	/// would not.
	private enum LinkTarget {
		/// Components to walk from the directory that holds the link.
		case relative([String])
		/// Components to walk from the root.
		case fromRoot([String])
	}

	/// Reads the symlink `name` in `directory`. An absolute target is mapped to
	/// the root by matching one of the root's spellings component by
	/// component (the rest, `..` included, is walked); otherwise `realpath`
	/// reports where the kernel resolves it now. That answer is only a
	/// position to walk to: the walk from the root descriptor re-checks every
	/// component with `O_NOFOLLOW`. nil when the target is not inside the root.
	private func readLink(named name: String, in directory: ContainedDirectory) -> LinkTarget? {
		var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
		let length = readlinkat(directory.fd, name, &buffer, Int(MAXPATHLEN))
		guard length > 0 else { return nil }
		let target = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
		let components = target.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
		guard target.hasPrefix("/") else {
			return .relative(components)
		}
		for spelling in spellings {
			let base = spelling.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
			if components.count >= base.count, Array(components.prefix(base.count)) == base {
				return .fromRoot(Array(components.dropFirst(base.count)))
			}
		}
		guard let resolved = target.withCString({ cPath -> String? in
			guard let pointer = realpath(cPath, nil) else { return nil }
			defer { free(pointer) }
			return String(cString: pointer)
		}) else { return nil }
		if resolved == realPath { return .fromRoot([]) }
		guard resolved.hasPrefix(realPath + "/") else { return nil }
		return .fromRoot(resolved.dropFirst(realPath.count + 1).split(separator: "/").map(String.init))
	}

	// MARK: - Walking

	/// Opens the directory at root-relative `components` without letting the
	/// kernel follow any symlink. Returns the descriptor and its resolved,
	/// symlink-free position.
	///
	/// `components` may contain `.` and `..` (from link targets): `..` steps
	/// back to the directory actually reached before it, and a `..` at the root
	/// is refused, as is anything else that would leave the root.
	///
	/// - Throws: `invalidRelativePath` when a symlink resolves outside the root,
	///   the walk would climb above the root, a component is not a directory,
	///   or links loop; `fileNotFound` when a component is missing and
	///   `createMissing` is false.
	func openDirectory(
		_ components: [String],
		createMissing: Bool
	) throws -> (directory: ContainedDirectory, position: [String]) {
		var hops = 0
		return try openDirectory(components, createMissing: createMissing, hops: &hops)
	}

	private func openDirectory(
		_ components: [String],
		createMissing: Bool,
		hops: inout Int
	) throws -> (directory: ContainedDirectory, position: [String]) {
		var pending = components[...]
		var position: [String] = []
		// Directories reached below the root, parallel to `position`.
		var reached: [ContainedDirectory] = []
		var attempts = 0
		while let component = pending.first {
			attempts += 1
			if attempts > 4 * (components.count + Self.maxSymlinkHops) + 64 {
				throw FileSystemError.invalidRelativePath
			}
			if component == "." {
				pending = pending.dropFirst()
				continue
			}
			if component == ".." {
				guard !position.isEmpty else { throw FileSystemError.invalidRelativePath }
				position.removeLast()
				reached.removeLast()
				pending = pending.dropFirst()
				continue
			}
			let current = reached.last ?? directory
			let next = openat(current.fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			if next >= 0 {
				reached.append(ContainedDirectory(adopting: next))
				position.append(component)
				pending = pending.dropFirst()
				continue
			}
			let openError = errno
			var info = stat()
			if fstatat(current.fd, component, &info, AT_SYMLINK_NOFOLLOW) != 0 {
				guard errno == ENOENT else { throw FileSystemError.invalidRelativePath }
				guard createMissing else { throw FileSystemError.fileNotFound }
				if mkdirat(current.fd, component, 0o777) != 0, errno != EEXIST {
					throw FileSystemError.failedToCreateDirectory(Self.posixError(errno, "mkdirat", component))
				}
				continue // open what is there now
			}
			switch info.st_mode & S_IFMT {
			case S_IFLNK:
				hops += 1
				guard hops <= Self.maxSymlinkHops, let target = readLink(named: component, in: current) else {
					throw FileSystemError.invalidRelativePath
				}
				switch target {
				case .relative(let targetComponents):
					// Walked from the link's own directory (the current position).
					pending = (targetComponents + pending.dropFirst())[...]
				case .fromRoot(let targetComponents):
					pending = (targetComponents + pending.dropFirst())[...]
					position = []
					reached = []
				}
			case S_IFDIR:
				// A directory we may not open (permissions), or one that was
				// swapped in after the open failed: retry once, then report.
				if openError == EACCES || openError == EPERM {
					throw FileSystemError.failedToCreateDirectory(Self.posixError(openError, "openat", component))
				}
				continue
			default:
				throw FileSystemError.invalidRelativePath // not a directory
			}
		}
		return (reached.last ?? directory, position)
	}

	/// The parent directory of `components` plus the leaf name.
	func openParent(
		of components: [String],
		createMissing: Bool
	) throws -> (directory: ContainedDirectory, position: [String], leaf: String) {
		var hops = 0
		return try openParent(of: components, createMissing: createMissing, hops: &hops)
	}

	private func openParent(
		of components: [String],
		createMissing: Bool,
		hops: inout Int
	) throws -> (directory: ContainedDirectory, position: [String], leaf: String) {
		guard let leaf = components.last, leaf != ".", leaf != ".." else { throw FileSystemError.invalidRelativePath }
		let (directory, position) = try openDirectory(Array(components.dropLast()), createMissing: createMissing, hops: &hops)
		return (directory, position, leaf)
	}

	/// The location of an existing regular file, following symlinks at the
	/// leaf explicitly: each target is walked from the link's directory (or
	/// the root), sharing one hop budget with the directory walks.
	func openExistingRegularFile(_ components: [String]) throws -> (directory: ContainedDirectory, leaf: String) {
		var target = components
		var hops = 0
		while true {
			if let last = target.last, last == "." || last == ".." {
				// The link points at a directory (or out of the root).
				_ = try openDirectory(target, createMissing: false, hops: &hops)
				throw FileSystemError.isDirectory
			}
			let (directory, position, leaf) = try openParent(of: target, createMissing: false, hops: &hops)
			var info = stat()
			guard fstatat(directory.fd, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
				throw FileSystemError.fileNotFound
			}
			switch info.st_mode & S_IFMT {
			case S_IFREG:
				return (directory, leaf)
			case S_IFLNK:
				hops += 1
				guard hops <= Self.maxSymlinkHops, let link = readLink(named: leaf, in: directory) else {
					throw FileSystemError.invalidRelativePath
				}
				switch link {
				case .relative(let targetComponents): target = position + targetComponents
				case .fromRoot(let targetComponents): target = targetComponents
				}
				guard !target.isEmpty else { throw FileSystemError.isDirectory } // the root itself
			case S_IFDIR:
				throw FileSystemError.isDirectory
			default:
				throw FileSystemError.invalidRelativePath
			}
		}
	}

	// MARK: - Entry queries

	/// `lstat` of `name` in `directory`, or nil when nothing is there.
	static func entryInfo(_ name: String, in directory: ContainedDirectory) -> stat? {
		var info = stat()
		return fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 ? info : nil
	}

	/// Something exists at `name`: an entry that is not a symlink, or a
	/// symlink whose target exists (a dangling link counts as absent and is
	/// replaced by a create, as before).
	static func entryExists(_ name: String, in directory: ContainedDirectory) -> Bool {
		guard let info = entryInfo(name, in: directory) else { return false }
		if (info.st_mode & S_IFMT) != S_IFLNK { return true }
		var followed = stat()
		return fstatat(directory.fd, name, &followed, 0) == 0
	}

	// MARK: - Removal

	/// Removes `name` from `directory`: a file or symlink is unlinked (a link
	/// is removed, never its target), a directory is removed with everything
	/// in it, without following symlinks inside.
	static func removeEntry(_ name: String, in directory: ContainedDirectory) throws {
		guard let info = entryInfo(name, in: directory) else { throw FileSystemError.fileNotFound }
		if (info.st_mode & S_IFMT) == S_IFDIR {
			let child = openat(directory.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			guard child >= 0 else { throw posixError(errno, "openat", name) }
			let childDirectory = ContainedDirectory(adopting: child)
			for entry in try entryNames(in: childDirectory) {
				try removeEntry(entry, in: childDirectory)
			}
			guard unlinkat(directory.fd, name, AT_REMOVEDIR) == 0 else { throw posixError(errno, "unlinkat", name) }
		} else {
			guard unlinkat(directory.fd, name, 0) == 0 else { throw posixError(errno, "unlinkat", name) }
		}
	}

	private static func entryNames(in directory: ContainedDirectory) throws -> [String] {
		let duplicate = dup(directory.fd)
		guard duplicate >= 0, let stream = fdopendir(duplicate) else {
			if duplicate >= 0 { close(duplicate) }
			throw posixError(errno, "fdopendir", ".")
		}
		defer { closedir(stream) }
		var names: [String] = []
		while let entry = readdir(stream) {
			let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
				String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
			}
			if name != "." && name != ".." { names.append(name) }
		}
		return names
	}

	static func posixError(_ code: Int32, _ operation: String, _ name: String) -> NSError {
		NSError(
			domain: NSPOSIXErrorDomain,
			code: Int(code),
			userInfo: [NSLocalizedDescriptionKey: "\(operation) failed for \(name) (\(code))"]
		)
	}
}
