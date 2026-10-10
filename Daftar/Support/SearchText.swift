//  SearchText.swift
//  How a search query matches text, shared by search, Quick Open and the
//  page-link picker: case, accents and Arabic harakat are ignored, and so
//  are Arabic spelling variants the system comparison doesn't fold - alef
//  with hamza or madda (أ إ آ ٱ) matches plain alef (ا), and tatweel (ـ)
//  is ignored.

import Foundation

enum SearchText {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    private static let alefVariants: Set<Unicode.Scalar> = ["\u{0622}", "\u{0623}", "\u{0625}", "\u{0671}"]
    private static let tatweel: Unicode.Scalar = "\u{0640}"

    static func matches(_ text: String, _ query: String) -> Bool {
        range(of: query, in: text) != nil
    }

    /// Where `query` occurs in `text`. When only the folded forms match, the
    /// range is mapped back by character offset (tatweel removed before the
    /// match can shift it by a few characters; fine for snippets).
    static func range(of query: String, in text: String) -> Range<String.Index>? {
        guard !query.isEmpty else { return nil }
        if let direct = text.range(of: query, options: options) { return direct }
        guard needsFolding(text) || needsFolding(query) else { return nil }
        let folded = fold(text)
        guard let match = folded.range(of: fold(query), options: options) else { return nil }
        let start = folded.distance(from: folded.startIndex, to: match.lowerBound)
        let length = folded.distance(from: match.lowerBound, to: match.upperBound)
        let lower = text.index(text.startIndex, offsetBy: start, limitedBy: text.endIndex) ?? text.endIndex
        let upper = text.index(lower, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
        return lower..<upper
    }

    /// `text` with alef variants made plain and tatweel removed.
    static func fold(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar != tatweel {
            scalars.append(alefVariants.contains(scalar) ? "\u{0627}" : scalar)
        }
        return String(scalars)
    }

    private static func needsFolding(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 == tatweel || alefVariants.contains($0) }
    }
}
