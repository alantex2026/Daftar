//  SampleData.swift
//  Builds the "User Guide" notebook the first time the app opens,
//  so the app never starts empty.

import Foundation
import SwiftData

enum SampleData {

    static func seedIfNeeded(context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<Notebook>())) ?? 0
        guard existing == 0 else { return }

        let guide = Notebook(name: "User Guide", colorName: "teal", sortIndex: 0)
        context.insert(guide)

        let explore = NoteSection(name: "Explore Daftar", colorName: "blue", sortIndex: 0)
        explore.notebook = guide
        context.insert(explore)

        // A tiny helper so the tree below stays easy to read.
        var index = 0
        func page(_ title: String, parent: Page? = nil, tag: PageTag = .none) -> Page {
            let p = Page(title: title, sortIndex: parent == nil ? index : parent!.nextChildIndex)
            if parent == nil { index += 1 }
            p.section = explore
            p.parent = parent
            p.tagRaw = tag.rawValue
            context.insert(p)
            return p
        }

        _ = page("User Guide Map", tag: .star)
        _ = page("Daftar Basics")

        let taking = page("Taking Notes")
        _ = page("Saving Your Notes", parent: taking)
        _ = page("Text Styles", parent: taking)
        _ = page("Lists", parent: taking)
        _ = page("Tags", parent: taking, tag: .question)
        _ = page("Tables", parent: taking)
        _ = page("Links", parent: taking)
        _ = page("Images", parent: taking)
        let attachments = page("File Attachments", parent: taking)
        _ = page("Printouts", parent: attachments)
        _ = page("Spellcheck and Word Count", parent: taking)

        let organizing = page("Organizing Notes")
        _ = page("Notebooks", parent: organizing)
        let sections = page("Sections", parent: organizing)
        _ = page("Section Groups", parent: sections)
        let pages = page("Pages", parent: organizing)
        _ = page("Sub-pages", parent: pages)
        _ = page("Recent Pages", parent: pages)

        let second = NoteSection(name: "Scratch Pad", colorName: "orange", sortIndex: 1)
        second.notebook = guide
        context.insert(second)
        let scratch = Page(title: "Quick Notes", sortIndex: 0)
        scratch.section = second
        context.insert(scratch)

        try? context.save()
    }
}
