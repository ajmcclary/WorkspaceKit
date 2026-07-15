import Foundation
import WorkspacePathsCore

// FileSystemItem + File/Folder scan payload types, promoted from
// RepoPrompt's FileSystemItems.swift (adoption slice 4). The app keeps
// FileTreeItem (FileViewModel-coupled) in that file.

public protocol FileSystemItem: Identifiable, Equatable, Sendable {
	var id: UUID { get }
	var name: String { get }
	var path: String { get }
	var modificationDate: Date { get }
}

public struct Folder: FileSystemItem {
	public let id = UUID()
	public let name: String
	public let path: String
	public let modificationDate: Date

	public init(name: String, path: String, modificationDate: Date) {
		self.name = name
		self.path = path
		self.modificationDate = modificationDate
	}
	
	public static func == (lhs: Folder, rhs: Folder) -> Bool {
		return lhs.path == rhs.path
	}
}

public extension FileSystemItem {
	func relativePath(rootPath: String) -> String {
		RelativePath.from(absolutePath: self.path, rootPath: rootPath)
	}
}

public struct File: FileSystemItem {
	public let id = UUID()
	public let name: String
	public let path: String
	public let modificationDate: Date

	public init(name: String, path: String, modificationDate: Date) {
		self.name = name
		self.path = path
		self.modificationDate = modificationDate
	}
	
	public static func == (lhs: File, rhs: File) -> Bool {
		return lhs.path == rhs.path
	}
}

