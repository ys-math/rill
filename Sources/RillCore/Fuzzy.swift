import Foundation

/// fzf-style fuzzy matching: the query's characters must appear in order; matches at word
/// starts and in consecutive runs score higher, gaps score lower. Smart-case like search.
public enum Fuzzy {
    public struct Match: Equatable, Sendable {
        public var score: Double
        /// Offsets (in Characters) of the matched characters, for highlighting.
        public var positions: [Int]
    }

    static let wordStartBonus = 8.0
    static let consecutiveBonus = 6.0
    static let firstCharacterBonus = 4.0
    static let gapPenalty = 0.15
    static let separators: Set<Character> = ["/", "_", "-", ".", " ", ":", "(", ")"]

    public static func match(_ query: String, in candidate: String) -> Match? {
        let q = Array(query.filter { !$0.isWhitespace })
        guard !q.isEmpty else { return Match(score: 0, positions: []) }
        let caseSensitive = q.contains { $0.isUppercase }
        let normalize: (Character) -> Character = { caseSensitive ? $0 : Character($0.lowercased()) }
        let c = Array(candidate)
        let cn = c.map(normalize)
        let qn = q.map(normalize)

        // Try every place the first query character occurs and keep the best greedy alignment.
        var best: Match?
        for start in cn.indices where cn[start] == qn[0] {
            guard let aligned = align(qn, cn, original: c, from: start) else { break } // later starts can't fit either
            if best == nil || aligned.score > best!.score { best = aligned }
        }
        return best
    }

    private static func align(_ q: [Character], _ c: [Character], original: [Character], from start: Int) -> Match? {
        var positions: [Int] = []
        var score = 0.0
        var i = start
        /// The bonus of the character that started the current run; the rest of the run earns
        /// at least as much (as in fzf), so "cat" in "category" beats "c_a_t"-style scatter.
        var runBonus = 0.0
        for (k, qc) in q.enumerated() {
            // Prefer the next occurrence at a word start within reach over the nearest one.
            guard let nearest = c[i...].firstIndex(of: qc) else { return nil }
            var chosen = nearest
            if k > 0, !(positions.last.map { nearest == $0 + 1 } ?? false) {
                if let boundary = c[nearest...].indices.first(where: { c[$0] == qc && isWordStart(original, $0) }),
                   boundary - nearest <= 12 {
                    chosen = boundary
                }
            }
            score += 1
            if chosen == 0 { score += firstCharacterBonus }
            if let last = positions.last, chosen == last + 1 {
                score += max(consecutiveBonus, runBonus)
            } else {
                runBonus = isWordStart(original, chosen) ? wordStartBonus : 0
                score += runBonus
                if let last = positions.last { score -= gapPenalty * Double(chosen - last - 1) }
            }
            positions.append(chosen)
            i = chosen + 1
        }
        // Shorter candidates win ties: "rill.pdf" beats "rill-old-draft.pdf" for "rill".
        score -= Double(c.count) * 0.01
        return Match(score: score, positions: positions)
    }

    static func isWordStart(_ s: [Character], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let previous = s[i - 1], current = s[i]
        if separators.contains(previous) { return true }
        return previous.isLowercase && current.isUppercase   // camelCase
            || (previous.isLetter && current.isNumber)
    }
}

/// `/Users/me/Papers/x.pdf` → `~/Papers/x.pdf`.
public func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {
    path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// `~/Papers` → `/Users/me/Papers`.
public func expandHome(_ path: String, home: String = NSHomeDirectory()) -> String {
    path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
}

/// Names that tell files apart: the file name alone when it's unique, otherwise the shortest
/// run of parent folders that makes it unique, e.g. `homological_algebra/main.pdf` next to
/// `topology/main.pdf`.
public func distinguishingNames(_ paths: [String]) -> [String] {
    let components = paths.map { $0.split(separator: "/").map(String.init) }
    var depth = [Int](repeating: 1, count: paths.count)
    func name(_ i: Int) -> String { components[i].suffix(depth[i]).joined(separator: "/") }
    while true {
        let groups = Dictionary(grouping: paths.indices, by: name).values.filter { $0.count > 1 }
        var grew = false
        for group in groups {
            for i in group where depth[i] < components[i].count {
                depth[i] += 1
                grew = true
            }
        }
        if !grew { break }
    }
    return paths.indices.map(name)
}
