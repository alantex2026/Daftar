//  PageRevisionEntry.swift
//  One saved version of a page. Each version is its own row, so saving a
//  new one inserts a row instead of re-encoding the page's whole history.

import Foundation
import SwiftData

@Model
final class PageRevisionEntry {
    var revisionID: UUID = UUID()
    var capturedAt: Date = Date()
    /// Newest has the highest number; keeps order stable even when two
    /// versions share a timestamp.
    var sequence: Int = 0
    var title: String = ""
    var kind: Int = 0
    var contentData: Data?
    var spreadsheetData: Data?
    var plainText: String = ""
    var outgoingLinkIDs: [UUID] = []
    var customTags: [String] = []
    var tagRaw: Int = 0
    var paperSize: String = "letter"
    /// Counted against `PageHistory.byteLimit`.
    var byteSize: Int = 0
    var payload: PagePayload?

    init(_ revision: PageRevision, sequence: Int) {
        revisionID = revision.id
        capturedAt = revision.capturedAt
        self.sequence = sequence
        title = revision.title
        kind = revision.kind
        contentData = revision.contentData
        spreadsheetData = revision.spreadsheetData
        plainText = revision.plainText
        outgoingLinkIDs = revision.outgoingLinkIDs
        customTags = revision.customTags
        tagRaw = revision.tagRaw
        paperSize = revision.paperSize
        byteSize = PageHistory.size(of: revision)
    }

    var revision: PageRevision {
        PageRevision(id: revisionID, capturedAt: capturedAt, title: title, kind: kind,
                     contentData: contentData, spreadsheetData: spreadsheetData, plainText: plainText,
                     outgoingLinkIDs: outgoingLinkIDs, customTags: customTags, tagRaw: tagRaw, paperSize: paperSize)
    }
}
