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
| `SidebarView.swift` | Column 1: pinned pages + the notebook tree. |
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

## 6. Saving, protection, and notebook interchange

- Each window has its own editor; Format menu commands target the focused window.
- Rich text, document, and spreadsheet edits report **Saved** only after a successful
  database save. Pending edits flush on page changes and normal quit. Failed saves
  remain available for retry, and a failed quit save keeps the app open.
- Section locks apply to child sections, search results, page-link suggestions, and
  notebook export. Export requires unlocking every protected section first.
- Notebook export creates readable Markdown, uniquely named attachment files, and
  a hidden `.daftar-notebook.json` companion containing the complete live notebook.
  Keep that file with the export to restore sections/groups, page types, formulas,
  formatting, embedded attachments, tags, and internal links. Importing an export
  restores this snapshot; edits made to its Markdown files are not applied. To
  import edited Markdown instead, select a folder without the companion file.
- Unreadable pages open in recovery mode. Reset requires confirmation and a
  successful backup of the original bytes before the page is replaced.
- These are local access locks, not encryption of the database or exported files.

**Library tools** (external-drive icon in the toolbar):
- **Back Up Entire Library** writes a versioned `.daftarbackup` file containing all
  notebooks, sections, page types, attachments, tags, history, saved searches, and
  Trash. **Restore Library Backup** adds notebooks without replacing existing notes.
  IDs are preserved in an empty library and remapped consistently when restoring
  alongside existing notes, including links between notebooks.
- **Set Up Folder Sync** lets you select a private folder in iCloud Drive, Dropbox,
  or another installed file-sync provider. Choose the same folder on each Mac.
  Daftar checks every 30 seconds while open; **Sync Now** retries immediately.
  Each device owns a separate file, and concurrent notebook edits produce a
  **Sync conflict** copy instead of discarding either version. Notes, attachments,
  custom tags, history, Trash, and deletions synchronize. Saved searches remain
  local, but are included in library backups.
- Sync is off until configured. Its status means the shared-folder write completed;
  delivery to another Mac depends on your folder provider. Locked sections must be
  unlocked before publishing. Sync files and backups are not encrypted by Daftar.
- Before applying remote changes, Daftar keeps a local recovery backup. The latest
  ten are retained; **Show Recovery Backups** opens their folder. Turning sync off
  stops future operations and leaves existing local and shared files intact.

**Page tools**:
- The history button opens previews and restore controls. Automatic revisions
  capture the previous saved state at most once per minute. **Save Snapshot**
  captures immediately. History keeps up to 50 revisions within a 64 MB budget
  per page (always retaining at least the newest revision).
- The tag button manages multiple custom tags. Search can match/filter those tags;
  **Saved Searches** stores the query, notebook, built-in tag, and custom-tag filter.
- The last session restores section tabs, selected page, and text cursor. Windows
  maintain separate sessions; a new launch resumes the last saved window session.

**Spreadsheet tools**:
- CSV import/export supports quoted fields, commas, and multiline values.
- Enter a range such as `A1:C5`, then use **Copy Range**, **Paste Range**, or
  **Delete Rows**. Deletion shifts cell references and marks deleted references invalid.
- Undo/redo works through the buttons or Cmd+Z / Shift+Cmd+Z. CSV imports and range
  operations are undoable. The grid supports up to 200 rows and 26 columns.
- Formulas support arithmetic, references, `SUM`, `AVERAGE`, `MIN`, `MAX`, and
  `COUNT`, including ranges such as `=SUM(A1:A5)`.

**Click-to-type canvas:** click an empty area of a note and start typing there.
Text is positioned using normal rich-text paragraphs and tabs, aligned to text
lines, and stays searchable and editable. The canvas grows below your content;
placement and typing use the same autosave and undo support as other edits.

**Images:** click an imported or pasted picture to select it. Drag the picture
itself to position it freely on the canvas; drag any of its eight handles to
resize while preserving its proportions. Arrow keys move a selected floating
image by one point (Shift moves ten). Click outside or press Escape to deselect,
and use Delete to remove it. Right-click for size presets or **Place in Text** to
return to inline layout. Movement and resizing support Undo/Redo and survive
reopening, history, backups and folder sync. PDF exports preserve the canvas
layout; other rich-text editors show the embedded pictures inline.

**Document pages** support US Letter, A4, and Legal paper, backlinks, page links,
consistent save feedback, removal of empty trailing pages, and export of all sheets
as PDF. Existing formatting is preserved when paper size changes.

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
