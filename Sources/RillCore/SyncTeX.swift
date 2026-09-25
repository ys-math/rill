import CoreGraphics
import CSynctex
import Foundation

/// A region of the PDF that SyncTeX ties to a source location.
public struct SyncTeXBox: Equatable, Sendable {
    /// 0-based page index.
    public var page: Int
    /// In PDF points, origin at the page's top-left.
    public var rect: CGRect

    public init(page: Int, rect: CGRect) {
        self.page = page
        self.rect = rect
    }
}

/// Wraps the official SyncTeX parser for one compiled PDF.
///
/// The `.synctex(.gz)` file is found next to the PDF. The scanner is not thread-safe;
/// use one instance from one thread at a time.
public final class SyncTeX {
    private let scanner: synctex_scanner_p

    /// Returns nil if there is no SyncTeX data for `pdfPath`.
    public init?(pdfPath: String) {
        guard let scanner = synctex_scanner_new_with_output_file(pdfPath, nil, 1) else { return nil }
        self.scanner = scanner
    }

    deinit {
        synctex_scanner_free(scanner)
    }

    /// Forward search: the text line in the PDF that best matches `line` (and `column`) of `file`,
    /// as the boxes on that line.
    ///
    /// SyncTeX's first result is its best match; the rest are fallbacks that can cover much of
    /// the page (e.g. text from macros like `\lipsum` that has no source line of its own). Only
    /// boxes sharing the best match's text line are kept.
    public func boxes(for location: SourceLocation) -> [SyncTeXBox] {
        guard synctex_display_query(scanner, location.file, Int32(location.line), Int32(location.column), -1) > 0 else {
            return []
        }
        var boxes: [SyncTeXBox] = []
        while let node = synctex_scanner_next_result(scanner) {
            let page = Int(synctex_node_page(node)) - 1
            let h = CGFloat(synctex_node_box_visible_h(node))
            let v = CGFloat(synctex_node_box_visible_v(node))
            let width = abs(CGFloat(synctex_node_box_visible_width(node)))
            let height = CGFloat(synctex_node_box_visible_height(node))
            let depth = CGFloat(synctex_node_box_visible_depth(node))
            // v is the baseline; height rises above it and depth hangs below.
            boxes.append(SyncTeXBox(page: page, rect: CGRect(x: h, y: v - height, width: width, height: height + depth)))
        }
        guard let best = boxes.first else { return [] }
        return boxes.filter { $0.page == best.page && Self.shareLine($0.rect, best.rect) }
    }

    /// Two boxes are on the same text line if they overlap vertically by at least half the shorter one.
    static func shareLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap >= min(a.height, b.height) / 2
    }

    /// Inverse search: the source line that produced the point (`x`, `y`) on `page`
    /// (0-based, PDF points from the page's top-left).
    public func location(page: Int, x: CGFloat, y: CGFloat) -> SourceLocation? {
        guard synctex_edit_query(scanner, Int32(page + 1), Float(x), Float(y)) > 0,
              let node = synctex_scanner_next_result(scanner),
              let name = synctex_scanner_get_name(scanner, synctex_node_tag(node))
        else { return nil }
        let file = URL(fileURLWithPath: String(cString: name)).standardizedFileURL.path
        return SourceLocation(line: Int(synctex_node_line(node)), column: max(Int(synctex_node_column(node)), 0), file: file)
    }
}
