import AppKit

enum RestoreResult: Equatable {
    case restored
    case failed
}

struct ClipboardSnapshot {
    fileprivate let items: [ClipboardManager.SavedItem]
}

/// Best-effort clipboard save/restore (§3 Decision c, AC6: "clipboard
/// restore is best-effort with verification, user notified on restore
/// failure"). Also used to preserve a transcript to the clipboard on any
/// insertion failure (§3.1 failure transitions).
struct ClipboardManager {
    fileprivate struct SavedItem {
        let types: [NSPasteboard.PasteboardType]
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    private let pasteboard = NSPasteboard.general

    /// Snapshots every item currently on the pasteboard, across all of its
    /// declared types, so `restore` can put back exactly what was there.
    func save() -> ClipboardSnapshot {
        let items = pasteboard.pasteboardItems ?? []
        let saved: [SavedItem] = items.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return SavedItem(types: item.types, dataByType: dataByType)
        }
        return ClipboardSnapshot(items: saved)
    }

    /// Writes `text` as the sole pasteboard content (used by C1 paste and
    /// by the transcript-preservation fallback on insertion failure).
    func setText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Restores a prior snapshot. Best-effort: writes back every captured
    /// type and reports `.failed` (verification) if the write is rejected,
    /// so the caller can notify the user rather than assume success.
    @discardableResult
    func restore(_ snapshot: ClipboardSnapshot) -> RestoreResult {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else {
            return .restored
        }

        let newItems = snapshot.items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for type in saved.types {
                if let data = saved.dataByType[type] {
                    item.setData(data, forType: type)
                }
            }
            return item
        }
        return pasteboard.writeObjects(newItems) ? .restored : .failed
    }
}
