import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Daftar

final class ImageCompressionTests: XCTestCase {
    /// A noisy "photo" (so it doesn't compress trivially), encoded as `type`.
    private func makeImage(width: Int, height: Int, type: UTType = .png, alpha: Bool = false,
                           dpi: Double = 72, orientation: Int? = nil, frames: Int = 1) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        // Cheap pseudo-random texture: a photo-like image PNG can't shrink much.
        var state: UInt32 = 2463534242
        let pixels = context.data!.bindMemory(to: UInt32.self, capacity: width * height)
        for index in 0..<(width * height) {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            let transparent = alpha && index % width < width / 2
            pixels[index] = transparent ? 0 : (state | 0xFF00_0000)
        }
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil)!
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func info(_ data: Data) -> (type: String, width: Int, height: Int, points: NSSize) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        return (CGImageSourceGetType(source)! as String, properties[kCGImagePropertyPixelWidth] as! Int,
                properties[kCGImagePropertyPixelHeight] as! Int, NSImage(data: data)!.size)
    }

    func testOriginalKeepsBytesUntouched() {
        let data = makeImage(width: 3000, height: 2000)
        let result = ImageCompression.original.apply(to: data, filename: "photo.png")
        XCTAssertEqual(result.data, data)
        XCTAssertEqual(result.filename, "photo.png")
    }

    func testPhotoIsDownscaledToJPEGAndKeepsItsOnPageSize() {
        let data = makeImage(width: 3000, height: 2000)
        for (option, edge) in [(ImageCompression.high, 2560), (.medium, 1600), (.small, 1024)] {
            let result = option.apply(to: data, filename: "Holiday.png")
            let out = info(result.data)
            XCTAssertEqual(out.type, UTType.jpeg.identifier, "\(option)")
            XCTAssertEqual(max(out.width, out.height), edge, "\(option): longest edge")
            XCTAssertEqual(Double(out.width) / Double(out.height), 1.5, accuracy: 0.01, "\(option): aspect ratio kept")
            XCTAssertLessThan(result.data.count, data.count)
            XCTAssertEqual(result.filename, "Holiday.jpeg")
            XCTAssertEqual(out.points.width, 3000, accuracy: 1, "\(option): displays at the same size, just with fewer pixels")
        }
    }

    func testRetinaScreenshotKeepsItsPointSize() {
        // 144 dpi: 2400 px shows as 1200 pt. Losing pixels must not double its size on the page.
        let data = makeImage(width: 2400, height: 1600, dpi: 144)
        let result = ImageCompression.small.apply(to: data, filename: "Screenshot.png")
        XCTAssertEqual(info(result.data).width, 1024)
        XCTAssertEqual(info(result.data).points.width, 1200, accuracy: 1)
    }

    func testTransparentImageStaysPNG() {
        let data = makeImage(width: 3000, height: 2000, alpha: true)
        let result = ImageCompression.medium.apply(to: data, filename: "Logo.png")
        let out = info(result.data)
        XCTAssertEqual(out.type, UTType.png.identifier, "JPEG would turn the transparent half black")
        XCTAssertEqual(out.width, 1600)
        XCTAssertEqual(result.filename, "Logo.png")
    }

    func testCameraOrientationIsAppliedToThePixels() {
        // Orientation 6: stored landscape, shown portrait.
        let data = makeImage(width: 3000, height: 2000, type: .jpeg, orientation: 6)
        let out = info(ImageCompression.medium.apply(to: data, filename: "IMG_1.jpg").data)
        XCTAssertEqual(out.width, 1067, accuracy: 1)
        XCTAssertEqual(out.height, 1600)
    }

    func testCasesWhereTheOriginalIsKept() {
        let animated = makeImage(width: 800, height: 600, type: .gif, frames: 2)
        XCTAssertEqual(ImageCompression.small.apply(to: animated, filename: "anim.gif").data, animated, "animations stay intact")
        let garbage = Data("not an image".utf8)
        XCTAssertEqual(ImageCompression.small.apply(to: garbage, filename: "x.png").data, garbage)
        let tiny = makeImage(width: 8, height: 8, type: .jpeg)
        let result = ImageCompression.small.apply(to: tiny, filename: "tiny.jpg")
        XCTAssertLessThanOrEqual(result.data.count, tiny.count, "never grows a file")
    }

    @MainActor
    func testInsertStoresTheCompressedImage() throws {
        let key = AppSettings.imageCompressionKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(ImageCompression.small.rawValue, forKey: key)
        let storage = NSTextStorage()
        let layout = NSLayoutManager(); storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: 10_000)); layout.addTextContainer(container)
        let controller = EditorController()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800), textContainer: container)
        controller.textView = textView  // weak; `textView` keeps it alive
        let original = makeImage(width: 3000, height: 2000)
        controller.insertImage(data: original, filename: "Big.png")
        let attachment = try XCTUnwrap(storage.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let stored = try XCTUnwrap(attachment.fileWrapper?.regularFileContents)
        XCTAssertLessThan(stored.count, original.count)
        XCTAssertEqual(attachment.fileWrapper?.preferredFilename, "Big.jpeg")
        XCTAssertTrue(EditorController.isImageAttachment(attachment, at: 0, in: storage), "still treated as a picture")
        withExtendedLifetime(textView) {}
    }
}
