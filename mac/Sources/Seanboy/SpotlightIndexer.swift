import CoreSpotlight
import Foundation
import SeanboyCore

/// Mirrors live notes into the CoreSpotlight index so system-wide Spotlight
/// search finds them; activating a result opens the note in-app.
enum SpotlightIndexer {
    private static let domain = "com.torchcodelab.seanboy.notes"

    nonisolated(unsafe) private static var pending: DispatchWorkItem?

    /// Debounced — the store calls this on every keystroke.
    static func reindexAll(notes: [Note]) {
        pending?.cancel()
        let work = DispatchWorkItem { performReindex(notes: notes) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private static func performReindex(notes: [Note]) {
        let items = notes.map { note -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = note.title
            attributes.contentDescription = String(note.body.prefix(300))
            attributes.contentModificationDate = note.modifiedAt
            return CSSearchableItem(
                uniqueIdentifier: note.id.uuidString,
                domainIdentifier: domain,
                attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { error in
                if let error {
                    NSLog("Seanboy: Spotlight indexing failed: \(error)")
                }
            }
        }
    }

    static func remove(id: UUID) {
        CSSearchableIndex.default()
            .deleteSearchableItems(withIdentifiers: [id.uuidString]) { _ in }
    }
}
