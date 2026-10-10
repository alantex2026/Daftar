//  AppTheme.swift
//  All the colors of the app in one place, plus the page tags.
//  If you want to change how the app looks, start here.

import SwiftUI
import AppKit
import Observation

/// Every color the app's own chrome is drawn with, for one theme.
struct ThemePalette {
    // Left sidebar
    var sidebar: Color
    var sidebarRowOn: Color
    var sidebarText: Color
    var sidebarLabel: Color

    // Middle column (the page outline)
    var outlineBack: Color
    var pageCard: Color
    var pageCardOn: Color
    var pageCardText: Color

    // Right side (tabs + paper)
    var tabStrip: Color
    var paper: Color
    var paperText: Color

    /// The theme's one accent: active tab marker, toggled toolbar buttons,
    /// control tint, image handles.
    var accent: Color
    /// Confirmations such as "Saved" and spell check being on.
    var success: Color

    // AppKit surfaces. `nil` keeps the system's own color.
    var textSelection: NSColor?
    var caret: NSColor?
    var toolbar: Color?
    /// Paginated document sheets and their default text.
    var documentPage: NSColor
    var documentText: NSColor
    /// Draw the sidebar with the system's translucent sidebar material
    /// instead of the flat `sidebar` color.
    var usesSidebarMaterial = false
}

/// The color themes people can pick in Settings > Appearance.
enum ColorTheme: String, CaseIterable, Identifiable {
    case classic, desert

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .classic: return "Classic"
        case .desert: return "Desert"
        }
    }

    /// Desert is a warm light palette, so it pins the app to Light mode;
    /// dark text-field and menu chrome would clash with sand and ivory.
    var forcedColorScheme: ColorScheme? {
        self == .desert ? .light : nil
    }

    /// Tint for system controls (toggles, selections). Classic keeps the
    /// person's own macOS accent color.
    var controlTint: Color? {
        self == .desert ? palette.accent : nil
    }

    /// The colors shown next to the theme's name in Settings.
    var swatches: [Color] {
        switch self {
        case .classic: return [palette.sidebar, palette.pageCard, palette.accent]
        case .desert: return [palette.sidebar, Color(hex: 0xD8B896), palette.paper, palette.accent]
        }
    }

    /// Built once: views read these colors on every redraw.
    var palette: ThemePalette {
        switch self {
        case .classic: return Self.classicPalette
        case .desert: return Self.desertPalette
        }
    }

    /// A color that follows Light / Dark mode.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    private static func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(white: white, alpha: alpha)
    }

    // Follows the system appearance throughout: light chrome in Light mode,
    // dark chrome in Dark mode, with system label and selection colors so
    // text contrast and the person's accent color are always respected.
    private static let classicPalette = ThemePalette(
        sidebar:      adaptive(light: gray(0.93), dark: gray(0.17)),
        sidebarRowOn: adaptive(light: gray(0, 0.08), dark: gray(1, 0.10)),
        sidebarText:  Color(nsColor: .labelColor),
        sidebarLabel: Color(nsColor: .secondaryLabelColor),
        outlineBack:  adaptive(light: gray(0.965), dark: gray(0.155)),
        pageCard:     adaptive(light: gray(1), dark: gray(0.215)),
        pageCardOn:   Color(nsColor: .unemphasizedSelectedContentBackgroundColor),
        pageCardText: Color(nsColor: .labelColor),
        tabStrip:     adaptive(light: gray(0.94), dark: gray(0.155)),
        // These track the system appearance instead of being pinned to light mode,
        // since the paper is the one surface people stare at for hours.
        paper:        Color(NSColor.textBackgroundColor),
        paperText:    Color(NSColor.textColor),
        accent:       Color(nsColor: .controlAccentColor),
        success:      .green,
        textSelection: nil,
        caret:        nil,
        toolbar:      nil,
        documentPage: .white,
        documentText: .black,
        usesSidebarMaterial: true)

    // Two planes and one accent: Pale Dune chrome, Warm Ivory paper, Desert
    // Sand for selection, Sunburnt Clay as the accent and Cactus Green
    // only for confirmations. Dark umber text keeps every label >= 4.5:1.
    private static let desertPalette = ThemePalette(
        sidebar:      Color(hex: 0xF1DFC7),   // Pale Dune
        sidebarRowOn: Color(hex: 0xE2C8AA),   // Desert Sand at 60% on Pale Dune
        sidebarText:  Color(hex: 0x2F2219),
        sidebarLabel: Color(hex: 0x5C4535),
        outlineBack:  Color(hex: 0xF1DFC7),   // Pale Dune
        pageCard:     Color(hex: 0xFFF4E4),   // Warm Ivory
        pageCardOn:   Color(hex: 0xE2C8AA),
        pageCardText: Color(hex: 0x2F2219),
        tabStrip:     Color(hex: 0xF1DFC7),   // Pale Dune
        paper:        Color(hex: 0xFFF4E4),   // Warm Ivory
        paperText:    Color(hex: 0x2F2219),
        accent:       Color(hex: 0xB86F4E),   // Sunburnt Clay
        success:      Color(hex: 0x6D7855),   // Cactus Green
        textSelection: NSColor(Color(hex: 0xD8B896)),  // Desert Sand
        caret:        NSColor(Color(hex: 0xB86F4E)),
        toolbar:      Color(hex: 0xF1DFC7),
        documentPage: NSColor(Color(hex: 0xFFF4E4)),
        documentText: NSColor(Color(hex: 0x2F2219)))
}

/// The chosen color theme. Observable, so any view that reads an
/// `AppTheme` color while drawing redraws when the theme changes.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    var theme: ColorTheme {
        didSet { defaults.set(theme.rawValue, forKey: AppSettings.colorTheme) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: AppSettings.colorTheme).flatMap(ColorTheme.init(rawValue:)) ?? .classic
    }
}

extension Color {
    /// `Color(hex: 0xD8B896)` for a 24-bit sRGB color.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Light/dark mode and control tint for the chosen color theme. A view
/// modifier (not the App body) so the theme read is observation-tracked.
struct ThemedAppearance: ViewModifier {
    @AppStorage(AppSettings.appearanceMode) private var appearanceMode = "system"

    func body(content: Content) -> some View {
        let theme = ThemeStore.shared.theme
        content
            .tint(theme.controlTint)
            // Set on NSApp rather than with preferredColorScheme: SwiftUI on
            // macOS doesn't reliably return to the system appearance when
            // that goes back to nil, which would strand people in Light
            // mode after trying Desert.
            .onChange(of: "\(theme.rawValue)-\(appearanceMode)", initial: true) {
                NSApp.appearance = Self.appearance(theme: theme, mode: appearanceMode)
            }
    }

    static func appearance(theme: ColorTheme, mode: String) -> NSAppearance? {
        switch theme.forcedColorScheme ?? (mode == "light" ? .light : mode == "dark" ? .dark : nil) {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }
}

/// Control tint for content in its own NSHostingView (the split-view panes),
/// which doesn't inherit the window's SwiftUI environment.
struct ThemedTint: ViewModifier {
    func body(content: Content) -> some View {
        content.tint(ThemeStore.shared.theme.controlTint)
    }
}

extension View {
    func themedAppearance() -> some View { modifier(ThemedAppearance()) }
    func themedTint() -> some View { modifier(ThemedTint()) }

    /// Rounded, inset selection highlight for list rows.
    func selectionBackground(_ isSelected: Bool, color: Color) -> some View {
        background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? color : .clear)
                .padding(.horizontal, 6)
        )
    }
}

enum AppTheme {
    private static var palette: ThemePalette { ThemeStore.shared.theme.palette }

    // Left sidebar
    static var sidebar: Color      { palette.sidebar }
    static var usesSidebarMaterial: Bool { palette.usesSidebarMaterial }
    static var sidebarRowOn: Color { palette.sidebarRowOn }
    static var sidebarText: Color  { palette.sidebarText }
    static var sidebarLabel: Color { palette.sidebarLabel }

    // Middle column (the page outline)
    static var outlineBack: Color  { palette.outlineBack }
    static var pageCard: Color     { palette.pageCard }
    static var pageCardOn: Color   { palette.pageCardOn }
    static var pageCardText: Color { palette.pageCardText }

    // Right side (tabs + paper)
    static var tabStrip: Color     { palette.tabStrip }
    static var paper: Color        { palette.paper }
    static var paperText: Color    { palette.paperText }

    static var accent: Color       { palette.accent }
    static var success: Color      { palette.success }
    static var toolbar: Color?     { palette.toolbar }

    // AppKit
    /// Accent for AppKit drawing (image handles); Classic follows macOS.
    static var nsAccent: NSColor {
        ThemeStore.shared.theme == .classic ? .controlAccentColor : NSColor(palette.accent)
    }
    static var textSelection: NSColor { palette.textSelection ?? .selectedTextBackgroundColor }
    static var caret: NSColor?        { palette.caret }
    static var documentPage: NSColor  { palette.documentPage }
    static var documentText: NSColor  { palette.documentText }
    /// Same as `nsAccent`, for SwiftUI views that used `Color.accentColor`.
    static var controlAccent: Color   { ThemeStore.shared.theme.controlTint ?? .accentColor }

    /// The disclosure chevron for a collapsed/expanded row. SF Symbol
    /// chevrons don't auto-mirror for RTL the way logically-named symbols
    /// (like "sidebar.leading") do, so the collapsed-state direction is
    /// picked explicitly - pointing towards where the content will expand
    /// from: right in LTR, left in RTL, matching macOS's own outline views.
    static func disclosureIcon(isOpen: Bool, layoutDirection: LayoutDirection) -> String {
        if isOpen { return "chevron.down" }
        return layoutDirection == .rightToLeft ? "chevron.left" : "chevron.right"
    }
}

/// The colors you can give to a notebook or a section tab.
enum PaletteColor: String, CaseIterable, Identifiable {
    case blue, purple, teal, green, yellow, orange, red, pink, gray

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .teal: return "Teal"
        case .green: return "Green"
        case .yellow: return "Yellow"
        case .orange: return "Orange"
        case .red: return "Red"
        case .pink: return "Pink"
        case .gray: return "Gray"
        }
    }

    var color: Color {
        switch self {
        case .blue:   return Color(red: 0.33, green: 0.62, blue: 0.86)
        case .purple: return Color(red: 0.64, green: 0.46, blue: 0.91)
        case .teal:   return Color(red: 0.26, green: 0.68, blue: 0.72)
        case .green:  return Color(red: 0.36, green: 0.73, blue: 0.46)
        case .yellow: return Color(red: 0.90, green: 0.77, blue: 0.31)
        case .orange: return Color(red: 0.94, green: 0.58, blue: 0.28)
        case .red:    return Color(red: 0.88, green: 0.37, blue: 0.37)
        case .pink:   return Color(red: 0.92, green: 0.48, blue: 0.68)
        case .gray:   return Color(red: 0.56, green: 0.59, blue: 0.63)
        }
    }

    static func named(_ name: String) -> PaletteColor { PaletteColor(rawValue: name) ?? .blue }
}

/// The little colored marks you can put on a page.
/// What kind of document a page is - almost every page is `.richText`
/// (the free-flowing editor); `.document` and `.spreadsheet` are
/// alternate editors that use the same `Page` model but render and
/// store their content differently (see `Page.spreadsheetData`).
enum PageKind: Int, CaseIterable, Identifiable {
    case richText = 0
    case document = 1
    case spreadsheet = 2

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .richText: return "Note"
        case .document: return "Document"
        case .spreadsheet: return "Spreadsheet"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .richText: return "Free-flowing text, checklists, images"
        case .document: return "Paginated, letter-sized pages"
        case .spreadsheet: return "A grid with rows, columns, and formulas"
        }
    }

    var symbol: String {
        switch self {
        case .richText: return "doc.text"
        case .document: return "doc.richtext"
        case .spreadsheet: return "tablecells"
        }
    }
}

enum PageTag: Int, CaseIterable, Identifiable {
    case none = 0, question = 1, star = 2, important = 3

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .none: return "No Tag"
        case .question: return "Question"
        case .star: return "Important Idea"
        case .important: return "Critical"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "tag"
        case .question: return "questionmark"
        case .star: return "star.fill"
        case .important: return "exclamationmark"
        }
    }

    var color: Color {
        switch self {
        case .none: return .gray
        case .question: return Color(red: 0.29, green: 0.45, blue: 0.75)
        case .star: return Color(red: 0.95, green: 0.62, blue: 0.20)
        case .important: return Color(red: 0.85, green: 0.24, blue: 0.20)
        }
    }
}

/// The small rounded badge used for a tag.
struct TagBadge: View {
    let tag: PageTag
    var size: CGFloat = 18
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(tag.color)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: tag.symbol)
                    .font(.system(size: size * 0.6, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

/// The small book shape next to a notebook name.
struct NotebookIcon: View {
    let colorName: String
    var body: some View {
        let c = PaletteColor.named(colorName).color
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3).fill(c.opacity(0.55)).frame(width: 16, height: 22)
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 6, height: 22)
        }
        .frame(width: 18, height: 22)
    }
}

/// The small tab shape next to a section name.
struct SectionIcon: View {
    let colorName: String
    var isGroup: Bool = false
    var body: some View {
        let c = PaletteColor.named(colorName).color
        if isGroup {
            Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(c).frame(width: 18)
        } else {
            UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 1,
                                   bottomTrailingRadius: 1, topTrailingRadius: 4)
                .fill(c).frame(width: 17, height: 11)
        }
    }
}

/// The system's translucent sidebar material, which shows the desktop
/// through the window the way Finder's and Mail's sidebars do.
struct SidebarMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
    /// The sidebar's backdrop for the current theme: system material, or
    /// the theme's flat color.
    @ViewBuilder
    func sidebarBackground() -> some View {
        if AppTheme.usesSidebarMaterial {
            background(SidebarMaterialBackground().ignoresSafeArea())
        } else {
            background(AppTheme.sidebar)
        }
    }

    /// A single tap and a double tap on the same row, correctly
    /// disambiguated - without this, SwiftUI can fire both a stacked
    /// `.onTapGesture(count: 1)` and `.onTapGesture(count: 2)` for the same
    /// click, instead of waiting to see if a second tap follows.
    func onSingleAndDoubleTap(single: @escaping () -> Void, double: @escaping () -> Void) -> some View {
        gesture(
            TapGesture(count: 2).onEnded(double)
                .exclusively(before: TapGesture(count: 1).onEnded(single))
        )
    }
}
