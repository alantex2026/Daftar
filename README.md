# Daftar — a macOS notebook app

Native macOS note-taking app built with **SwiftUI** + **SwiftData** + **AppKit**.

Structure: **Notebook → Section / Section Group → Page → Sub-page → Page Editor**

---

## 1. What you need

- A Mac (your M1 MacBook is fine)
- **Xcode 16 or newer** (Xcode 26 on macOS Tahoe) — free from the Mac App Store

That's all. No accounts, no internet, no API keys.

---

## 2. How to run it

1. Unzip the folder somewhere easy, like your Desktop.
2. Double-click **`Daftar.xcodeproj`**. Xcode opens.
3. At the top, make sure the dropdown next to the app name says **My Mac**.
4. Press **▶** (or `Cmd + R`). First build takes about 30 seconds.
5. The window opens with a "User Guide" notebook already inside.

**If Xcode asks for a signing team:** click the blue project icon on the left →
`Signing & Capabilities` → set *Signing Certificate* to **Sign to Run Locally**.

**If the project file will not open:** File → New → Project → macOS → App.
Name it `Daftar`, Interface **SwiftUI**, Storage **SwiftData**. Delete the two
files Xcode creates, then drag the `Daftar` folder from this download into the
Xcode file list (tick "Copy items if needed"). Press ▶.

---

## 3. The four levels

```
Notebook              "User Guide"          left sidebar, book icon
 └─ Section           "Explore Daftar"      left sidebar, coloured tab
     └─ Page          "Taking Notes"        middle column, grey card
         └─ Sub-page  "Saving Your Notes"   middle column, indented card
```

A **Section Group** is a section with `isGroup = true`: it holds other sections
instead of pages. Sub-pages work the same way — a page can hold other pages, as
deep as you want.

---

## 4. What each file does

| File | What it does |
|---|---|
| `DaftarApp.swift` | Starting point. Creates the window, database and Format menu. |
| **Models/** | |
| `Notebook.swift` | A notebook. Holds sections. |
| `NoteSection.swift` | A section. Holds pages, or other sections if it is a group. |
| `Page.swift` | A page: title, tag, rich text, and its own sub-pages. |
| **Views/** | |
| `ContentView.swift` | The three resizable columns + the whole top toolbar. |
| `SidebarView.swift` | Column 1: RECENTS list + the notebook tree. |
| `PageOutlineView.swift` | Column 2: page cards, sub-pages, and search results. |
| `TabBarView.swift` | The blue section tabs above the paper. |
| `PageEditorView.swift` | The white paper: title, editor, bottom status bar. |
| `RichTextEditor.swift` | Bridge letting SwiftUI use macOS's real text editor. |
| `MainToolbar.swift` | Every toolbar button: style, B/I/U, colours, tags, share. |
| **Support/** | |
| `AppTheme.swift` | **All colours in one place**, plus tags and the small icons. |
| `EditorController.swift` | The "remote control": bold, colours, tables, export… |
| `SampleData.swift` | Builds the example User Guide notebook on first launch. |

---

## 5. What works

**Structure**
- Notebooks: create, rename, recolour, delete
- Sections and Section Groups: create, nest, rename, recolour, move between
  notebooks, delete
- Pages and **sub-pages** at any depth, with open/close triangles
- New page, new sub-page, rename, duplicate, "move out one level", delete
- **RECENTS** — the last 6 pages you opened, updated automatically
- **Tabs** — every section you open gets a tab; close one, close others, or use
  the `+` to open another section

**Editor**
- Title with the underline rule, live word count
- Bold ⌘B, Italic ⌘I, Underline ⌘U
- Styles: Normal, Heading 1/2/3, Code
- Font size, text colour, highlight colour
- Left / centre / right alignment
- Bulleted and numbered lists
- Links, tables (2×2 / 3×3 / 4×4), pictures, file attachments, date & time
- Undo / Redo, spell check, Find in page ⌘F
- Zoom 50–200 %
- Export the page as PDF or RTF, copy page text

**Tags** — Question (blue ?), Important Idea (orange ★), Critical (red !).
Click a tag button in the toolbar to add or remove it. The tag shows on the page
card and next to the title.

**Search** — type in the Search box top-right. The middle column switches to
results across **all** pages, matching titles and body text.

---

## 6. Not built (honest list)

- The "Register" button from the reference — that is the paid app's trial nag,
  not a real feature.
- iCloud sync (the "Last Sync" line is a label only — your notes save instantly
  to your Mac, they just don't sync anywhere).
- Password-protected sections.
- Drag and drop to reorder pages or sections (menus do the same job for now).
- A real app icon.

---

## 7. Where your notes live

```
~/Library/Application Support/default.store
```

Everything is offline and local. To start completely fresh: quit the app, press
`Cmd + Shift + G` in Finder, paste `~/Library/Application Support`, and delete
`default.store`, `default.store-shm` and `default.store-wal`.

---

## 8. Three easy things to try, to learn

1. `Support/AppTheme.swift` — change `paper` to a soft cream colour
   `Color(red: 0.99, green: 0.98, blue: 0.94)` and run again.
2. `Support/SampleData.swift` — change the example page titles.
3. `Views/PageEditorView.swift` — change the title size from `34` to `28`.
