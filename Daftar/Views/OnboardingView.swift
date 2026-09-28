//  OnboardingView.swift
//  A one-time, first-launch explainer of the Notebook -> Section -> Page
//  model, shown once before the user is dropped into the seeded notebook.

import SwiftUI

struct OnboardingView: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(AppTheme.accent)
                Text("Welcome to Daftar")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("Everything is organized in four levels.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 18) {
                step(icon: AnyView(NotebookIcon(colorName: "teal")), title: "Notebook",
                     description: "The top level - one per project, class, or area of your life.")
                step(icon: AnyView(SectionIcon(colorName: "blue")), title: "Section",
                     description: "A notebook holds sections, or Section Groups that hold more sections.")
                step(icon: AnyView(Image(systemName: "doc.text").font(.system(size: 15)).foregroundStyle(.secondary)),
                     title: "Page",
                     description: "A section holds pages, and pages can hold their own sub-pages, as deep as you need.")
                step(icon: AnyView(Image(systemName: "pencil.line").font(.system(size: 15)).foregroundStyle(.secondary)),
                     title: "Editor",
                     description: "Open any page to write - rich text, tables, links, images, and more.")
            }

            Button("Get Started") { onDismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(36)
        .frame(width: 420)
    }

    private func step(icon: AnyView, title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            icon.frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(description).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
