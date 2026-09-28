//  PageTemplates.swift
//  Starter content for "New Page From Template". Builds plain RTFD data
//  using the exact same conventions EditorController's live text-editing
//  commands produce - heading fonts from `TextStyle`, "• " for bullets,
//  "☐ " for checklist items - so a template reads and behaves exactly
//  like a page a person built by hand with the toolbar. Checklist glyphs
//  don't need to be marked clickable here: RichTextEditor re-marks every
//  checklist glyph in a page the moment it loads.

import AppKit

enum PageTemplate: String, CaseIterable, Identifiable {
    case blank        = "Blank Page"
    case meetingNotes = "Meeting Notes"
    case dailyJournal = "Daily Journal"
    case todoList     = "To-Do List"
    case cornellNotes = "Cornell Notes"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .blank:        return "doc"
        case .meetingNotes: return "person.2"
        case .dailyJournal: return "sun.max"
        case .todoList:     return "checklist"
        case .cornellNotes: return "rectangle.split.3x1"
        }
    }

    /// This template's starter page title. `nil` for `.blank`, which keeps
    /// the normal "Untitled" a fresh page gets.
    var pageTitle: String? {
        self == .blank ? nil : rawValue
    }

    /// Ready-to-store `Page.contentData`, or `nil` for `.blank` (an empty
    /// page has no content at all, same as one created the normal way).
    var contentData: Data? {
        guard let body = attributedBody else { return nil }
        return try? body.data(from: NSRange(location: 0, length: body.length),
                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }

    /// The plain-text copy of the above, kept in sync the same way
    /// `PageEditorView` keeps `Page.plainText` in sync on every save - it's
    /// what page search matches against.
    var plainText: String {
        attributedBody?.string ?? ""
    }

    private var attributedBody: NSAttributedString? {
        let builder = TemplateBuilder()
        switch self {
        case .blank:
            return nil

        case .meetingNotes:
            builder.heading1("Meeting Notes")
            builder.normal("Date: ")
            builder.normal("Attendees: ")
            builder.blank()
            builder.heading2("Agenda")
            builder.bullets(count: 3)
            builder.heading2("Notes")
            builder.blank()
            builder.heading2("Action Items")
            builder.checklist(count: 3)

        case .dailyJournal:
            builder.heading1("Daily Journal")
            builder.normal("Date: ")
            builder.blank()
            builder.heading2("Today I'm Grateful For")
            builder.bullets(count: 3)
            builder.heading2("Notes")
            builder.blank()
            builder.heading2("Tomorrow's Priorities")
            builder.checklist(count: 3)

        case .todoList:
            builder.heading1("To-Do List")
            builder.checklist(count: 6)

        case .cornellNotes:
            builder.heading1("Cornell Notes")
            builder.normal("Topic: ")
            builder.normal("Date: ")
            builder.blank()
            builder.heading2("Cues")
            builder.bullets(count: 3)
            builder.heading2("Notes")
            builder.blank()
            builder.heading2("Summary")
            builder.blank()
        }
        return builder.result
    }

    private final class TemplateBuilder {
        let result = NSMutableAttributedString()

        private func append(_ string: String, font: NSFont) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.textColor
            ]
            result.append(NSAttributedString(string: string, attributes: attrs))
        }

        func heading1(_ text: String) { append(text, font: EditorController.TextStyle.heading1.font) }
        func heading2(_ text: String) { append(text, font: EditorController.TextStyle.heading2.font) }
        func normal(_ text: String) { append(text, font: EditorController.TextStyle.normal.font) }
        func blank() { append("", font: EditorController.TextStyle.normal.font) }

        func bullets(count: Int) {
            for _ in 0..<count { append("• ", font: EditorController.TextStyle.normal.font) }
        }

        func checklist(count: Int) {
            for _ in 0..<count { append("\u{2610} ", font: EditorController.TextStyle.normal.font) }
        }
    }
}
