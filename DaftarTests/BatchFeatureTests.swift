import XCTest
import AppKit
@testable import Daftar

/// Search highlighting, the delete-undo notice and auto-lock.
@MainActor
final class BatchFeatureTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: Search highlighting

    func testMatchRangesAreExactEvenAcrossFoldedArabic() {
        let text = "Café notes — كـتـاب and أحمد, cafe again"
        let ns = text as NSString
        XCTAssertEqual(SearchText.ranges(of: "cafe", in: text).map(ns.substring(with:)), ["Café", "cafe"])
        XCTAssertEqual(SearchText.ranges(of: "كتاب", in: text).map(ns.substring(with:)), ["كـتـاب"], "tatweel inside the match is included")
        XCTAssertEqual(SearchText.ranges(of: "احمد", in: text).map(ns.substring(with:)), ["أحمد"])
        XCTAssertTrue(SearchText.ranges(of: "", in: text).isEmpty)
    }

    func testHighlightRequestIsTakenOnceByThatPageOnly() {
        let page = UUID(), other = UUID()
        SearchHighlight.request("milk", for: page)
        XCTAssertNil(SearchHighlight.take(for: other))
        XCTAssertEqual(SearchHighlight.take(for: page), "milk")
        XCTAssertNil(SearchHighlight.take(for: page), "taken once")
        SearchHighlight.request("   ", for: page)
        XCTAssertNil(SearchHighlight.take(for: page), "blank queries aren't highlighted")
    }

    func testHighlightMarksMatchesWithoutChangingTheText() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        textView.string = "buy milk, then more milk"
        let before = textView.textStorage!.copy() as! NSAttributedString
        XCTAssertEqual(SearchHighlight.apply("MILK", to: textView, scroll: false), 2)
        let layout = textView.layoutManager!
        XCTAssertNotNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 5, effectiveRange: nil))
        XCTAssertTrue(textView.textStorage!.isEqual(to: before), "a highlight is never saved into the page")
        SearchHighlight.clear(in: textView)
        XCTAssertNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 5, effectiveRange: nil))
    }

    // MARK: Undo after delete

    func testUndoToastRunsTheUndoOnceAndHides() {
        let toast = UndoToast()
        var restored = 0
        toast.trashed("Groceries") { restored += 1 }
        XCTAssertEqual(toast.notice?.message.contains("Groceries"), true)
        toast.performUndo()
        toast.performUndo()
        XCTAssertEqual(restored, 1)
        XCTAssertNil(toast.notice)
    }

    func testANewerDeleteReplacesTheOlderNotice() {
        let toast = UndoToast()
        var undone: [String] = []
        toast.trashed("First") { undone.append("First") }
        toast.trashed("Second") { undone.append("Second") }
        toast.performUndo()
        XCTAssertEqual(undone, ["Second"])
    }

    // MARK: Auto-lock

    func testSleepRelocksUnlockedSectionsUnlessTurnedOff() {
        let section = NoteSection(name: "Private"); section.isLocked = true
        let locks = SectionLockStore { _, completion in completion(true) }
        locks.requestUnlock(section, reason: "test") { _ in }
        XCTAssertTrue(locks.isUnlocked(section))

        let off = defaults(); off.set(false, forKey: AppSettings.autoLockSections)
        locks.lockAllIfEnabled(defaults: off)
        XCTAssertTrue(locks.isUnlocked(section), "the setting can turn auto-lock off")

        locks.lockAllIfEnabled(defaults: defaults())
        XCTAssertFalse(locks.isUnlocked(section), "on by default")
    }
}
