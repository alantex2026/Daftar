import Foundation
import CryptoKit

/// A page revision whose large payloads live in blob files.
struct SyncRevision: Codable, Equatable, Sendable {
    var revision: PageRevision
    var contentBlob: String?
    var spreadsheetBlob: String?
}

/// Sync manifests stay small by moving page content, spreadsheets and each
/// history revision into immutable files named by their SHA-256. An edit then
/// uploads only the payloads that changed, and identical revisions are stored once.
enum SyncBlobs {
    /// Payloads at or below this size stay inline in the manifest.
    static let inlineLimit = 4096

    enum BlobError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            "Waiting for sync files to finish downloading. Daftar will try again shortly."
        }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Replaces large payloads with hashes; `store` receives each payload by hash.
    /// Deterministic, so every device produces identical manifests for identical notes.
    static func dehydrate(_ archive: NotebookArchive, store: inout [String: Data]) -> NotebookArchive {
        func extract(_ data: inout Data?, into ref: inout String?) {
            guard let bytes = data, bytes.count > inlineLimit else { return }
            let key = hash(bytes)
            store[key] = bytes; ref = key; data = nil
        }
        return archive.mappingPages { page in
            extract(&page.contentData, into: &page.contentBlob)
            extract(&page.spreadsheetData, into: &page.spreadsheetBlob)
            // Canonical form: readable history is always a list of revisions,
            // whether it arrived as JSON or straight from revision rows.
            if let json = page.historyData, let revisions = try? JSONDecoder().decode([PageRevision].self, from: json) {
                page.history = revisions.isEmpty ? nil : revisions.map { SyncRevision(revision: $0) }
                page.historyData = nil
            }
            if let history = page.history {
                page.history = history.map { record in
                    var record = record
                    extract(&record.revision.contentData, into: &record.contentBlob)
                    extract(&record.revision.spreadsheetData, into: &record.spreadsheetBlob)
                    return record
                }
            } else {
                extract(&page.historyData, into: &page.historyBlob)
            }
        }
    }

    /// Restores every payload. Throws `BlobError.missing` if one is unavailable,
    /// which leaves the library untouched until the file arrives.
    static func hydrate(_ archive: NotebookArchive, blob: (String) throws -> Data) throws -> NotebookArchive {
        func fill(_ data: inout Data?, from ref: inout String?) throws {
            guard let key = ref else { return }
            data = try blob(key); ref = nil
        }
        return try archive.mappingPages { page in
            try fill(&page.contentData, from: &page.contentBlob)
            try fill(&page.spreadsheetData, from: &page.spreadsheetBlob)
            try fill(&page.historyData, from: &page.historyBlob)
            if let history = page.history {
                let revisions = try history.map { record -> PageRevision in
                    var record = record
                    try fill(&record.revision.contentData, from: &record.contentBlob)
                    try fill(&record.revision.spreadsheetData, from: &record.spreadsheetBlob)
                    return record.revision
                }
                page.historyData = try portableEncoder.encode(revisions)
                page.history = nil
            }
        }
    }

    static var portableEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func references(_ archive: NotebookArchive) -> Set<String> {
        var refs = Set<String>()
        _ = archive.mappingPages { page in
            [page.contentBlob, page.spreadsheetBlob, page.historyBlob].compactMap { $0 }.forEach { refs.insert($0) }
            for record in page.history ?? [] {
                [record.contentBlob, record.spreadsheetBlob].compactMap { $0 }.forEach { refs.insert($0) }
            }
        }
        return refs
    }

    static func url(for key: String, in directory: URL) -> URL {
        directory.appendingPathComponent(String(key.prefix(2)), isDirectory: true).appendingPathComponent(key)
    }

    /// Reads a blob and verifies it, so a partially synced file is never used.
    static func read(_ key: String, in directory: URL) throws -> Data {
        guard isValidHash(key) else { throw LibraryBackup.BackupError.invalidFormat }
        let file = url(for: key, in: directory)
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? FolderSync.coordinatedRead(file), hash(data) == key else { throw BlobError.missing(key) }
        return data
    }

    /// All blob names in the folder with their modification dates.
    static func inventory(in directory: URL) -> [String: Date] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                              options: [.skipsHiddenFiles]) else { return [:] }
        var result: [String: Date] = [:]
        for case let file as URL in enumerator where isValidHash(file.lastPathComponent) {
            result[file.lastPathComponent] = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        return result
    }
}

extension NotebookArchive {
    /// Converts structured history (see `PageRecord.init(structuredHistory:)`)
    /// into the `historyData` JSON that backups and exports contain.
    func withPortableHistory() throws -> NotebookArchive {
        try mappingPages { page in
            guard let history = page.history, history.allSatisfy({ $0.contentBlob == nil && $0.spreadsheetBlob == nil }) else { return }
            page.historyData = try SyncBlobs.portableEncoder.encode(history.map(\.revision))
            page.history = nil
        }
    }

    /// True when any payload was moved out to a blob file.
    var hasBlobReferences: Bool { !SyncBlobs.references(self).isEmpty }

    func mappingPages<E: Error>(_ transform: (inout PageRecord) throws(E) -> Void) throws(E) -> NotebookArchive {
        func page(_ record: PageRecord) throws(E) -> PageRecord {
            var copy = record
            try transform(&copy)
            copy.children = try record.children.map(page)
            return copy
        }
        func section(_ record: SectionRecord) throws(E) -> SectionRecord {
            var copy = record
            copy.pages = try record.pages.map(page)
            copy.children = try record.children.map(section)
            return copy
        }
        var copy = self
        copy.sections = try sections.map(section)
        return copy
    }
}
