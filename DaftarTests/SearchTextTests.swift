import XCTest
@testable import Daftar

final class SearchTextTests: XCTestCase {
    func testIgnoresCaseAccentsAndHarakat() {
        XCTAssertTrue(SearchText.matches("Café Résumé", "cafe resume"))
        XCTAssertTrue(SearchText.matches("مُحَمَّد", "محمد"))
        XCTAssertTrue(SearchText.matches("محمد", "مُحَمَّد"))
    }

    func testFoldsAlefVariantsAndTatweel() {
        XCTAssertTrue(SearchText.matches("أحمد", "احمد"))
        XCTAssertTrue(SearchText.matches("احمد", "أحمد"))
        XCTAssertTrue(SearchText.matches("إسلام وآمال", "اسلام"))
        XCTAssertTrue(SearchText.matches("إسلام وآمال", "امال"))
        XCTAssertTrue(SearchText.matches("كـتـاب", "كتاب"))
        XCTAssertFalse(SearchText.matches("مدرسة", "مدرسه"), "taa marbuta and haa stay distinct")
        XCTAssertFalse(SearchText.matches("anything", ""))
    }

    func testFoldedMatchMapsBackToTheOriginalText() throws {
        let text = "ملاحظات عن أحمد اليوم"
        let range = try XCTUnwrap(SearchText.range(of: "احمد", in: text))
        XCTAssertEqual(String(text[range]), "أحمد")
    }

    func testQuickOpenRanksTitleMatchesFirst() throws {
        func score(_ title: String, path: String = "", _ query: String) -> Int? {
            QuickOpenRanking.score(title: title, path: path, query: query)
        }
        let prefix = try XCTUnwrap(score("Meeting notes", "meet"))
        let word = try XCTUnwrap(score("Team meeting", "meet"))
        let inside = try XCTUnwrap(score("Premeeting", "meet"))
        let letters = try XCTUnwrap(score("Meeting", "mtg"))
        let pathOnly = try XCTUnwrap(score("Agenda", path: "Work › Meetings", "meet"))
        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, inside)
        XCTAssertGreaterThan(inside, letters)
        XCTAssertGreaterThan(letters, pathOnly)
        XCTAssertNil(score("Groceries", path: "Home", "meet"))
        XCTAssertNotNil(score("أحمد", "احم"), "Arabic folding applies to Quick Open too")
    }
}
