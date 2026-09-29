import Foundation

/// A line of a back-of-book index, such as "compact set, 12, 34–35". Its page-number links
/// (makeindex with hyperref) name only the top of the page, so the term has to be found on it.
public enum IndexEntry {
    private static let number = #"(?:\d+|[ivxlcdm]+)(?:\s*[–—-]+\s*(?:\d+|[ivxlcdm]+))?(?:\s*ff?\.?)?"#
    /// A term, then a comma or dot leaders, then page numbers and ranges separated by commas.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*(.*?\p{L}.*?)\s*(?:,|(?:\s*\.){2,})\s*\#(number)(?:\s*,\s*\#(number))*\s*$"#,
        options: [.caseInsensitive])

    /// The term of an index line, or nil if the line doesn't end in page numbers.
    public static func term(ofLine line: String) -> String? {
        let ns = line as NSString
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let term = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        return term.isEmpty ? nil : term
    }

    /// Whether a link's own text is a page number or range ("12", "xiv", "34–35").
    public static func isPageNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
        return trimmed.range(of: "^\(number)$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What to look for on the target page, best first: for a subentry, the two terms together
    /// ("sequentially compact"); the entry's term; its parent's; then their words, longest first
    /// (the text may say "compactness" for "compact").
    public static func searchTerms(term: String, parent: String?) -> [String] {
        let phrases = parent.map { ["\(term) \($0)", "\($0) \(term)", term, $0] } ?? [term]
        let words = [term, parent].compactMap { $0 }
            .flatMap { $0.components(separatedBy: CharacterSet.letters.inverted) }
            .filter { $0.count >= 4 }
            .sorted { $0.count > $1.count }
        var seen = Set<String>()
        return (phrases + words).filter { seen.insert($0.lowercased()).inserted }
    }
}
