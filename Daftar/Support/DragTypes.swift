//  DragTypes.swift
//  Custom drag payload types so a row only accepts drops that started as a
//  drag of the same kind of thing (a page row won't react to a Finder file
//  drag, a section row won't react to a page drag, and so on).

import UniformTypeIdentifiers

extension UTType {
    static let daftarPage     = UTType(exportedAs: "com.alaa.daftar.page")
    static let daftarSection  = UTType(exportedAs: "com.alaa.daftar.section")
    static let daftarNotebook = UTType(exportedAs: "com.alaa.daftar.notebook")
}
