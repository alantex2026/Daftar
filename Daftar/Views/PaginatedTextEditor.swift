//  PaginatedTextEditor.swift
//  The editor for a `.document` page - the same rich text content as a
//  normal note, laid out across fixed, Letter-sized pages instead of one
//  continuous scroll, growing a new page automatically once you type past
//  the bottom margin. Built on TextKit1's documented multi-container
//  pagination pattern: one shared NSTextStorage/NSLayoutManager, and one
//  NSTextView per page, each with its own fixed-size NSTextContainer -
//  all the pages are really just different windows onto the same text.
//
//  Shares image selection, resizing and free positioning with the continuous
//  editor, with save feedback, backlinks and configurable paper sizes.

import SwiftUI
import AppKit

struct PaginatedTextEditor: NSViewRepresentable {
    static let pageSize = NSSize(width: 612, height: 792)   // US Letter at 72dpi
    static let pageMargin: CGFloat = 72                       // 1 inch
    static let pageGap: CGFloat = 28

    let initialData: Data?
    @ObservedObject var controller: EditorController
    var pageID: UUID? = nil
    var paperSize: String = "letter"
    /// Read where the editor is created, so a theme change reaches updateNSView.
    var theme: ColorTheme = ThemeStore.shared.theme
    var onChange: (Data, String, [UUID]) throws -> Void

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onChange: onChange)
        coordinator.appliedTheme = theme
        return coordinator
    }

    func makeNSView(context: Context) -> NSScrollView {
        let savedCursor = pageID.map { SessionStore.latestCursor($0) } ?? 0
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.delegate = context.coordinator
        textStorage.addLayoutManager(layoutManager)

        var loadFailed = false
        do { textStorage.setAttributedString(try initialData.map(PageContentCodec.richTextForEditor) ?? NSAttributedString()) }
        catch { loadFailed = true }

        let pagesView = PaginatedPagesView(layoutManager: layoutManager, textStorage: textStorage, pageSize: Self.size(for: paperSize))
        pagesView.configureImageCanvas(controller: controller)
        context.coordinator.pagesView = pagesView
        context.coordinator.controller = controller
        if loadFailed { pagesView.pages.forEach { $0.isEditable = false } }
        pagesView.onTextChange = { [weak coordinator = context.coordinator, weak controller] in
            controller?.scheduleCountsRefresh()
            coordinator?.scheduleSave(storage: textStorage)
        }
        let router = context.coordinator.linkRouter
        pagesView.onLink = { link, index, textView in router.handle(link, at: index, in: textView) }
        pagesView.onSelectionChange = { [weak controller] textView in
            controller?.textView = textView
            controller?.refreshState()
            if let pageID { SessionStore.rememberCursor(textView.selectedRange().location, id: pageID) }
        }

        let scrollView = NSScrollView()
        scrollView.documentView = pagesView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 3.0

        DispatchQueue.main.async {
            pagesView.requestCursorRestore(savedCursor)
            controller.textView = pagesView.restoredCursorView ?? pagesView.pages.first
            controller.refreshCounts()
            controller.refreshState()
            controller.saveState = .idle
            if loadFailed { controller.errorMessage = "This page couldn't be read. Its original data has been preserved." }
            // Sheets are laid out lazily, so matches are highlighted without
            // scrolling (the cursor restore above owns the scroll position).
            if let pageID, let query = SearchHighlight.take(for: pageID), let first = pagesView.pages.first {
                pagesView.showsSearchHighlight = SearchHighlight.apply(query, to: first, scroll: false) > 0
            }
        }

        return scrollView
    }

    static func size(for name: String) -> NSSize {
        switch name {
        case "a4": return NSSize(width: 595.28, height: 841.89)
        case "legal": return NSSize(width: 612, height: 1008)
        default: return pageSize
        }
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.pagesView?.setPageSize(Self.size(for: paperSize))
        if context.coordinator.appliedTheme != theme {
            context.coordinator.appliedTheme = theme
            context.coordinator.pagesView?.applyTheme()
        }
        if abs(scrollView.magnification - CGFloat(controller.zoom)) > 0.001 {
            scrollView.magnification = CGFloat(controller.zoom)
        }
        if !context.coordinator.didFocusOnAppear, let window = scrollView.window,
           let firstPage = context.coordinator.pagesView?.restoredCursorView ?? context.coordinator.pagesView?.pages.first {
            context.coordinator.didFocusOnAppear = true
            window.makeFirstResponder(firstPage)
            firstPage.scrollRangeToVisible(firstPage.selectedRange())
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.flush()
        coordinator.pagesView?.pageUndoManager.removeAllActions()
        if let current = coordinator.controller?.textView,
           coordinator.pagesView?.pages.contains(where: { $0 === current }) == true {
            coordinator.controller?.textView = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency NSLayoutManagerDelegate {
        private let autosaver: RichTextAutosaver
        weak var pagesView: PaginatedPagesView?
        var appliedTheme: ColorTheme?
        var didFocusOnAppear = false
        weak var controller: EditorController? { didSet { linkRouter.controller = controller } }
        let linkRouter = EditorLinkRouter()

        init(onChange: @escaping (Data, String, [UUID]) throws -> Void) {
            autosaver = RichTextAutosaver(onChange: onChange)
        }

        func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
            pagesView?.layoutManagerDidCompleteLayout(for: textContainer, atEnd: layoutFinishedFlag)
        }

        func scheduleSave(storage: NSTextStorage) {
            autosaver.schedule(storage, controller: controller) { [weak pagesView] controller in
                guard let current = controller.textView else { return false }
                return pagesView?.pages.contains { $0 === current } == true
            }
        }

        func flush() { autosaver.flush() }
    }
}

/// Hosts one NSTextView "sheet" per page, all sharing one NSLayoutManager/
/// NSTextStorage, stacked vertically with a gap between them so each page
/// reads as a distinct sheet of paper.
final class PaginatedPagesView: NSView {
    private let layoutManager: NSLayoutManager
    private let textStorage: NSTextStorage
    private(set) var pages: [NSTextView] = []
    let pageUndoManager = UndoManager()
    private(set) var imageCanvas: ImageCanvas?
    weak var editorController: EditorController?
    var onTextChange: (() -> Void)?
    var onSelectionChange: ((NSTextView) -> Void)?
    var onLink: ((Any, Int, NSTextView) -> Bool)?

    private var pageSize: NSSize
    private var trimming = false
    private var pendingCursor: Int?
    private(set) weak var restoredCursorView: NSTextView?
    /// Set while search matches are highlighted; the first edit clears them.
    var showsSearchHighlight = false
    private let margin = PaginatedTextEditor.pageMargin
    private let gap = PaginatedTextEditor.pageGap

    init(layoutManager: NSLayoutManager, textStorage: NSTextStorage, pageSize: NSSize = PaginatedTextEditor.pageSize) {
        self.pageSize = pageSize
        self.layoutManager = layoutManager
        self.textStorage = textStorage
        super.init(frame: .zero)
        addPage()
        layoutPages()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Sheet, default text, selection and caret colors from the color theme.
    func applyTheme() {
        let themeTexts = ColorTheme.allCases.map(\.palette.documentText)
        for case let page as DaftarTextView in pages {
            page.backgroundColor = AppTheme.documentPage
            // Only swap a theme's own default text color, never one the person chose.
            if let current = page.typingAttributes[.foregroundColor] as? NSColor, themeTexts.contains(current) {
                page.typingAttributes[.foregroundColor] = AppTheme.documentText
            }
            page.applyTheme()
        }
    }

    func configureImageCanvas(controller: EditorController) {
        editorController = controller
        let canvas = ImageCanvas(host: self, storage: textStorage, controller: controller) { [weak self] in self?.pages ?? [] }
        imageCanvas = canvas
        for case let page as DaftarTextView in pages { page.controller = controller; page.imageCanvas = canvas }
        canvas.onExtentChange = { [weak self] height in
            guard let self else { return }
            while height > self.frame.height, self.pages.count < 200 {
                self.addPage()
                self.layoutPages()
            }
        }
        canvas.sync()
    }

    /// Keep a picture on one printable sheet when dropping across page gaps.
    func imageRectOnSheet(_ proposed: NSRect) -> NSRect {
        let stride = pageSize.height + gap
        let sheetTop = floor(proposed.minY / stride) * stride
        let scale = min(1, pageSize.width / proposed.width, pageSize.height / proposed.height)
        let size = NSSize(width: proposed.width * scale, height: proposed.height * scale)
        return NSRect(x: min(proposed.minX, pageSize.width - size.width),
                      y: max(sheetTop, min(proposed.minY, sheetTop + pageSize.height - size.height)),
                      width: size.width, height: size.height)
    }

    var printedPageSize: NSSize { pageSize }
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pages.count)
        return true
    }
    override func rectForPage(_ page: Int) -> NSRect {
        guard (1...pages.count).contains(page) else { return .zero }
        return pages[page - 1].frame
    }

    func requestCursorRestore(_ location: Int) {
        pendingCursor = min(max(0, location), textStorage.length)
        restoreCursorIfLaidOut()
    }

    private func restoreCursorIfLaidOut() {
        guard let location = pendingCursor else { return }
        if let last = pages.last?.textContainer { layoutManager.ensureLayout(for: last) }
        let target = pages.first { page in
            guard let container = page.textContainer else { return false }
            let glyphs = layoutManager.glyphRange(for: container)
            let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            if textStorage.length == 0 { return page === pages.first }
            return NSLocationInRange(location, characters)
                || (location == textStorage.length && NSMaxRange(characters) == location && characters.length > 0)
        }
        guard let target else { return }
        pendingCursor = nil
        restoredCursorView = target
        target.setSelectedRange(NSRange(location: location, length: 0))
        window?.makeFirstResponder(target)
        target.scrollRangeToVisible(target.selectedRange())
    }

    func setPageSize(_ size: NSSize) {
        guard pageSize != size else { return }
        pageSize = size
        for page in pages {
            page.textContainer?.containerSize = NSSize(width: size.width - margin * 2, height: size.height - margin * 2)
        }
        layoutPages()
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length))
        trimEmptyPages()
    }

    func trimEmptyPages() {
        guard !trimming, pages.count > 1 else { return }
        trimming = true
        defer { trimming = false }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length))
        while pages.count > 1, let last = pages.last, let container = last.textContainer,
              layoutManager.glyphRange(for: container).length == 0 {
            if (imageCanvas?.extent ?? 0) > last.frame.minY { break }
            // Preserve the extra line fragment needed by a final newline.
            if layoutManager.extraLineFragmentTextContainer === container && textStorage.length > 0 { break }
            if window?.firstResponder === last { window?.makeFirstResponder(pages[pages.count - 2]) }
            layoutManager.removeTextContainer(at: pages.count - 1)
            pages.removeLast().removeFromSuperview()
        }
        layoutPages()
    }

    private func addPage() {
        let container = NSTextContainer(containerSize: NSSize(width: pageSize.width - margin * 2,
                                                                height: pageSize.height - margin * 2))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = DaftarTextView(frame: NSRect(origin: .zero, size: pageSize), textContainer: container)
        textView.controller = editorController
        textView.imageCanvas = imageCanvas
        textView.allowsImageEditing = false
        // Disable the macOS image-extension rollover button (including Markup).
        textView.usesRolloverButtonForSelection = false
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = true
        textView.appearance = NSAppearance(named: .aqua)
        textView.backgroundColor = AppTheme.documentPage
        textView.textContainerInset = NSSize(width: margin, height: margin)
        textView.typingAttributes = [.font: EditorController.defaultFont, .foregroundColor: AppTheme.documentText]
        textView.applyTheme()
        textView.delegate = self
        textView.wantsLayer = true
        textView.layer?.shadowColor = NSColor.black.cgColor
        textView.layer?.shadowOpacity = 0.3
        textView.layer?.shadowRadius = 5
        textView.layer?.shadowOffset = CGSize(width: 0, height: -2)

        addSubview(textView, positioned: .below, relativeTo: nil)
        pages.append(textView)
    }

    /// Called by the layout manager's delegate whenever a page finishes
    /// laying out. If the *last* page just filled up and there's more
    /// text still waiting, grow another page. Empty trailing pages are trimmed
    /// after edits, outside the layout callback, to avoid reentrant TextKit mutation.
    ///
    /// The actual `addPage()` is deferred to the next run loop turn
    /// rather than called from here directly: creating the new NSTextView
    /// and setting its properties (e.g. `drawsBackground`) triggers its
    /// own layout queries against this same, still-mid-callback layout
    /// manager, which re-enters this exact delegate method - synchronously
    /// calling `addPage()` here causes unbounded recursion and a stack
    /// overflow once a document runs more than a couple of pages long.
    func layoutManagerDidCompleteLayout(for textContainer: NSTextContainer?, atEnd: Bool) {
        if atEnd, pendingCursor != nil {
            DispatchQueue.main.async { [weak self] in self?.restoreCursorIfLaidOut() }
        }
        guard let textContainer, !atEnd,
              let index = pages.firstIndex(where: { $0.textContainer === textContainer }),
              index == pages.count - 1 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.addPageIfStillLast(index)
        }
    }

    /// Re-checks that `index` is still the last page before actually
    /// adding one - by the time this deferred call runs, another
    /// already-queued completion (or a user edit) may have grown the
    /// document further, and we don't want to double-add for the same
    /// overflow signal.
    private func addPageIfStillLast(_ index: Int) {
        guard index == pages.count - 1, let container = pages.last?.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let range = layoutManager.glyphRange(for: container)
        // A queued overflow callback may be stale after deleting text. Also
        // require progress so an oversized attachment cannot create endless pages.
        guard range.length > 0, NSMaxRange(range) < layoutManager.numberOfGlyphs else { return }
        addPage()
        layoutPages()
        // AppKit can lay out a new container during NSTextView initialization,
        // before that view is in `pages`. Its delegate callback is then too early
        // to recognize the last page, so explicitly check for remaining glyphs.
        guard let last = pages.last?.textContainer else { return }
        layoutManager.ensureLayout(for: last)
        let lastRange = layoutManager.glyphRange(for: last)
        if lastRange.length > 0, NSMaxRange(lastRange) < layoutManager.numberOfGlyphs {
            let nextIndex = pages.count - 1
            DispatchQueue.main.async { [weak self] in self?.addPageIfStillLast(nextIndex) }
        }
    }

    private func layoutPages() {
        var y: CGFloat = 0
        for page in pages {
            page.frame = NSRect(x: 0, y: y, width: pageSize.width, height: pageSize.height)
            y += pageSize.height + gap
        }
        frame.size = NSSize(width: pageSize.width, height: max(pageSize.height, y - gap))
        restoreCursorIfLaidOut()
    }
}

extension PaginatedPagesView: NSTextViewDelegate {
    /// One undo history for this document (all its sheets share the text), not
    /// the window's - see `RichTextEditor.Coordinator.undoManager`.
    func undoManager(for view: NSTextView) -> UndoManager? { pageUndoManager }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        onSelectionChange?(textView)
        return onLink?(link, charIndex, textView) ?? false
    }
    func textDidChange(_ notification: Notification) {
        if showsSearchHighlight, let first = pages.first {
            SearchHighlight.clear(in: first)  // all sheets share one layout manager
            showsSearchHighlight = false
        }
        imageCanvas?.sync()
        onTextChange?()
        DispatchQueue.main.async { [weak self] in self?.trimEmptyPages() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        onSelectionChange?(textView)
        imageCanvas?.sync()
    }
}
