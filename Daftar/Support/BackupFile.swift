//  BackupFile.swift
//  The on-disk form of a library backup (format 2).
//
//  Format 1 was plain JSON: every payload base64-encoded, and page history
//  stored as JSON *inside* that JSON, so history bytes were base64-encoded
//  twice. Each history revision also repeated every picture on the page.
//  A real library with 5 MB of distinct pictures produced a 105 MB backup.
//
//  Format 2:
//  - a binary property list, which stores bytes as bytes (no base64);
//  - no page history: a backup holds the current library (pages, Trash,
//    attachments, saved searches); older versions stay in the app;
//  - each RTFD split into its files (text + attachments), every distinct
//    file stored once by SHA-256 and shared by all pages.
//  Restoring verifies every file against its hash before anything is used.
//  Files written before history was dropped may still contain it (as a
//  list of revisions); restoring keeps it rather than discarding data.

import Foundation
import CryptoKit

/// An RTFD package as a list of its files, whose bytes live in `BackupFile.files`.
struct PackedRTFD: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        var name: String
        var sha256: String
        var modified: Date?
        var permissions: Int?
    }
    var files: [File]

    /// Only payloads above this size are packed; smaller ones stay inline.
    static let packThreshold = 4096

    /// Splits flattened RTFD `data`. Returns nil for anything that isn't a
    /// plain RTFD directory of files, which is then stored as-is.
    static func pack(_ data: Data, into store: inout [String: Data]) -> PackedRTFD? {
        guard data.count > packThreshold,
              let wrapper = FileWrapper(serializedRepresentation: data), wrapper.isDirectory,
              let children = wrapper.fileWrappers, !children.isEmpty,
              children.values.allSatisfy({ $0.isRegularFile && $0.regularFileContents != nil }) else { return nil }
        var files: [File] = []
        for (name, child) in children.sorted(by: { $0.key < $1.key }) {
            let bytes = child.regularFileContents!
            let key = SyncBlobs.hash(bytes)
            store[key] = bytes
            files.append(File(name: name, sha256: key,
                              modified: child.fileAttributes[FileAttributeKey.modificationDate.rawValue] as? Date,
                              permissions: (child.fileAttributes[FileAttributeKey.posixPermissions.rawValue] as? NSNumber)?.intValue))
        }
        return PackedRTFD(files: files)
    }

    /// Rebuilds the flattened RTFD. Content (text, attachments, names and
    /// file attributes) is identical to what was packed; AppKit's cached
    /// previews that flattened RTFD sometimes carries are regenerated on use.
    func unpack(from store: [String: Data]) throws -> Data {
        var children: [String: FileWrapper] = [:]
        for file in files {
            guard let bytes = store[file.sha256] else { throw LibraryBackup.BackupError.invalidFormat }
            let child = FileWrapper(regularFileWithContents: bytes)
            child.preferredFilename = file.name
            if file.modified != nil || file.permissions != nil {
                // FileWrapper insists on a type and permissions whenever attributes are set.
                var attributes: [String: Any] = [FileAttributeKey.type.rawValue: FileAttributeType.typeRegular,
                                                 FileAttributeKey.posixPermissions.rawValue: file.permissions ?? 0o644]
                if let modified = file.modified { attributes[FileAttributeKey.modificationDate.rawValue] = modified }
                child.fileAttributes = attributes
            }
            children[file.name] = child
        }
        guard let data = FileWrapper(directoryWithFileWrappers: children).serializedRepresentation else {
            throw LibraryBackup.BackupError.invalidFormat
        }
        return data
    }
}

struct BackupFile: Codable, Sendable {
    static let currentVersion = 2
    var formatVersion = BackupFile.currentVersion
    var createdAt: Date
    /// Page records whose `contentBlob` / revision `contentBlob` name an
    /// entry in `rtfd`; everything else is stored inline.
    var notebooks: [NotebookArchive]
    var savedSearches: [SavedSearch]
    var rtfd: [String: PackedRTFD]
    /// File contents by SHA-256.
    var files: [String: Data]

    init(_ backup: LibraryBackup) throws {
        createdAt = backup.createdAt
        savedSearches = backup.savedSearches
        var rtfd: [String: PackedRTFD] = [:], files: [String: Data] = [:]
        func pack(_ data: inout Data?, into ref: inout String?) {
            guard let bytes = data else { return }
            let key = SyncBlobs.hash(bytes)
            if rtfd[key] == nil {
                guard let packed = PackedRTFD.pack(bytes, into: &files) else { return }
                rtfd[key] = packed
            }
            ref = key; data = nil
        }
        notebooks = try backup.notebooks.map { archive in
            try archive.mappingPages { page in
                guard page.contentBlob == nil, page.spreadsheetBlob == nil, page.historyBlob == nil else {
                    throw LibraryBackup.BackupError.invalidFormat  // sync manifests are never written as backups
                }
                pack(&page.contentData, into: &page.contentBlob)
                // Backups never carry page history, whichever capture produced them.
                page.historyData = nil
                page.history = nil
            }
        }
        self.rtfd = rtfd
        self.files = files
    }

    /// Verifies every stored file, then rebuilds the ordinary in-memory backup.
    func restored() throws -> LibraryBackup {
        guard formatVersion == Self.currentVersion,
              files.allSatisfy({ SyncBlobs.isValidHash($0.key) && SyncBlobs.hash($0.value) == $0.key }) else {
            throw LibraryBackup.BackupError.invalidFormat  // damaged or edited backup
        }
        func unpack(_ data: inout Data?, from ref: inout String?) throws {
            guard let key = ref else { return }
            guard let packed = rtfd[key] else { throw LibraryBackup.BackupError.invalidFormat }
            data = try packed.unpack(from: files)
            ref = nil
        }
        let archives = try notebooks.map { archive in
            try archive.mappingPages { page in
                guard page.spreadsheetBlob == nil, page.historyBlob == nil else { throw LibraryBackup.BackupError.invalidFormat }
                try unpack(&page.contentData, from: &page.contentBlob)
                if let history = page.history {
                    let revisions = try history.map { record -> PageRevision in
                        var record = record
                        guard record.spreadsheetBlob == nil else { throw LibraryBackup.BackupError.invalidFormat }
                        try unpack(&record.revision.contentData, from: &record.contentBlob)
                        return record.revision
                    }
                    page.historyData = try SyncBlobs.portableEncoder.encode(revisions)
                    page.history = nil
                }
            }
        }
        var backup = LibraryBackup(notebooks: archives, savedSearches: savedSearches)
        backup.createdAt = createdAt
        try backup.validate()
        return backup
    }

    // MARK: - Encoding

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    static func isBackupFile(_ data: Data) -> Bool { data.starts(with: Data("bplist".utf8)) }

    static func decode(_ data: Data) throws -> BackupFile {
        let version = try PropertyListDecoder().decode(VersionProbe.self, from: data).formatVersion
        guard version == currentVersion else { throw LibraryBackup.BackupError.invalidFormat }
        return try PropertyListDecoder().decode(BackupFile.self, from: data)
    }

    private struct VersionProbe: Decodable { var formatVersion: Int }
}
