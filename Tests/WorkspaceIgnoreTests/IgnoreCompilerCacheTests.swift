import Foundation
import Testing
import WorkspaceIgnore

struct IgnoreCompilerCacheTests {
	@Test func compileCompatibilityAPIReadsDirectly() async throws {
		try await withFile { url in
			try Data("one\n".utf8).write(to: url)
			let rules = try await IgnoreRulesManager.shared.compileIgnoreFile(at: url)
			#expect(rules.denies("one", isDirectory: false))
		}
	}

	@Test func missingFilesThrowAndPreEpochDatesAreSupported() async throws {
		try await withFile { url in
			await #expect(throws: CocoaError.self) {
				_ = try await IgnoreRulesManager.shared.compiledIgnoreFile(at: url)
			}
			try Data("one\n".utf8).write(to: url)
			try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: -100)], ofItemAtPath: url.path)
			let rules = try await IgnoreRulesManager.shared.compiledIgnoreFile(at: url)
			#expect(rules.denies("one", isDirectory: false))
		}
	}

	@Test func subsecondRewriteInvalidatesCachedRules() async throws {
		try await withFile { url in
			let manager = IgnoreRulesManager.shared
			let base = Date(timeIntervalSince1970: 1_700_000_000)
			try Data("one\n".utf8).write(to: url)
			try FileManager.default.setAttributes([.modificationDate: base + 0.1], ofItemAtPath: url.path)
			let first = try await manager.compiledIgnoreFile(at: url)
			#expect(first.denies("one", isDirectory: false))
			try Data("two\n".utf8).write(to: url)
			try FileManager.default.setAttributes([.modificationDate: base + 0.7], ofItemAtPath: url.path)
			let second = try await manager.compiledIgnoreFile(at: url)
			#expect(second.denies("two", isDirectory: false))
			#expect(!second.denies("one", isDirectory: false))
		}
	}

	private func withFile(_ action: (URL) async throws -> Void) async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await action(directory.appendingPathComponent(".gitignore"))
	}
}
