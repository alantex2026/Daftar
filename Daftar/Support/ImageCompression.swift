//  ImageCompression.swift
//  The "Compress new pictures" setting: shrinks and re-encodes an image as
//  it's inserted, so a page of phone photos doesn't weigh tens of megabytes
//  (every save, history revision, backup and sync carries those bytes).

import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageCompression: String, CaseIterable, Sendable {
    case original, high, medium, small

    /// Longest edge in pixels after compression; nil keeps the file as-is.
    var maxPixelSize: Int? {
        switch self {
        case .original: return nil
        case .high: return 2560
        case .medium: return 1600
        case .small: return 1024
        }
    }

    /// JPEG quality for opaque images.
    var quality: CGFloat {
        switch self {
        case .original, .high: return 0.85
        case .medium: return 0.75
        case .small: return 0.6
        }
    }

    var title: String {
        switch self {
        case .original: return String(localized: "Original (no compression)")
        case .high: return String(localized: "High quality (up to 2560 px)")
        case .medium: return String(localized: "Medium (up to 1600 px)")
        case .small: return String(localized: "Small (up to 1024 px)")
        }
    }

    /// Returns the bytes and filename to store for an inserted image. Falls
    /// back to the untouched original whenever compressing wouldn't help or
    /// can't be done safely: unreadable data, animations, vector formats, or
    /// a result that isn't actually smaller.
    ///
    /// - Opaque images become JPEG; images with transparency stay PNG (JPEG
    ///   has no alpha, so they'd get a black background).
    /// - Camera orientation is applied to the pixels, and metadata such as
    ///   GPS location is not carried over.
    /// - The on-page size in points is kept (via DPI), so a Retina screenshot
    ///   doesn't suddenly display twice as large after losing pixels.
    nonisolated func apply(to data: Data, filename: String) -> (data: Data, filename: String) {
        let unchanged = (data, filename)
        guard let maxPixelSize,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,  // animations and multi-page images stay intact
              let sourceType = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              sourceType.conforms(to: .image), !sourceType.conforms(to: .pdf), !sourceType.conforms(to: .svg),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0 else { return unchanged }

        // Orientations 5-8 are rotated 90°: width and height swap on screen.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let orientedWidth = (5...8).contains(orientation) ? pixelHeight : pixelWidth
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let pointWidth = Double(orientedWidth) * 72 / dpi

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(pixelWidth, pixelHeight), maxPixelSize),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return unchanged }

        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool ?? false) && Self.hasTransparency(image)
        let outputType: UTType = hasAlpha ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, outputType.identifier as CFString, 1, nil) else { return unchanged }
        let outputDPI = 72 * Double(image.width) / pointWidth
        var outputProperties: [CFString: Any] = [kCGImagePropertyDPIWidth: outputDPI, kCGImagePropertyDPIHeight: outputDPI]
        if !hasAlpha { outputProperties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, outputProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0, output.length < data.count else { return unchanged }

        let base = (filename as NSString).deletingPathExtension
        let name = (base.isEmpty ? "Picture" : base) + "." + (outputType.preferredFilenameExtension ?? (hasAlpha ? "png" : "jpg"))
        return (output as Data, name)
    }

    /// True if any pixel is not fully opaque. PNGs (screenshots especially)
    /// often carry an alpha channel they never use; those can become JPEG.
    private nonisolated static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let width = image.width, height = image.height
        // Check a downsampled copy: exact enough for "is anything see-through".
        let sampleWidth = min(width, 256), sampleHeight = max(1, height * sampleWidth / max(width, 1))
        guard let context = CGContext(data: nil, width: sampleWidth, height: sampleHeight, bitsPerComponent: 8,
                                      bytesPerRow: sampleWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data else { return true }
        context.clear(CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        let bytes = pixels.bindMemory(to: UInt8.self, capacity: sampleWidth * sampleHeight * 4)
        for index in stride(from: 3, to: sampleWidth * sampleHeight * 4, by: 4) where bytes[index] < 255 { return true }
        return false
    }
}
