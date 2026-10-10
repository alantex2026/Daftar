//  DragTypes.swift
//  Custom drag payload types so a row only accepts drops that started as a
//  drag of the same kind of thing (a page row won't react to a Finder file
//  drag, a section row won't react to a page drag, and so on).

import Foundation
import UniformTypeIdentifiers

/// The page being dragged right now. The sidebar (drop on a section) and the
/// page list (drop on a page) are separate views, so they share it here.
/// Weak: a cancelled drag never keeps a deleted page alive.
@MainActor
enum PageDrag {
    static weak var current: Page?

    /// The dragged page, if `providers` came from a page drag.
    static func page(from providers: [NSItemProvider]) -> Page? {
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.daftarPage.identifier) }) else { return nil }
        return current
    }
}

extension UTType {
    static let daftarPage     = UTType(exportedAs: "com.alaa.daftar.page")
    static let daftarSection  = UTType(exportedAs: "com.alaa.daftar.section")
    static let daftarNotebook = UTType(exportedAs: "com.alaa.daftar.notebook")
}
