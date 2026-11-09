import AppKit
import StorageKit
import SwiftUI

/// Where MyMole is on the web. Opened as they are: nothing of the user's,
/// not even an error code, is ever added to them.
enum Links {
    /// MyMole's own page.
    static let website = URL(string: "https://mymole.viktornyberg.com")!
    /// Support, shared with the developer's other apps.
    static let support = URL(string: "https://viktornyberg.com/#support")!
}

/// An error as the user sees it: what went wrong and, when it came from an
/// error, a code to quote when asking for help. The code holds nothing
/// personal (see `ErrorCode`); the message may name a file, so only the code
/// is ever copied.
struct Problem: Equatable, CustomStringConvertible, Sendable, Error {
    let text: String
    let code: ErrorCode?

    init(_ area: ErrorCode.Area, _ error: any Error) {
        text = error.localizedDescription
        code = ErrorCode(area, error)
    }

    /// A problem MyMole explains itself, with no error behind it.
    init(_ text: String) {
        self.text = text
        code = nil
    }

    var description: String { code.map { String(localized: "\(text) Error code \($0.description).") } ?? text }
}

/// Copies an error code with MyMole's version and edition, and nothing
/// else, with the way to support beside it; shows nothing for a problem
/// without a code.
struct CopyErrorCodeButton: View {
    let code: ErrorCode?

    init(_ code: ErrorCode?) { self.code = code }

    var body: some View {
        if let code {
            Button("Copy Error Code") {
                Self.copy(code)
            }
            .help("Copies \(code.description) and MyMole's version, to quote when asking for help. No file names or paths are included.")
            Button("Get Help") { NSWorkspace.shared.open(Links.support) }
                .help("Opens support in your browser. Paste the copied error code there.")
        }
    }

    static func copy(_ code: ErrorCode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(code), forType: .string)
    }

    /// In English whatever the interface's language: it's read by support.
    static func report(_ code: ErrorCode, info: [String: Any]? = Bundle.main.infoDictionary, edition: Edition = .current) -> String {
        let version = (info?["CFBundleShortVersionString"] as? String).map { v in
            v + ((info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? "")
        } ?? "development build"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(code) · MyMole \(version), \(edition == .appStore ? "App Store" : "direct") edition, "
            + "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}
