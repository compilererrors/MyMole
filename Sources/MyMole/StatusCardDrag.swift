import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Only a card identity and the originating layout session travel in a drag.
struct StatusCardDrag: Codable, Transferable, Sendable {
    static let contentType = UTType(exportedAs: "app.mymole.status-card", conformingTo: .json)
    let card: StatusCardID
    let session: UUID

    func canMove(in layout: StatusLayout, session: UUID, before target: StatusCardID?) -> Bool {
        self.session == session && card != target
            && layout.visible.contains { $0.id == card }
            && (target == nil || layout.visible.contains { $0.id == target })
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}
