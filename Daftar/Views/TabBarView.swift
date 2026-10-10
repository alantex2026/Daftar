//  TabBarView.swift
//  The strip of section tabs above the paper.

import SwiftUI
import SwiftData

struct TabBarView: View {
    @Query private var allSections: [NoteSection]
    @Binding var openTabs: [NoteSection]
    @Binding var selectedSection: NoteSection?
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                Button {
                    if let first = openTabs.first { withAnimation { proxy.scrollTo(first.persistentModelID) } }
                } label: {
                    Image(systemName: layoutDirection == .rightToLeft ? "chevron.right" : "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.sidebarLabel)
                        .frame(width: 22, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Scroll to First Tab"))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(openTabs) { section in
                            tab(section)
                                .id(section.persistentModelID)
                        }
                    }
                    .padding(.horizontal, 2)
                    // Tabs sit on the bottom edge so the active one runs into the paper.
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: 36)

                Spacer(minLength: 8)

                Menu {
                    ForEach(closableSections) { section in
                        Button(section.name) {
                            if !openTabs.contains(where: { $0 === section }) { openTabs.append(section) }
                            selectedSection = section
                        }
                    }
                    if closableSections.isEmpty {
                        Text("All sections are already open")
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(AppTheme.sidebarLabel)
                .help("Open another section in a tab")
                .accessibilityLabel(Text("Open Section in Tab"))

                Button {
                    if let last = openTabs.last { withAnimation { proxy.scrollTo(last.persistentModelID) } }
                } label: {
                    Image(systemName: layoutDirection == .rightToLeft ? "chevron.left" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.sidebarLabel)
                        .frame(width: 22, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Scroll to Last Tab"))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 36)
        .background(AppTheme.tabStrip)
    }

    private var closableSections: [NoteSection] {
        allSections.filter { candidate in
            !candidate.isGroup && !candidate.isTrashed && !openTabs.contains(where: { open in open === candidate })
        }
        .sorted { $0.name < $1.name }
    }

    /// The active tab is cut from the paper itself, marked by a thin accent
    /// line; inactive tabs are just text on the strip.
    private func tab(_ section: NoteSection) -> some View {
        let isActive = selectedSection === section
        let shape = UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 0, topTrailingRadius: 8,
                                           style: .continuous)
        return HStack(spacing: 6) {
            Text(section.name)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? AppTheme.paperText : AppTheme.sidebarText.opacity(0.75))
                .lineLimit(1)
            Button {
                close(section)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isActive ? AppTheme.paperText.opacity(0.6) : AppTheme.sidebarLabel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close Tab"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            if isActive {
                shape.fill(AppTheme.paper)
                    .overlay(alignment: .top) {
                        AppTheme.accent.frame(height: 2)
                    }
                    .clipShape(shape)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedSection = section }
        .contextMenu {
            Button("Close Tab") { close(section) }
            Button("Close Other Tabs") { openTabs = [section]; selectedSection = section }
        }
    }

    private func close(_ section: NoteSection) {
        openTabs.removeAll { $0 === section }
        if selectedSection === section { selectedSection = openTabs.last }
    }
}
