import Foundation

/// UserDefaults keys and defaults for app preferences, in one place so the
/// Settings window, the editor and maintenance code can't disagree on a key
/// name or a default value.
enum AppSettings {
    static let spellCheckEnabled = "spellCheckEnabled"
    static let editorZoom = "editorZoom"
    static let autoSaveDelay = "autoSaveDelay"
    static let showSidebar = "showSidebar"
    static let appearanceMode = "appearanceMode"
    static let colorTheme = "colorTheme"
    static let editorFontName = "editorFontName"
    static let editorFontSize = "editorFontSize"
    static let autoEmptyTrashEnabled = "autoEmptyTrashEnabled"
    static let hasSeenOnboarding = "hasSeenOnboarding"
    static let defaultImageSize = "defaultImageSize"
    static let imageCompressionKey = "imageCompression"
    /// Relock unlocked sections when the Mac sleeps or the screen locks. On by default.
    static let autoLockSections = "autoLockSections"

    static var zoom: Double { UserDefaults.standard.object(forKey: editorZoom) as? Double ?? 1.0 }
    static var spellCheck: Bool { UserDefaults.standard.object(forKey: spellCheckEnabled) as? Bool ?? true }
    static var saveDelay: Double { UserDefaults.standard.object(forKey: autoSaveDelay) as? Double ?? 1.0 }
    static var emptiesTrash: Bool { UserDefaults.standard.object(forKey: autoEmptyTrashEnabled) as? Bool ?? true }
    /// How newly inserted images are compressed. Off unless chosen, so
    /// nobody's pictures change without asking.
    static var imageCompression: ImageCompression {
        UserDefaults.standard.string(forKey: imageCompressionKey).flatMap(ImageCompression.init(rawValue:)) ?? .original
    }

    /// Size newly inserted images get, relative to their own size.
    static var imageSize: InsertedImageSize {
        UserDefaults.standard.string(forKey: defaultImageSize).flatMap(InsertedImageSize.init(rawValue:)) ?? .medium
    }
}
