//  DaftarModelTests.swift
//  Model-layer regression tests: sort-index bookkeeping, cascade delete,
//  and the Trash (soft-delete) filtering that keeps trashed items out of
//  the tree without needing to touch every descendant's own `deletedAt`.

import XCTest
import SwiftData
@testable import Daftar

final class DaftarModelTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Notebook.self, NoteSection.self, Page.self,
                                           configurations: config)
        return ModelContext(container)
    }

    // MARK: - Sort-index bookkeeping

    func testNextRootPageIndexTracksExistingPages() throws {
        let context = try makeContext()
        let section = NoteSection(name: "Section")
        context.insert(section)
        XCTAssertEqual(section.nextRootPageIndex, 0)

        let first = Page(title: "A", sortIndex: section.nextRootPageIndex)
        first.section = section
        context.insert(first)
        XCTAssertEqual(section.nextRootPageIndex, 1)

        let second = Page(title: "B", sortIndex: section.nextRootPageIndex)
        second.section = section
        context.insert(second)
        XCTAssertEqual(section.nextRootPageIndex, 2)
    }

    func testNextChildIndexIsIndependentPerParent() throws {
        let context = try makeContext()
        let section = NoteSection(name: "Section")
        context.insert(section)
        let parent = Page(title: "Parent", sortIndex: 0)
        parent.section = section
        context.insert(parent)

        XCTAssertEqual(parent.nextChildIndex, 0)
        let child = Page(title: "Child", sortIndex: parent.nextChildIndex)
        child.parent = parent
        child.section = section
        context.insert(child)
        XCTAssertEqual(parent.nextChildIndex, 1)
    }

    // MARK: - Cascade delete

    func testDeletingSectionCascadesToItsPages() throws {
        let context = try makeContext()
        let notebook = Notebook(name: "Notebook")
        context.insert(notebook)
        let section = NoteSection(name: "Section")
        section.notebook = notebook
        context.insert(section)
        let page = Page(title: "Page")
        page.section = section
        context.insert(page)

        context.delete(section)
        try context.save()

        XCTAssertTrue(try context.fetch(FetchDescriptor<Page>()).isEmpty)
    }

    func testDeletingPageCascadesToSubPages() throws {
        let context = try makeContext()
        let section = NoteSection(name: "Section")
        context.insert(section)
        let parent = Page(title: "Parent")
        parent.section = section
        context.insert(parent)
        let child = Page(title: "Child")
        child.section = section
        child.parent = parent
        context.insert(child)

        context.delete(parent)
        try context.save()

        XCTAssertTrue(try context.fetch(FetchDescriptor<Page>()).isEmpty)
    }

    // MARK: - Trash (soft delete)

    func testTrashingANotebookHidesItsSectionsFromTopLevel() throws {
        let context = try makeContext()
        let notebook = Notebook(name: "Notebook")
        context.insert(notebook)
        let section = NoteSection(name: "Section")
        section.notebook = notebook
        context.insert(section)

        XCTAssertEqual(notebook.topLevelSections.count, 1)
        notebook.deletedAt = Date()

        XCTAssertTrue(section.isTrashed, "a section's ancestor being trashed should trash the section too")
        XCTAssertEqual(notebook.topLevelSections.count, 0)
    }

    func testTrashingASectionHidesItsPagesWithoutTouchingThePage() throws {
        let context = try makeContext()
        let section = NoteSection(name: "Section")
        context.insert(section)
        let page = Page(title: "Page")
        page.section = section
        context.insert(page)

        XCTAssertEqual(section.rootPages.count, 1)
        section.deletedAt = Date()

        XCTAssertNil(page.deletedAt, "trashing a section should not need to write to its pages")
        XCTAssertTrue(page.isTrashed, "a page should read as trashed if its section is trashed")
        XCTAssertEqual(section.rootPages.count, 0)
    }

    func testTrashingAPageHidesItsSubPagesFromCounts() throws {
        let context = try makeContext()
        let section = NoteSection(name: "Section")
        context.insert(section)
        let parent = Page(title: "Parent")
        parent.section = section
        context.insert(parent)
        let child = Page(title: "Child")
        child.section = section
        child.parent = parent
        context.insert(child)

        XCTAssertTrue(parent.hasChildren)
        parent.deletedAt = Date()

        XCTAssertTrue(child.isTrashed)
        XCTAssertEqual(section.totalPageCount, 0,
                       "trashing the parent should remove it and its child from the section's live count")
    }

    func testRestoringAPageAloneDoesNotSurfaceItWhileItsSectionIsStillTrashed() throws {
        let context = try makeContext()
        let section = NoteSection(name: "Section")
        context.insert(section)
        let page = Page(title: "Page")
        page.section = section
        context.insert(page)

        section.deletedAt = Date()
        page.deletedAt = Date()

        // Restore only the page, leaving its section trashed - this is the
        // scenario TrashView.restore() guards against by also restoring ancestors.
        page.deletedAt = nil

        XCTAssertTrue(page.isTrashed, "a page can't be visible while its section is still in the Trash")
    }
}
