import CoreTransferable
import Foundation
import UniformTypeIdentifiers
import SwiftUI

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

    static func applying(_ items: [Self], to layout: StatusLayout, session: UUID, before target: StatusCardID?) -> StatusLayout? {
        guard items.count == 1, let item = items.first, item.canMove(in: layout, session: session, before: target) else { return nil }
        var changed = layout
        changed.move(item.card, before: target)
        return changed
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}

/// Normal telemetry controls have no drag destination over their hit regions.
/// Drop interactions exist only during an explicit layout edit.
struct StatusCardDropTarget: ViewModifier {
    let enabled: Bool
    let accept: ([StatusCardDrag]) -> Bool
    let targeted: (Bool) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: StatusCardDrag.self) { items, _ in accept(items) }
                isTargeted: { targeted($0) }
        } else { content }
    }
}
