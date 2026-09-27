import Foundation

/// Finds what changed between two versions of a document, for the after-reload margin marker.
///
/// The app compares the text lines around the viewport. Lines are matched with a longest
/// common subsequence, so text that merely moved (because a paragraph was added above it, even
/// across a page break) matches, and only new or edited lines count as changed. Comparing
/// pixels instead fails here: LaTeX re-stretches vertical space, so moved text lands on
/// different sub-pixel offsets and no longer looks identical.
public enum ChangeDetector {
    /// Elements of `new` with no counterpart in `old`, merged into bands. A deletion (old
    /// elements with nothing new in their place) is an empty range at the index where it happened.
    public static func changedBands<Element: Equatable>(old: [Element], new: [Element], mergeGap: Int = 0) -> [Range<Int>] {
        let n = old.count, m = new.count
        guard n > 0, m > 0 else { return m > 0 ? [0..<m] : [] }
        guard old != new else { return [] }

        // lcs[i][j] = LCS length of old[i...] and new[j...], in a flat table.
        let width = m + 1
        var lcs = [UInt16](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i * width + j] = old[i] == new[j]
                    ? lcs[(i + 1) * width + j + 1] + 1
                    : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
            }
        }

        var changed: [Range<Int>] = []
        var i = 0, j = 0
        var inserted: Int?
        var deletedHere = false
        func flush(at row: Int) {
            if let start = inserted { changed.append(start..<row) } else if deletedHere { changed.append(row..<row) }
            inserted = nil
            deletedHere = false
        }
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] {
                flush(at: j)
                i += 1
                j += 1
            } else if j < m, i == n || lcs[i * width + j + 1] >= lcs[(i + 1) * width + j] {
                if inserted == nil { inserted = j }
                j += 1
            } else {
                deletedHere = true
                i += 1
            }
        }
        flush(at: m)
        return merge(changed, gap: mergeGap)
    }

    /// Joins bands closer than `gap` rows (a changed paragraph with unchanged blank rows between lines).
    static func merge(_ bands: [Range<Int>], gap: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for band in bands {
            if let last = result.last, band.lowerBound - last.upperBound <= gap {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, band.upperBound)
            } else {
                result.append(band)
            }
        }
        return result
    }
}
