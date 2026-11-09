import StorageKit
import SwiftUI

struct UninstallRowDetails: View {
    let item: Leftover?
    let canChoose: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let item {
                if !item.canRemove {
                    Label {
                        Text("Unverified — use with caution")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }.font(.callout.weight(.medium))
                    Text(canChoose
                         ? "Ownership couldn't be confirmed. Review this path before choosing it; removal always asks for confirmation."
                         : "This match can't pass the ownership or protection checks. You can inspect it in Finder.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Matched by \(item.evidence.title)").font(.callout.weight(.medium))
                    Text(item.kind == .rebuildable
                         ? "The app may rebuild or download this data again."
                         : "Removing this item can reset settings or remove local app data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DSPath(item.path, lines: 2)
            } else {
                Text("Select a file to see its full path and why it matches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .accessibilityIdentifier("uninstall.rowDetails")
    }
}
