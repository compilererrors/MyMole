import PrivilegedKit
import StorageKit

/// Freeze exactly what the user confirms. Late discovery cannot add data.
struct UninstallIntent: Sendable {
    let app: AppBundle
    let leftovers: [Leftover]
    let system: [SystemLeftover]
    let manualReview: ManualLeftoverReview?

    var needsExplicitConfirmation: Bool { !system.isEmpty || leftovers.contains { !$0.canRemove } }
}
