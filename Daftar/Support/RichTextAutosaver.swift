import AppKit
import SwiftData

/// Debounced persistence of an editor's text, shared by the continuous and
/// the paginated editor: one place encodes RTFD, extracts links, honours the
/// auto-save delay and reports save state.
@MainActor
final class RichTextAutosaver {
    private let saver = SaveCoordinator()
    private let onChange: (Data, String, [UUID]) throws -> Void

    init(onChange: @escaping (Data, String, [UUID]) throws -> Void) {
        self.onChange = onChange
    }

    /// `ownsEditor` reports whether the controller is currently driving this
    /// editor, so only the visible editor updates the status bar.
    func schedule(_ storage: NSTextStorage, controller: EditorController?,
                  ownsEditor: @escaping @MainActor (EditorController) -> Bool) {
        let onChange = self.onChange
        saver.onStateChange = { [weak controller] state in
            if let controller, ownsEditor(controller) { controller.saveState = state }
        }
        saver.onError = { [weak controller] in controller?.errorMessage = $0 }
        saver.rescue = { folder in try Self.writeRescueCopy(of: storage, into: folder) }
        saver.schedule(delay: controller?.autoSaveDelay ?? 1.0) {
            let data = try PageContentCodec.rtfd(CanvasImageLayout.portable(storage))
            try onChange(data, storage.string, storage.linkedPageIDs)
        }
    }

    var state: EditorController.SaveState { saver.state }

    /// Writes the text as an .rtfd package (images included) that TextEdit
    /// can open, named after its first line.
    static func writeRescueCopy(of text: NSAttributedString, into folder: URL) throws -> URL {
        let firstLine = text.string.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let url = SaveCoordinator.rescueURL(named: firstLine, extension: "rtfd", in: folder)
        let portable = CanvasImageLayout.portable(text)
        let wrapper = try portable.fileWrapper(from: NSRange(location: 0, length: portable.length),
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        return url
    }

    @discardableResult
    func flush() -> Bool { saver.flush() }
}

extension Page {
    /// Stores edited rich text, keeping a history revision first. The single
    /// save path for every rich-text editor.
    @MainActor
    func saveRichText(_ data: Data, plainText: String, links: [UUID], in context: ModelContext) throws {
        try PageHistory.capture(self)
        contentData = data
        self.plainText = plainText
        outgoingLinkIDs = links
        updatedAt = Date()
        try context.save()
    }
}
