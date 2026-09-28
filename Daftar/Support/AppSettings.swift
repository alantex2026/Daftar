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
    static let editorFontName = "editorFontName"
    static let editorFontSize = "editorFontSize"
    static let autoEmptyTrashEnabled = "autoEmptyTrashEnabled"
    static let hasSeenOnboarding = "hasSeenOnboarding"

    static var zoom: Double { UserDefaults.standard.object(forKey: editorZoom) as? Double ?? 1.0 }
    static var spellCheck: Bool { UserDefaults.standard.object(forKey: spellCheckEnabled) as? Bool ?? true }
    static var saveDelay: Double { UserDefaults.standard.object(forKey: autoSaveDelay) as? Double ?? 1.0 }
    static var emptiesTrash: Bool { UserDefaults.standard.object(forKey: autoEmptyTrashEnabled) as? Bool ?? true }
}
