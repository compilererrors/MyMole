import SwiftUI

/// Native buttons and menus share their outline and corner shape in reviews.
extension View {
    func dialogControls() -> some View {
        buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: DS.Radius.control))
            .controlSize(.regular)
    }
}
