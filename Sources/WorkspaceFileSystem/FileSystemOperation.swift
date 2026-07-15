import Foundation
import WorkspaceIgnore

public class FileSystemOperation: Operation, @unchecked Sendable {
	public let fileSystemService: FileSystemService
	
	public init(fileSystemService: FileSystemService) {
		self.fileSystemService = fileSystemService
		super.init()
	}
	
	public func createFile(atRelativePath relativePath: String, content: String) async throws {
		try await fileSystemService.createFile(atRelativePath: relativePath, content: content)
	}
	
	public func editFile(atRelativePath relativePath: String, newContent: String) async throws {
		try await fileSystemService.editFile(atRelativePath: relativePath, newContent: newContent)
	}
	
	public func deleteFile(atRelativePath relativePath: String) async throws {
		try await fileSystemService.deleteFile(atRelativePath: relativePath)
	}
}
