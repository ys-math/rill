import AppKit
import RillCore

/// What visual mode needs from the document.
@MainActor
protocol VisualHost: AnyObject {
    func textIndex() -> PDFTextIndex?
    /// Selection rects per page (display coordinates), and the cursor's character rect.
    func showSelection(_ rects: [Int: [CGRect]], cursor: (page: Int, rect: CGRect)?)
    /// Keep the cursor on screen.
    func revealCursor(page: Int, rect: CGRect)
    /// Visual mode ended; `copied` is the yanked text, if any.
    func visualEnded(copied: String?)
}

/// `v` / `V`: keyboard text selection. Starts at a line picked with a hint, then Vim motions
/// extend it: h l, w b e, j k, 0 $, counts, o (swap ends), y (copy), Esc.
@MainActor
final class VisualController {
    weak var host: VisualHost?
    /// "VISUAL", "V-LINE", or nil when inactive (for the status pill).
    var onModeChange: ((String?) -> Void)?

    private(set) var isActive = false
    private var linewise = false
    private var anchor = TextPosition(page: 0, index: 0)
    private var cursor = TextPosition(page: 0, index: 0)
    private var count = ""
    /// The column j/k aim for, kept across vertical moves like Vim's.
    private var goalX: CGFloat?
    private var texts: [Int: PageText] = [:]
    /// Keys are applied strictly in order, each after the previous one's lookups finish.
    private var queue: Task<Void, Never>?

    func begin(at position: TextPosition, linewise: Bool) {
        cancel()
        isActive = true
        self.linewise = linewise
        anchor = position
        cursor = position
        onModeChange?(linewise ? "V-LINE" : "VISUAL")
        enqueue { await $0.render() }
    }

    /// Keys in visual mode; all are consumed.
    func feed(_ token: KeyToken) -> Bool {
        guard isActive else { return false }
        enqueue { await $0.handle(token) }
        return true
    }

    func cancel() {
        guard isActive else { return }
        finish(copied: nil)
    }

    private func enqueue(_ work: @escaping @MainActor (VisualController) async -> Void) {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self, self.isActive else { return }
            await work(self)
        }
    }

    private func handle(_ token: KeyToken) async {
        if let digit = token.first, token.count == 1, digit.isNumber, digit != "0" || !count.isEmpty {
            count.append(digit)
            return
        }
        let n = Int(count) ?? 1
        count = ""
        guard let index = host?.textIndex() else { return }

        switch token {
        case "<Esc>":
            return finish(copied: nil)
        case "y":
            let (from, to) = span()
            let selection = await index.selection(from: from, to: to)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selection.text, forType: .string)
            return finish(copied: selection.text)
        case "o":
            swap(&anchor, &cursor)
            goalX = nil
        case "j", "<Down>":
            await moveVertically(by: n, index: index)
        case "k", "<Up>":
            await moveVertically(by: -n, index: index)
        default:
            let motion: VisualMotion? = switch token {
            case "h", "<Left>": .left
            case "l", "<Right>": .right
            case "w": .wordForward
            case "b": .wordBackward
            case "e": .wordEnd
            case "0": .lineStart
            case "$": .lineEnd
            default: nil
            }
            guard let motion else { return }
            await load(around: cursor.page, index: index)
            let pageCount = await index.pageCount
            let texts = texts
            cursor = motion.apply(to: cursor, count: n, pageCount: pageCount) { texts[$0] }
            goalX = nil
        }
        await render()
    }

    /// j / k: the same column on the line `delta` lines away, continuing across pages.
    private func moveVertically(by delta: Int, index: PDFTextIndex) async {
        if goalX == nil { goalX = await index.characterRect(cursor)?.minX }
        let pageCount = await index.pageCount
        var page = cursor.page
        guard let text = await index.pageText(page), var line = text.lineIndex(containing: cursor.index) else { return }
        var rects = await index.lineRects(page)
        var lines = text.lines
        for _ in 0..<abs(delta) {
            if delta > 0, line + 1 < lines.count {
                line += 1
            } else if delta < 0, line > 0 {
                line -= 1
            } else {
                // Off this page's first or last line: the nearest page with text.
                var next = page + (delta > 0 ? 1 : -1)
                var found: (PageText, [CGRect])?
                while (0..<pageCount).contains(next) {
                    if let t = await index.pageText(next), !t.lines.isEmpty { found = (t, await index.lineRects(next)); break }
                    next += delta > 0 ? 1 : -1
                }
                guard let (t, r) = found else { break }
                page = next
                lines = t.lines
                rects = r
                line = delta > 0 ? 0 : lines.count - 1
            }
        }
        guard lines.indices.contains(line), rects.indices.contains(line) else { return }
        let range = lines[line], rect = rects[line]
        let x = min(max(goalX ?? rect.minX, rect.minX + 0.5), rect.maxX - 0.5)
        let hit = await index.characterIndex(page: page, at: CGPoint(x: x, y: rect.midY)) ?? range.location
        cursor = TextPosition(page: page, index: min(max(hit, range.location), NSMaxRange(range) - 1))
    }

    /// Ordered selection bounds; linewise mode widens them to whole lines.
    private func span() -> (TextPosition, TextPosition) {
        var (from, to) = anchor <= cursor ? (anchor, cursor) : (cursor, anchor)
        guard linewise else { return (from, to) }
        if let t = texts[from.page], let line = t.lineIndex(containing: from.index) { from.index = t.lines[line].location }
        if let t = texts[to.page], let line = t.lineIndex(containing: to.index) {
            to.index = max(NSMaxRange(t.lines[line]) - 1, t.lines[line].location)
        }
        return (from, to)
    }

    private func load(around page: Int, index: PDFTextIndex) async {
        for p in [page - 1, page, page + 1] where p >= 0 && texts[p] == nil {
            if let t = await index.pageText(p) { texts[p] = t }
        }
    }

    private func render() async {
        guard let index = host?.textIndex() else { return }
        await load(around: anchor.page, index: index)
        await load(around: cursor.page, index: index)
        let (from, to) = span()
        let selection = await index.selection(from: from, to: to)
        let cursorRect = await index.characterRect(cursor)
        guard isActive else { return }
        host?.showSelection(selection.rects, cursor: cursorRect.map { (cursor.page, $0) })
        if let cursorRect { host?.revealCursor(page: cursor.page, rect: cursorRect) }
    }

    private func finish(copied: String?) {
        isActive = false
        queue?.cancel()
        queue = nil
        count = ""
        goalX = nil
        texts = [:]
        onModeChange?(nil)
        host?.showSelection([:], cursor: nil)
        host?.visualEnded(copied: copied)
    }
}
