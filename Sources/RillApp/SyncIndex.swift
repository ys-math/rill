import CoreGraphics
import Foundation
import RillCore

/// SyncTeX lookups for one PDF, off the main thread. The `.synctex(.gz)` file is re-parsed
/// only when it changes, i.e. after a recompile.
actor SyncIndex {
    let pdfPath: String
    private var cached: (modified: Date, sync: SyncTeX)?

    init(pdfPath: String) {
        self.pdfPath = pdfPath
    }

    func boxes(for location: SourceLocation) -> [SyncTeXBox] {
        current()?.boxes(for: location) ?? []
    }

    func location(page: Int, x: CGFloat, y: CGFloat) -> SourceLocation? {
        current()?.location(page: page, x: x, y: y)
    }

    var hasData: Bool { current() != nil }

    private func current() -> SyncTeX? {
        guard let modified = dataFileModified() else {
            cached = nil
            return nil
        }
        if let cached, cached.modified == modified { return cached.sync }
        guard let sync = SyncTeX(pdfPath: pdfPath) else { return nil }
        cached = (modified, sync)
        return sync
    }

    private func dataFileModified() -> Date? {
        let base = (pdfPath as NSString).deletingPathExtension
        for candidate in [base + ".synctex.gz", base + ".synctex"] {
            if let date = (try? FileManager.default.attributesOfItem(atPath: candidate))?[.modificationDate] as? Date {
                return date
            }
        }
        return nil
    }
}
