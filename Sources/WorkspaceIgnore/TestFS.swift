//
//  TestFS.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-08-02.
//


import Foundation

#if DEBUG
/// Protocol for file system operations, used for testing
public protocol TestFS {
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
    func contentsOfDirectory(at url: URL,
                             includingPropertiesForKeys keys: [URLResourceKey]?,
                             options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL]
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
    func createDirectory(atPath path: String,
                         withIntermediateDirectories createIntermediates: Bool,
                         attributes: [FileAttributeKey: Any]?) throws
    func createDirectory(at url: URL,
                         withIntermediateDirectories createIntermediates: Bool,
                         attributes: [FileAttributeKey: Any]?) throws
    func removeItem(at url: URL) throws
    func moveItemToTrash(at url: URL) throws -> URL?
    func isWritableFile(atPath path: String) -> Bool
    func enumerator(at url: URL, 
                    includingPropertiesForKeys keys: [URLResourceKey]?, 
                    options mask: FileManager.DirectoryEnumerationOptions,
                    errorHandler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator?
    func contents(atPath path: String) -> Data?
}

extension FileManager: TestFS {
    public func moveItemToTrash(at url: URL) throws -> URL? {
        var resultingItemURL: NSURL?
        try trashItem(at: url, resultingItemURL: &resultingItemURL)
        return resultingItemURL as URL?
    }
}

/// Transfers a `TestFS` double across an actor boundary.
///
/// Why an escape hatch is unavoidable here: `TestFS` cannot be made to refine
/// `Sendable`. Its production conformer is `FileManager`, which Foundation
/// marks `@_nonSendable(_assumed)` (the conformance to `Sendable` is
/// *explicitly unavailable*), and `TestFS` is public API that RepoPrompt's own
/// `InMemoryFS` double conforms to. Refining it would break both.
///
/// INVARIANT — the wrapped value is one of exactly three things, each of which
/// is safe to call concurrently:
///
/// 1. `nil`.
/// 2. A **test double that serializes every access to its own mutable state
///    behind an internal lock**. The doubles in
///    `Tests/WorkspaceFileSystemTests/FSTestDoubles.swift` (`InMemoryFS`,
///    `SpyFS`, `ConcurrencyTrackingFS`) each guard their entire tree/counters
///    with an `NSRecursiveLock`/`NSLock`, so every protocol method is atomic
///    with respect to every other.
/// 3. `FileManager.default` — the process-wide shared instance, which Apple
///    documents as safe to call from multiple threads. This package only ever
///    stores `FileManager.default` in its `fileManager` properties and never
///    installs a delegate on it (delegates are the documented exception).
///
/// The box exists for exactly one purpose: a single file-system view has to be
/// observed by more than one isolation domain — the `FileSystemService` actor
/// (directory enumeration, attributes), the `IgnoreRulesManager` actor
/// (ignore-file reads), and the off-actor scan helpers — and that shared view
/// *is* the seam. Regression coverage for the cross-domain path lives in
/// `FileSystemServiceVFSMigrationTests
/// .testVirtualFSOverrideIsSharedSafelyAcrossIsolationDomains`.
public struct TestFSTransfer: @unchecked Sendable {
    public let fileSystem: (any TestFS)?

    public init(_ fileSystem: (any TestFS)?) {
        self.fileSystem = fileSystem
    }
}
#endif