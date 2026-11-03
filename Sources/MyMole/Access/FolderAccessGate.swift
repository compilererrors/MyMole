import SwiftUI

/// The App Store edition's first step for a pane: choose the folder it
/// works in, once. macOS keeps MyMole to the folders the user picks.
struct FolderAccessGate: View {
    let app: AppModel
    let place: FolderAccess.Place

    var body: some View {
        CenterCard(
            symbol: "folder.badge.person.crop",
            title: "Give MyMole access to \(place.inSentence)",
            subtitle: "\(place.why) macOS lets App Store apps into the folders you choose, so choose \(place.path) in the next window. MyMole remembers it; you can take it back in Settings."
                + (app.access.lastProblem.map { "\n\n" + $0 } ?? "")
        ) {
            Button("Choose \(place.inSentence)…") {
                app.access.request(place)
                app.recheckDiskAccess()
            }
            .primaryAction()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
