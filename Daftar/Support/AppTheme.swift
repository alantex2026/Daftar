//  AppTheme.swift
//  All the colors of the app in one place, plus the page tags.
//  If you want to change how the app looks, start here.

import SwiftUI
import AppKit

enum AppTheme {
    // Left sidebar
    static let sidebar        = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let sidebarRowOn   = Color(red: 0.26, green: 0.26, blue: 0.28)
    static let sidebarText    = Color(red: 0.93, green: 0.93, blue: 0.94)
    static let sidebarLabel   = Color(red: 0.62, green: 0.63, blue: 0.65)

    // Middle column (the page outline)
    static let outlineBack    = Color(red: 0.21, green: 0.21, blue: 0.22)
    static let pageCard       = Color(red: 0.91, green: 0.91, blue: 0.91)
    static let pageCardOn     = Color(red: 0.78, green: 0.79, blue: 0.80)
    static let pageCardText   = Color(red: 0.13, green: 0.13, blue: 0.14)

    // Right side (tabs + paper)
    static let tabStrip       = Color(red: 0.21, green: 0.21, blue: 0.22)
    static let tabActive      = Color(red: 0.25, green: 0.56, blue: 0.75)
    static let tabInactive    = Color(red: 0.30, green: 0.30, blue: 0.32)
    // These track the system appearance instead of being pinned to light mode,
    // since the paper is the one surface people stare at for hours.
    static let paper          = Color(NSColor.textBackgroundColor)
    static let paperText      = Color(NSColor.textColor)

    static let accent         = Color(red: 0.25, green: 0.56, blue: 0.75)

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

extension View {
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
