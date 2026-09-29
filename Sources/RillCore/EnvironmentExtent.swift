import CoreGraphics
import Foundation

/// A piece of text on a page: a line as PDFKit reports it (display coordinates, origin top-left).
public struct TextPiece: Equatable, Sendable {
    public var rect: CGRect
    public var text: String

    public init(rect: CGRect, text: String) {
        self.rect = rect
        self.text = text
    }
}

/// Finds the block a link lands on (a theorem with its whole statement, a display equation, a
/// bibliography entry) from the page's text layout alone, since PDFs don't mark environments.
///
/// An environment ends at its end mark (□, ■), or where a vertical break (more space than
/// between lines) is followed by something that starts a new block: a heading ("Proof.",
/// "Lemma 2.3.", "定義 2.1", a section title) or an indented paragraph. List items and display
/// math inside it also sit after breaks, but they start with a label or are centered, so they
/// don't end it. One that reaches the bottom of its column unfinished continues at the top of
/// the next page.
public enum EnvironmentExtent {
    /// An environment's part on one page.
    public struct Block: Equatable, Sendable {
        /// As wide as its column.
        public var rect: CGRect
        /// It runs off the bottom of the column: the rest is at the top of the next page.
        public var continues: Bool

        public init(rect: CGRect, continues: Bool) {
            self.rect = rect
            self.continues = continues
        }
    }

    /// The environment starting at `anchor` (a link destination), or nil if no text follows it.
    public static func extent(of pieces: [TextPiece], anchor: CGPoint, maxHeight: CGFloat = .infinity) -> Block? {
        let column = Column(pieces, at: anchor.x)
        // The first line at or below the anchor, with the pieces on its baseline.
        guard let first = column.rows.firstIndex(where: { $0.pieces.contains { $0.rect.minY >= anchor.y - 3 } })
        else { return nil }
        // A section shows its heading and the block under it (its first paragraph or theorem).
        let (end, open) = column.isSection(first) && first + 1 < column.rows.count && !column.isFooter(first + 1)
            ? column.blockEnd(from: first + 1) : column.blockEnd(from: first)
        return column.block(first...end, continues: open, maxHeight: maxHeight)
    }

    /// The rest of an environment carried over from the `previous` page: the lines at the top
    /// of this one, or nil if the page starts with something new (a heading, a new paragraph,
    /// text further down than the previous page's, like a title page).
    public static func continuation(on pieces: [TextPiece], after previous: [TextPiece],
                                    maxHeight: CGFloat = .infinity) -> Block? {
        guard let left = pieces.map(\.rect.minX).min() else { return nil }
        let column = Column(pieces, at: left + 1)
        guard let first = column.firstBodyRow, !column.startsBlock(first) else { return nil }
        if let top = topOfText(previous), column.rows[first].rect.minY > top + column.lineHeight * 2 { return nil }
        let (end, open) = column.blockEnd(from: first, continuing: true)
        return column.block(first...end, continues: open, maxHeight: maxHeight)
    }

    /// The environment containing `point` (say, an index term found on the page): the one opened
    /// by the nearest heading above it, if that environment reaches down to `point`. Nil when the
    /// point is in running text, or when the environment is taller than `maxHeight`.
    public static func enclosing(_ point: CGPoint, in pieces: [TextPiece], maxHeight: CGFloat = .infinity) -> Block? {
        let column = Column(pieces, at: point.x)
        guard let index = column.headingAbove(point) else { return nil }
        let heading = column.rows[index].rect
        guard let block = extent(of: pieces, anchor: CGPoint(x: point.x, y: heading.minY), maxHeight: maxHeight),
              block.rect.minY <= point.y, point.y <= block.rect.maxY
        else { return nil }
        return block
    }

    /// Whether `point` is in the part of an environment carried over from the previous page:
    /// no heading or end mark between it and the top of the page.
    public static func isCarriedOver(_ point: CGPoint, in pieces: [TextPiece], after previous: [TextPiece]) -> Bool {
        let column = Column(pieces, at: point.x)
        guard column.headingAbove(point) == nil, !column.endsAbove(point),
              let block = continuation(on: pieces, after: previous)
        else { return false }
        return block.rect.minY <= point.y && point.y <= block.rect.maxY
    }

    /// The environment that runs off the bottom of the page into the next, if any: the one
    /// opened by the last heading in the last column.
    public static func unfinished(on pieces: [TextPiece], maxHeight: CGFloat = .infinity) -> Block? {
        guard let right = pieces.map(\.rect.maxX).max() else { return nil }
        let column = Column(pieces, at: right - 1)
        guard let heading = column.rows.lastIndex(where: { isHeading($0) }),
              let block = extent(of: pieces, anchor: CGPoint(x: column.rows[heading].rect.minX, y: column.rows[heading].rect.minY),
                                 maxHeight: maxHeight),
              block.continues
        else { return nil }
        return block
    }

    /// Where a page's text starts, below any running header.
    static func topOfText(_ pieces: [TextPiece]) -> CGFloat? {
        guard let left = pieces.map(\.rect.minX).min() else { return nil }
        let column = Column(pieces, at: left + 1)
        return column.firstBodyRow.map { column.rows[$0].rect.minY }
    }

    /// `rect` with a margin around it for showing, stopping halfway to any text above or below
    /// that isn't part of it (lines are often closer than the margin).
    public static func padded(_ rect: CGRect, among pieces: [TextPiece], margin: CGFloat = 6) -> CGRect {
        let outside = pieces.filter {
            !rect.insetBy(dx: -0.5, dy: -0.5).contains($0.rect) && $0.rect.maxX > rect.minX && $0.rect.minX < rect.maxX
        }
        let above = outside.filter { $0.rect.maxY <= rect.minY + 0.5 }.map(\.rect.maxY).max()
        let below = outside.filter { $0.rect.minY >= rect.maxY - 0.5 }.map(\.rect.minY).min()
        let top = max(rect.minY - margin, above.map { ($0 + rect.minY) / 2 } ?? -.infinity)
        let bottom = min(rect.maxY + margin, below.map { ($0 + rect.maxY) / 2 } ?? .infinity)
        return CGRect(x: rect.minX - 8, y: top, width: rect.width + 16, height: bottom - top)
    }

    // MARK: - Layout of a column

    /// The lines of one column merged into rows, with its measurements.
    struct Column {
        let rows: [Row]
        let margin: CGFloat, right: CGFloat
        let lineGap: CGFloat, lineHeight: CGFloat

        init(_ pieces: [TextPiece], at x: CGFloat) {
            rows = Row.merge(EnvironmentExtent.column(of: pieces, at: x))
            margin = rows.isEmpty ? 0 : sharedEdge(rows.map(\.rect.minX), lowest: true)
            right = rows.isEmpty ? 0 : sharedEdge(rows.map(\.rect.maxX), lowest: false)
            let gaps = zip(rows, rows.dropFirst()).map { $1.rect.minY - $0.rect.maxY }.filter { $0 > 0 }.sorted()
            lineGap = gaps.isEmpty ? 3 : gaps[gaps.count / 2]
            // From lines of text at the margin (diagram labels are small and would drag it down),
            // their lower quartile (on a sparse page a large heading may be half of them).
            let margin = margin
            let text = rows.filter { abs($0.rect.minX - margin) < 2 }
            let heights = (text.isEmpty ? rows : text).map(\.rect.height).sorted()
            lineHeight = heights.isEmpty ? 10 : heights[(heights.count - 1) / 4]
        }

        func isCentered(_ row: Row) -> Bool {
            row.rect.minX > margin + 20 && row.rect.maxX < right - 20
        }

        func isDisplay(_ index: Int) -> Bool {
            hasEquationNumber(rows[index]) || isCentered(rows[index])
        }

        func isSection(_ index: Int) -> Bool {
            let row = rows[index]
            let atMargin = abs(row.rect.minX - margin) < 2
            let large = row.rect.height > lineHeight * 1.2
            let numbered = row.text.range(of: #"^\d+(\.\d+)*\.?\s+\S"#, options: .regularExpression) != nil
            let title = row.text.range(of: #"^(\d+(\.\d+)*\.?\s+)?\p{Lu}\p{L}*(\s+\p{L}+)*$"#, options: .regularExpression) != nil
            // At the margin in a larger font, or numbered like "1 Introduction"; or a centered
            // title (not a small diagram label).
            if atMargin, !hasEquationNumber(row), !isListItem(row), large || (numbered && title) { return true }
            return isCentered(row) && title && row.text.count > 2 && row.rect.height >= lineHeight * 0.9
        }

        /// A bare number ending the column is the page number, not a subscript or limit.
        func isFooter(_ index: Int) -> Bool {
            index == rows.count - 1 && isBareNumber(rows[index])
        }

        func isParagraphStart(_ index: Int) -> Bool {
            let indent = rows[index].rect.minX - margin
            return indent > 4 && indent < 30 && !isListItem(rows[index])
        }

        /// Whether a row begins something new rather than continuing what came before.
        func startsBlock(_ index: Int) -> Bool {
            isHeading(rows[index]) || isSection(index) || isParagraphStart(index)
        }

        /// The first row below a running header or page number at the top.
        var firstBodyRow: Int? {
            var index = 0
            while index < rows.count {
                // A page number, or a small first line set well apart (a running header).
                let header = isBareNumber(rows[index]) || (index == 0 && index + 1 < rows.count
                    && rows[index].rect.height < lineHeight * 0.9 && rows[1].rect.minY - rows[0].rect.maxY > lineGap * 4)
                guard header else { return index }
                index += 1
            }
            return nil
        }

        /// The last row of the block starting at `first`, and whether it runs off the bottom of
        /// the column unfinished. `continuing` is for the top of a page, where the block's
        /// beginning is on the previous one.
        func blockEnd(from first: Int, continuing: Bool = false) -> (end: Int, open: Bool) {
            var end = first
            let head = rows[first]
            if !continuing, isDisplay(first), !isSection(first) {
                // An equation: its rows (several for align), up to the text after it.
                while end + 1 < rows.count, isDisplay(end + 1), !isFooter(end + 1) { end += 1 }
                return (end, false)
            }
            // A hanging indent (a bibliography entry, a list item) ends where the next one starts.
            let hanging = !continuing && !isHeading(head) && first + 1 < rows.count && !isDisplay(first + 1)
                && rows[first + 1].rect.minX > head.rect.minX + 3
            while end + 1 < rows.count, !endsWithQED(rows[end]) {
                let row = rows[end + 1]
                let gap = row.rect.minY - rows[end].rect.maxY
                if isFooter(end + 1) { break }
                // An end mark on its own line (pushed there by a long last line or a display).
                if row.text.count == 1, endsWithQED(row) { return (end + 1, false) }
                if hanging, abs(row.rect.minX - head.rect.minX) < 1.5 { return (end, false) }
                if gap > lineGap + 1.5, isHeading(row) || isSection(end + 1) { return (end, false) }
                if gap > lineGap + 3, !isDisplay(end + 1), !isDisplay(end), isParagraphStart(end + 1) { return (end, false) }
                end += 1
            }
            // Reached the bottom of the column without an end.
            return (end, !endsWithQED(rows[end]) && (end + 1 == rows.count || isFooter(end + 1)))
        }

        /// The nearest heading at or above `point`'s line, unless an earlier environment ends
        /// between them.
        func headingAbove(_ point: CGPoint) -> Int? {
            guard var index = rows.lastIndex(where: { $0.rect.minY <= point.y }) else { return nil }
            while !isHeading(rows[index]) {
                guard index > 0, !endsWithQED(rows[index - 1]) else { return nil }
                index -= 1
            }
            return index
        }

        /// Whether an end mark comes between the top of the column and `point`'s line.
        func endsAbove(_ point: CGPoint) -> Bool {
            rows.contains { $0.rect.maxY < point.y - 1 && endsWithQED($0) }
        }

        func block(_ range: ClosedRange<Int>, continues: Bool, maxHeight: CGFloat) -> Block {
            var rect = rows[range].reduce(rows[range.lowerBound].rect) { $0.union($1.rect) }
            let capped = rect.height > maxHeight
            if capped { rect.size.height = maxHeight }
            // As wide as the column, so the environment shows at its place in the text.
            let left = min(margin, rect.minX)
            rect = CGRect(x: left, y: rect.minY, width: max(right, rect.maxX) - left, height: rect.height)
            return Block(rect: rect, continues: continues && !capped)
        }
    }

    // MARK: - Lines

    /// Theorem-like names that open an environment, in English and Japanese.
    private static let names = [
        "Theorem", "Lemma", "Proposition", "Corollary", "Definition", "Remark", "Example", "Exercise",
        "Claim", "Conjecture", "Notation", "Fact", "Problem", "Question", "Observation", "Assumption", "Proof",
        "定理", "補題", "命題", "系", "定義", "注意", "注", "例", "演習", "問題", "事実", "主張", "予想", "記法", "証明",
    ]
    /// A name (its letters possibly spread out by justification), then a number, a period, a
    /// parenthesized title or the end of the heading.
    private static let namedHeading = try! NSRegularExpression(
        pattern: "^(?:" + names.map { $0.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s?"#) }
            .joined(separator: "|") + #")(?:\s*\d+(?:\.\d+)*|\s*[.:．]|\s*[(（]|\s|$)"#,
        options: [.caseInsensitive])

    /// "Proof.", "Lemma 2.3.", "定義 2.1", "Definition 2.1 (Compact)." at the start of a line.
    static func isHeading(_ row: Row) -> Bool {
        let text = row.text
        if namedHeading.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil { return true }
        return text.range(of: #"^\p{Lu}\p{L}+(\s+\p{L}+)?(\s+[\dA-Z]+(\.\d+)*)?\s*(\([^)]*\))?\s*\."#, options: .regularExpression) != nil
    }

    /// Ends in a proof's or theorem's end mark (□, ■, ∎).
    static func endsWithQED(_ row: Row) -> Bool {
        guard let last = row.text.last else { return false }
        return "□■∎".contains(last)
    }

    static func isListItem(_ row: Row) -> Bool {
        row.text.range(of: #"^((\d+\.|\(?[a-z\d]{1,4}\))\s|[•◦▪–—-])"#, options: .regularExpression) != nil
    }

    static func isBareNumber(_ row: Row) -> Bool {
        row.text.range(of: #"^(\d+|[ivxlc]+)$"#, options: .regularExpression) != nil
    }

    /// Starts or ends with an equation tag: "(1)", "(2.3)", "(∗)", not the "F(A)" of a formula.
    static func hasEquationNumber(_ row: Row) -> Bool {
        let tag = #"\(\s*(\d+(\.\d+)*[a-z]?|[*∗†‡′]+)\s*\)"#
        return row.text.range(of: "^\(tag)(\\s|$)|(^|\\s)\(tag)$", options: .regularExpression) != nil
    }

    // MARK: - Columns

    /// The pieces in the column at `x`: the whole page unless it has a gutter.
    static func column(of pieces: [TextPiece], at x: CGFloat) -> [TextPiece] {
        guard let gutter = gutter(of: pieces) else { return pieces }
        return pieces.filter { x < gutter ? $0.rect.maxX < gutter : $0.rect.minX > gutter }
    }

    /// The x of the gap between two columns of text: crossed by almost no line, with plenty on
    /// each side. Only lines of text count: a diagram's small labels have gaps between them too.
    static func gutter(of all: [TextPiece]) -> CGFloat? {
        guard let left = all.map(\.rect.minX).min(), let right = all.map(\.rect.maxX).max() else { return nil }
        let width = right - left
        let pieces = all.filter { $0.rect.width > width * 0.2 }
        guard pieces.count >= 8 else { return nil }
        var best: (x: CGFloat, crossing: Int)?
        for x in stride(from: left + width * 0.3, through: left + width * 0.7, by: 2) {
            let crossing = pieces.count { $0.rect.minX < x && x < $0.rect.maxX }
            guard crossing * 10 <= pieces.count,
                  pieces.count(where: { $0.rect.maxX <= x }) * 4 >= pieces.count,
                  pieces.count(where: { $0.rect.minX >= x }) * 4 >= pieces.count
            else { continue }
            if best == nil || crossing < best!.crossing { best = (x, crossing) }
        }
        return best?.x
    }

    /// The outermost value (rounded to a point) that at least two lines share, so a stray
    /// line doesn't count: the margin, say.
    static func sharedEdge(_ values: [CGFloat], lowest: Bool) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        for value in values { counts[value.rounded(), default: 0] += 1 }
        let shared = counts.filter { $0.value >= 2 }.map(\.key)
        return (lowest ? shared.min() : shared.max()) ?? values.sorted()[values.count / 2]
    }

    /// Pieces on the same baseline (an equation and its number, a formula split by PDFKit), in
    /// reading order.
    struct Row {
        var rect: CGRect
        var pieces: [TextPiece]
        var text: String { pieces.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ") }

        static func merge(_ pieces: [TextPiece]) -> [Row] {
            var rows: [Row] = []
            for piece in pieces.sorted(by: { $0.rect.minY < $1.rect.minY }) {
                if let last = rows.indices.last {
                    let overlap = min(rows[last].rect.maxY, piece.rect.maxY) - max(rows[last].rect.minY, piece.rect.minY)
                    if overlap > min(rows[last].rect.height, piece.rect.height) * 0.5 {
                        rows[last].rect = rows[last].rect.union(piece.rect)
                        rows[last].pieces.append(piece)
                        continue
                    }
                }
                rows.append(Row(rect: piece.rect, pieces: [piece]))
            }
            return rows
        }
    }
}
