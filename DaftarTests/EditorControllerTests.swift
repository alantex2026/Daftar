//  EditorControllerTests.swift
//  Coverage for the checklist parsing/marking helpers, which are pure
//  enough to test without a live NSTextView.

import XCTest
import AppKit
@testable import Daftar

@MainActor
final class EditorControllerTests: XCTestCase {

    /// The tests run inside the app and read its real preferences; pin the
    /// insert size to Medium (100%) so a personal choice of Small or Large
    /// doesn't change what they measure. Tests that need another size set it.
    private var savedImageSize: Any?
    override func setUp() {
        super.setUp()
        savedImageSize = UserDefaults.standard.object(forKey: AppSettings.defaultImageSize)
        UserDefaults.standard.set(InsertedImageSize.medium.rawValue, forKey: AppSettings.defaultImageSize)
    }
    override func tearDown() {
        UserDefaults.standard.set(savedImageSize, forKey: AppSettings.defaultImageSize)
        super.tearDown()
    }

    func testChecklistContentReturnsNilForPlainText() {
        XCTAssertNil(EditorController.checklistContent(of: "just a line"))
    }

    func testChecklistContentParsesUncheckedLine() {
        let result = EditorController.checklistContent(of: "\u{2610} buy milk")
        XCTAssertEqual(result?.checked, false)
        XCTAssertEqual(result?.text, "buy milk")
    }

    func testChecklistContentParsesCheckedLine() {
        let result = EditorController.checklistContent(of: "\u{2611} buy milk")
        XCTAssertEqual(result?.checked, true)
        XCTAssertEqual(result?.text, "buy milk")
    }

    func testImageSizePresetResolvesFractionOfContainerWidth() {
        let width = EditorController.ImageSizePreset.medium.resolvedWidth(containerWidth: 600, naturalWidth: 2000)
        XCTAssertEqual(width, 300)
    }

    func testImageSizePresetMediumNeverUpscalesPastNaturalWidth() {
        let width = EditorController.ImageSizePreset.medium.resolvedWidth(containerWidth: 600, naturalWidth: 200)
        XCTAssertEqual(width, 200)
    }

    func testImageSizePresetFullWidthAlwaysReachesContainerEdge() {
        // Full Width is a literal request, unlike Small/Medium/Large - it
        // should reach the container's edge even for a small image whose
        // natural size is well under it.
        let width = EditorController.ImageSizePreset.fullWidth.resolvedWidth(containerWidth: 600, naturalWidth: 200)
        XCTAssertEqual(width, 600)
    }

    func testImageSizePresetOriginalIgnoresContainerWidth() {
        let width = EditorController.ImageSizePreset.original.resolvedWidth(containerWidth: 600, naturalWidth: 2000)
        XCTAssertEqual(width, 2000)
    }

    func testNearestSnapWidthSnapsWithinTolerance() {
        // Container is 600pt wide, so 50% is 300pt; a drag that lands a
        // few points short of that should snap to exactly 300.
        let snapped = EditorController.nearestSnapWidth(to: 292, containerWidth: 600)
        XCTAssertEqual(snapped, 300)
    }

    func testNearestSnapWidthReturnsNilOutsideTolerance() {
        let snapped = EditorController.nearestSnapWidth(to: 400, containerWidth: 600)
        XCTAssertNil(snapped)
    }

    func testNearestSnapWidthReturnsNilWhenAlreadyExact() {
        let snapped = EditorController.nearestSnapWidth(to: 300, containerWidth: 600)
        XCTAssertNil(snapped)
    }

    func testIsImageAttachmentTrueForImageFilename() {
        let wrapper = FileWrapper(regularFileWithContents: Data())
        wrapper.preferredFilename = "photo.png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let storage = NSTextStorage(attributedString: NSAttributedString(attachment: attachment))
        XCTAssertTrue(EditorController.isImageAttachment(attachment, at: 0, in: storage))
    }

    func testIsImageAttachmentFalseForNonImageFilename() {
        let wrapper = FileWrapper(regularFileWithContents: Data())
        wrapper.preferredFilename = "notes.pdf"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let storage = NSTextStorage(attributedString: NSAttributedString(attachment: attachment))
        XCTAssertFalse(EditorController.isImageAttachment(attachment, at: 0, in: storage))
    }

    func testIsImageAttachmentFalseWithoutFileWrapper() {
        let storage = NSTextStorage(attributedString: NSAttributedString(attachment: NSTextAttachment()))
        XCTAssertFalse(EditorController.isImageAttachment(NSTextAttachment(), at: 0, in: storage))
    }

    /// A `.png` inserted via "File Attachment..." should keep the file-icon
    /// affordance, not the image resize handles - even though its filename
    /// alone would look exactly like a real inserted picture.
    func testIsImageAttachmentFalseForFileAttachmentWithImageExtension() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let controller = EditorController()
        let textView = NSTextView()
        controller.textView = textView
        controller.insertFileAttachment(from: fileURL)
        guard let storage = textView.textStorage,
              let attachment = storage.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment else {
            return XCTFail("Expected an attachment to have been inserted")
        }
        XCTAssertFalse(EditorController.isImageAttachment(attachment, at: 0, in: storage))
    }

    func testGalleryColumnsForCommonCounts() {
        XCTAssertEqual(EditorController.galleryColumns(for: 1), 1)
        XCTAssertEqual(EditorController.galleryColumns(for: 2), 2)
        XCTAssertEqual(EditorController.galleryColumns(for: 3), 3)
        XCTAssertEqual(EditorController.galleryColumns(for: 4), 2)
        XCTAssertEqual(EditorController.galleryColumns(for: 5), 3)
        XCTAssertEqual(EditorController.galleryColumns(for: 9), 3)
    }

    func testGalleryColumnsNeverExceedsPhotoCount() {
        for count in 1...12 {
            XCTAssertLessThanOrEqual(EditorController.galleryColumns(for: count), count)
        }
    }

    /// Builds an EditorController wired to a real (off-screen) NSTextView,
    /// the same TextKit1 stack RichTextEditor builds by hand - so these
    /// tests exercise the actual resize code path end to end instead of
    /// just its pure-math helpers.
    private func makeHarness(containerWidth: CGFloat = 600) -> (EditorController, NSTextView, NSTextStorage) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: containerWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 800), textContainer: container)

        let controller = EditorController()
        controller.textView = textView
        return (controller, textView, textStorage)
    }

    private func makeTestImagePNG(width: Int, height: Int) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let bitmap = NSBitmapImageRep(data: tiff)!
        return bitmap.representation(using: .png, properties: [:])!
    }

    func testSetImageSizeActuallyChangesAttachmentBounds() {
        let (controller, _, storage) = makeHarness(containerWidth: 600)
        let previous = UserDefaults.standard.object(forKey: AppSettings.defaultImageSize)
        defer { UserDefaults.standard.set(previous, forKey: AppSettings.defaultImageSize) }
        UserDefaults.standard.set("medium", forKey: AppSettings.defaultImageSize)
        controller.insertImage(data: makeTestImagePNG(width: 1000, height: 600), filename: "test.png")

        guard let attachment = storage.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment else {
            XCTFail("expected an image attachment at location 0")
            return
        }
        // Insert keeps the image within the 600pt page, not its raw 1000pt size.
        XCTAssertEqual(attachment.bounds.width, 600, accuracy: 0.5)

        controller.setImageSize(at: NSRange(location: 0, length: 1), to: .original)

        XCTAssertEqual(attachment.bounds.width, 1000, accuracy: 0.5,
                        "setImageSize(.original) should restore the image's natural 1000pt width")
    }

    func testResizeImageChangesAttachmentBounds() {
        let (controller, _, storage) = makeHarness(containerWidth: 600)
        controller.insertImage(data: makeTestImagePNG(width: 200, height: 100), filename: "test.png")

        guard let attachment = storage.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment else {
            XCTFail("expected an image attachment at location 0")
            return
        }
        let initialWidth = attachment.bounds.width

        controller.resizeImage(attachment: attachment, range: NSRange(location: 0, length: 1),
                                toWidth: initialWidth + 120, naturalSize: NSSize(width: 200, height: 100))

        XCTAssertNotEqual(attachment.bounds.width, initialWidth,
                           "dragging a resize handle should change the attachment's rendered width")
    }

    func testResizeImageCanGrowPastNaturalWidth() {
        // Regression test: resizeImage used to clamp `min(width, naturalWidth)`,
        // which silently no-opped any outward drag once an image was at or
        // near its native pixel width - the common case, since anything
        // under the 520pt insert cap starts out exactly at natural size.
        let (controller, _, storage) = makeHarness(containerWidth: 600)
        controller.insertImage(data: makeTestImagePNG(width: 200, height: 100), filename: "test.png")

        guard let attachment = storage.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment else {
            XCTFail("expected an image attachment at location 0")
            return
        }
        XCTAssertEqual(attachment.bounds.width, 200, accuracy: 0.5, "sanity: starts at natural width")

        controller.resizeImage(attachment: attachment, range: NSRange(location: 0, length: 1),
                                toWidth: 350, naturalSize: NSSize(width: 200, height: 100))

        XCTAssertEqual(attachment.bounds.width, 350, accuracy: 0.5,
                        "dragging outward past natural width should be allowed, like any other rich text editor")
    }

    func testMarkChecklistGlyphsAddsLinkOnlyToChecklistLines() {
        let storage = NSTextStorage(string: "\u{2610} task one\nplain line\n\u{2611} task two")
        let full = NSRange(location: 0, length: storage.length)

        EditorController.markChecklistGlyphs(in: full, storage: storage)

        // First glyph (task one, unchecked) is linked.
        let firstLink = storage.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertEqual(firstLink?.absoluteString, "daftar://checklist-toggle")

        // "plain line" never gets a link attribute anywhere in its range.
        let plainLineStart = (storage.string as NSString).range(of: "plain line").location
        XCTAssertNil(storage.attribute(.link, at: plainLineStart, effectiveRange: nil))

        // Second glyph (task two, checked) is also linked.
        let secondGlyphIndex = (storage.string as NSString).range(of: "\u{2611}").location
        let secondLink = storage.attribute(.link, at: secondGlyphIndex, effectiveRange: nil) as? URL
        XCTAssertEqual(secondLink?.absoluteString, "daftar://checklist-toggle")
    }

    func testInsertedImagesUseTheDefaultSizeSetting() {
        let key = AppSettings.defaultImageSize
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        for (setting, expected) in [("small", 150.0), ("medium", 300.0), ("large", 450.0)] {
            UserDefaults.standard.set(setting, forKey: key)
            let (controller, _, storage) = makeHarness(containerWidth: 600)
            controller.insertImage(data: makeTestImagePNG(width: 300, height: 200), filename: "photo.png")
            let attachment = storage.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
            XCTAssertEqual(attachment?.bounds.width ?? 0, expected, accuracy: 0.5, "\(setting): 50% / 100% / 150% of 300pt")
            XCTAssertEqual(attachment?.bounds.height ?? 0, expected * 200 / 300, accuracy: 0.5, "\(setting) keeps the aspect ratio")
        }
    }

    func testDefaultImageSizeStaysWithinThePageAndFallsBackSafely() {
        let photo = NSSize(width: 1000, height: 500)
        XCTAssertEqual(EditorController.insertedImageSize(for: photo, containerWidth: 600, size: .small).width, 500, accuracy: 0.5)
        XCTAssertEqual(EditorController.insertedImageSize(for: photo, containerWidth: 600, size: .large).width, 600, accuracy: 0.5,
                       "never wider than the page")
        XCTAssertEqual(EditorController.insertedImageSize(for: photo, containerWidth: 0, size: .medium).width, 520, accuracy: 0.5,
                       "before layout, 520pt stands in for the page")
        XCTAssertEqual(EditorController.insertedImageSize(for: .zero, containerWidth: 600, size: .small), .zero, "empty images don't divide by zero")

        let key = AppSettings.defaultImageSize
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(AppSettings.imageSize, .medium, "original size when never set")
        UserDefaults.standard.set("garbage", forKey: key)
        XCTAssertEqual(AppSettings.imageSize, .medium)
    }
}
