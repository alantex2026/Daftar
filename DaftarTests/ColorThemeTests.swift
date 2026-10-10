import XCTest
import SwiftUI
@testable import Daftar

final class ColorThemeTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ColorThemeTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDefaultsToClassicAndPersistsTheChoice() {
        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.theme, .classic)
        store.theme = .desert
        XCTAssertEqual(defaults.string(forKey: AppSettings.colorTheme), "desert")
        XCTAssertEqual(ThemeStore(defaults: defaults).theme, .desert)
    }

    func testUnknownStoredThemeFallsBackToClassic() {
        defaults.set("neon", forKey: AppSettings.colorTheme)
        XCTAssertEqual(ThemeStore(defaults: defaults).theme, .classic)
    }

    func testDesertUsesTheReferencePaletteAndIsLightOnly() {
        let desert = ColorTheme.desert
        XCTAssertEqual(desert.forcedColorScheme, .light)
        XCTAssertNil(ColorTheme.classic.forcedColorScheme)
        // Two planes (Pale Dune chrome, Warm Ivory paper), one accent (Clay),
        // Cactus Green only for confirmations.
        XCTAssertEqual(hex(desert.palette.sidebar), 0xF1DFC7)
        XCTAssertEqual(hex(desert.palette.outlineBack), 0xF1DFC7)
        XCTAssertEqual(hex(desert.palette.paper), 0xFFF4E4)
        XCTAssertEqual(hex(desert.palette.accent), 0xB86F4E)
        XCTAssertEqual(hex(desert.palette.success), 0x6D7855)
    }

    func testAppearanceFollowsModeExceptForLightOnlyThemes() {
        XCTAssertNil(ThemedAppearance.appearance(theme: .classic, mode: "system"))
        XCTAssertEqual(ThemedAppearance.appearance(theme: .classic, mode: "dark")?.name, .darkAqua)
        XCTAssertEqual(ThemedAppearance.appearance(theme: .classic, mode: "light")?.name, .aqua)
        XCTAssertEqual(ThemedAppearance.appearance(theme: .desert, mode: "dark")?.name, .aqua)
    }

    func testClassicKeepsSystemAppKitColors() {
        let classic = ColorTheme.classic.palette
        XCTAssertNil(classic.textSelection)
        XCTAssertNil(classic.caret)
        XCTAssertNil(classic.toolbar)
        XCTAssertEqual(classic.documentPage, .white)
    }

    func testClassicChromeFollowsLightAndDarkMode() {
        func brightness(_ color: Color, in name: NSAppearance.Name) -> CGFloat {
            var value: CGFloat = 0
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                value = NSColor(color).usingColorSpace(.sRGB)!.brightnessComponent
            }
            return value
        }
        let classic = ColorTheme.classic.palette
        for color in [classic.outlineBack, classic.pageCard, classic.tabStrip] {
            XCTAssertGreaterThan(brightness(color, in: .aqua), 0.85, "light chrome in Light mode")
            XCTAssertLessThan(brightness(color, in: .darkAqua), 0.3, "dark chrome in Dark mode")
        }
        XCTAssertGreaterThan(brightness(classic.pageCardText, in: .darkAqua), 0.8, "card text stays readable in Dark mode")
        XCTAssertTrue(classic.usesSidebarMaterial)
        XCTAssertFalse(ColorTheme.desert.palette.usesSidebarMaterial, "Desert keeps its own sidebar color")
    }

    private func hex(_ color: Color) -> UInt32 {
        let c = NSColor(color).usingColorSpace(.sRGB)!
        let r = UInt32((c.redComponent * 255).rounded()), g = UInt32((c.greenComponent * 255).rounded()), b = UInt32((c.blueComponent * 255).rounded())
        return r << 16 | g << 8 | b
    }
}
