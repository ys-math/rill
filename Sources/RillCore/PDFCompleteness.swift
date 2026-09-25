import Foundation

/// TeX engines write the PDF in place, front to back, so a file caught mid-compile is a
/// prefix of the final one. A complete PDF ends with `%%EOF` (possibly followed by a
/// newline or a little trailing whitespace).
public enum PDFCompleteness {
    /// How far from the end to look for the marker; some writers append a few bytes after it.
    static let tailWindow = 1024

    public static func looksComplete(_ data: Data) -> Bool {
        guard data.count >= 8, data.starts(with: Array("%PDF-".utf8)) else { return false }
        let tail = data.suffix(tailWindow)
        let marker = Array("%%EOF".utf8)
        guard let range = tail.lastRange(of: marker) else { return false }
        // Only whitespace may follow the marker.
        return tail[range.upperBound...].allSatisfy { $0 == 0x0A || $0 == 0x0D || $0 == 0x20 || $0 == 0x09 || $0 == 0x00 }
    }
}

private extension Data {
    func lastRange(of pattern: [UInt8]) -> Range<Index>? {
        guard count >= pattern.count else { return nil }
        var i = endIndex - pattern.count
        while i >= startIndex {
            if self[i..<(i + pattern.count)].elementsEqual(pattern) { return i..<(i + pattern.count) }
            i -= 1
        }
        return nil
    }
}
