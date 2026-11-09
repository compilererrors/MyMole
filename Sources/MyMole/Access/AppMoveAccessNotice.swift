import AppKit
import StorageKit
import SwiftUI

enum AppManagementAccess {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!

    static func openSettings() { NSWorkspace.shared.open(settingsURL) }
}

/// A failed move never grants permission or starts another removal.
struct AppMoveAccessNotice: View {
    let paths: [String]
    let code: ErrorCode?
    var administratorMayBeNeeded = false

    private var message: String {
        if administratorMayBeNeeded, Edition.current.isSandboxed {
            return String(localized: "macOS denied the move of a system-owned app. This edition cannot request administrator approval. Move it in Finder, then return here to review its leftovers.")
        }
        return paths.count == 1
            ? String(localized: "macOS denied the move. File access or permissions may still block it. You can move the app in Finder; its data stays in place.")
            : String(localized: "macOS denied these moves. File access or permissions may still block them. You can use Finder; the apps' data stays in place.")
    }

    var body: some View {
        DSNotice(.warning, LocalizedStringResource(stringLiteral: message)) {
            AppManagementButton()
            Button("Show App in Finder") { FileActions.reveal(paths) }
            Menu("Details") {
                if let code {
                    Button("Copy Error Code") { CopyErrorCodeButton.copy(code) }
                }
                Button("Contact Support") { NSWorkspace.shared.open(Links.support) }
            }
            .menuStyle(.borderedButton)
            .fixedSize()
        }
    }
}

struct AppManagementButton: View {
    var title = String(localized: "App Management…")
    @State private var showing = false

    var body: some View {
        Button(title) { showing = true }
            .sheet(isPresented: $showing) { AppManagementGuide() }
    }
}

struct AppManagementGuide: View {
    @Environment(\.dismiss) private var dismiss
    private var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MyMole" }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("App Management").font(.title2.bold())
            Text("Allow this copy to uninstall apps. macOS keeps this permission separate from Full Disk Access.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if Edition.current.isSandboxed {
                Text("The App Store edition also asks you to choose the app being removed in a file dialog. App Management and Full Disk Access don't replace that file access.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.md) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(verbatim: appName).font(.headline)
                    Text("Drag this app into the App Management list.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Space.sm)
                Image(systemName: "hand.draw").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(DS.Space.md).dsCard()
            .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
            .accessibilityLabel("Drag \(appName) to App Management")
            .help(Bundle.main.bundlePath)
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                step("1", String(localized: "Open App Management below."))
                step("2", String(localized: "Add \(appName) with drag and drop, or click the + below the app list and select this copy."))
                step("3", String(localized: "Turn its switch on. Follow Quit & Reopen if macOS asks, then try the uninstall again."))
            }
            HStack(spacing: DS.Space.sm) {
                Button("Show This Copy in Finder") { FileActions.reveal([Bundle.main.bundlePath]) }
                Button("Copy App Path") { FileActions.copy([Bundle.main.bundlePath], as: .absolutePath) }
            }
            Text("If file permissions still block the move, use Show App in Finder in the review. Finder can request an administrator's approval.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            DSActionGroup {
                EmptyView()
            } trailing: {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open App Management") { AppManagementAccess.openSettings() }.primaryAction()
            }.controlSize(.large)
        }
        .padding(DS.Space.xl)
        .frame(width: 600)
        .dialogControls()
        .dialogKeyboard()
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Text(number).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).frame(width: 18)
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
