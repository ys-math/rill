/// Vim's jump list: positions to return to with `⌃o` / `⌃i`.
///
/// Call `record(_:)` with the position being left before every jump. Going back from the
/// newest entry first saves the current position, so `⌃i` can return to it.
public struct JumpList<Position: Sendable>: Sendable {
    public let capacity: Int
    private let isSame: @Sendable (Position, Position) -> Bool
    private var entries: [Position] = []
    /// Index of the entry `⌃i` would return to; `entries.count` when at the newest position.
    private var index = 0

    public init(capacity: Int = 100, isSame: @escaping @Sendable (Position, Position) -> Bool) {
        self.capacity = capacity
        self.isSame = isSame
    }

    public var count: Int { entries.count }

    /// The position the latest jump left from (for `''`).
    public var lastJumpOrigin: Position? { entries.last }

    public mutating func record(_ current: Position) {
        // A new jump discards anything we'd gone back past, as in Vim.
        entries.removeSubrange(min(index, entries.count)...)
        if let last = entries.last, isSame(last, current) { entries.removeLast() }
        entries.append(current)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        index = entries.count
    }

    public mutating func back(from current: Position) -> Position? {
        guard index > 0 else { return nil }
        if index == entries.count {
            // Leaving the newest position: remember it so ⌃i can come back.
            if let last = entries.last, isSame(last, current) {
                index -= 1
                guard index > 0 else { index = entries.count; return nil }
            } else {
                entries.append(current)
            }
        }
        index -= 1
        return entries[index]
    }

    public mutating func forward() -> Position? {
        guard index + 1 < entries.count else { return nil }
        index += 1
        return entries[index]
    }
}

/// Hint labels: short, prefix-free strings over home-row keys, like Vimium's.
public enum HintLabels {
    public static let alphabet = Array("asdfghjkl")

    /// `count` labels, all the same length, so no label is a prefix of another.
    public static func make(_ count: Int, alphabet: [Character] = alphabet) -> [String] {
        guard count > 0, alphabet.count > 1 else { return [] }
        var length = 1
        var capacity = alphabet.count
        while capacity < count {
            length += 1
            capacity *= alphabet.count
        }
        return (0..<count).map { n in
            var n = n
            var label: [Character] = []
            for _ in 0..<length {
                label.append(alphabet[n % alphabet.count])
                n /= alphabet.count
            }
            // Vary the first key fastest across neighbouring hints.
            return String(label)
        }
    }
}
