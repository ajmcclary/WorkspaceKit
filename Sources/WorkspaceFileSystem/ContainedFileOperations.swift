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

	// MARK: - Position arithmetic

	/// Lexically folds an absolute path; nil if it climbs above `/`.
	private static func foldedAbsoluteComponents(_ path: String) -> [String]? {
		var result: [String] = []
		for component in path.split(separator: "/", omittingEmptySubsequences: true) {
			switch component {
			case ".": continue
			case "..":
				guard !result.isEmpty else { return nil }
				result.removeLast()
			default: result.append(String(component))
			}
		}
		return result
	}

	/// Root-relative components of an absolute path, or nil when it is not
	/// inside the root. Spellings of the root are matched lexically first;
	/// otherwise `realpath` reports where the path lands now. That answer
	/// is only a position to walk to: the walk from the root descriptor
	/// re-checks every component with `O_NOFOLLOW`.
	private func rootRelativeComponents(ofAbsolute path: String) -> [String]? {
		guard let folded = Self.foldedAbsoluteComponents(path) else { return nil }
		let joined = "/" + folded.joined(separator: "/")
		for spelling in spellings {
			let base = spelling.count > 1 && spelling.hasSuffix("/") ? String(spelling.dropLast()) : spelling
			if joined == base { return [] }
			if joined.hasPrefix(base + "/") {
				return joined.dropFirst(base.count + 1).split(separator: "/").map(String.init)
			}
		}
		guard let resolved = joined.withCString({ cPath -> String? in
			guard let pointer = realpath(cPath, nil) else { return nil }
			defer { free(pointer) }
			return String(cString: pointer)
		}) else { return nil }
		if resolved == realPath { return [] }
		guard resolved.hasPrefix(realPath + "/") else { return nil }
		return resolved.dropFirst(realPath.count + 1).split(separator: "/").map(String.init)
	}

	/// Where the symlink `name` inside the directory at root-relative `position`
	/// points, as root-relative components; nil when outside the root.
	private func resolveLink(named name: String, in directory: ContainedDirectory, position: [String]) -> [String]? {
		var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
		let length = readlinkat(directory.fd, name, &buffer, Int(MAXPATHLEN))
		guard length > 0 else { return nil }
		let target = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
		if target.hasPrefix("/") {
			return rootRelativeComponents(ofAbsolute: target)
		}
		// `position` is a symlink-free chain from the root, so folding `..`
		// lexically on realPath + position + target equals the physical walk.
		let absolute = ([realPath] + position + [target]).joined(separator: "/")
		return rootRelativeComponents(ofAbsolute: absolute)
	}

	// MARK: - Walking

	/// Opens the directory at root-relative `components` without letting the
	/// kernel follow any symlink. Returns the descriptor and its resolved,
	/// symlink-free position.
	///
	/// - Throws: `invalidRelativePath` when a symlink resolves outside the root,
	///   a component is not a directory, or links loop; `fileNotFound` when a
	///   component is missing and `createMissing` is false.
	func openDirectory(
		_ components: [String],
		createMissing: Bool
	) throws -> (directory: ContainedDirectory, position: [String]) {
		var pending = components[...]
		var position: [String] = []
		var current = directory
		var hops = 0
		var attempts = 0
		while let component = pending.first {
			attempts += 1
			if attempts > 4 * (components.count + Self.maxSymlinkHops) + 64 {
				throw FileSystemError.invalidRelativePath
			}
			let next = openat(current.fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			if next >= 0 {
				current = ContainedDirectory(adopting: next)
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
				guard hops <= Self.maxSymlinkHops,
					let target = resolveLink(named: component, in: current, position: position) else {
					throw FileSystemError.invalidRelativePath
				}
				pending = (target + pending.dropFirst())[...]
				position = []
				current = directory
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
		return (current, position)
	}

	/// The parent directory of `components` plus the leaf name.
	func openParent(
		of components: [String],
		createMissing: Bool
	) throws -> (directory: ContainedDirectory, position: [String], leaf: String) {
		guard let leaf = components.last else { throw FileSystemError.invalidRelativePath }
		let (directory, position) = try openDirectory(Array(components.dropLast()), createMissing: createMissing)
		return (directory, position, leaf)
	}

	/// The location of an existing regular file, following symlinks at the
	/// leaf explicitly (each target re-validated against the root).
	func openExistingRegularFile(_ components: [String]) throws -> (directory: ContainedDirectory, leaf: String) {
		var target = components
		for _ in 0...Self.maxSymlinkHops {
			let (directory, position, leaf) = try openParent(of: target, createMissing: false)
			var info = stat()
			guard fstatat(directory.fd, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
				throw FileSystemError.fileNotFound
			}
			switch info.st_mode & S_IFMT {
			case S_IFREG:
				return (directory, leaf)
			case S_IFLNK:
				guard let resolved = resolveLink(named: leaf, in: directory, position: position), !resolved.isEmpty else {
					throw FileSystemError.invalidRelativePath
				}
				target = resolved
			case S_IFDIR:
				throw FileSystemError.isDirectory
			default:
				throw FileSystemError.invalidRelativePath
			}
		}
		throw FileSystemError.invalidRelativePath
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
