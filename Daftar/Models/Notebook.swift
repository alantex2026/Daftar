//  Notebook.swift
//  Level 1 of the app: a Notebook holds Sections.

import Foundation
import SwiftData

@Model
final class Notebook {
    var name: String = "New Notebook"
    var colorName: String = "teal"
    var sortIndex: Int = 0
    var isExpanded: Bool = true
    var createdAt: Date = Date()

    /// Set when the notebook is moved to the Trash. `nil` means it is live.
    var deletedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \NoteSection.notebook)
    var sections: [NoteSection] = []

    init(name: String, colorName: String = "teal", sortIndex: Int = 0) {
        self.name = name
        self.colorName = colorName
        self.sortIndex = sortIndex
        self.isExpanded = true
        self.createdAt = Date()
    }

    var isTrashed: Bool { deletedAt != nil }

    /// Sections directly under the notebook (not the ones inside a group), excluding trashed ones.
    var topLevelSections: [NoteSection] {
        sections.filter { $0.parent == nil && !$0.isTrashed }.sorted { $0.sortIndex < $1.sortIndex }
    }

    var nextSectionIndex: Int { (sections.map(\.sortIndex).max() ?? -1) + 1 }
}
