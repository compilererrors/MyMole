import AppKit
import OSLog
import Foundation
import StorageKit

/// Whether MyMole holds Full Disk Access, and the way to grant it.
enum FullDiskAccess {
    /// Folders macOS only lets an app list with Full Disk Access. Listing
    /// one succeeds only with access; a permission error means no. Any other
    /// outcome (the folder doesn't exist on this Mac) moves on to the next
    /// probe, and if none is conclusive, access is assumed.
    private static let probes = [
        "Library/Safari",
        "Library/Mail",
        "Library/Application Support/com.apple.TCC",
    ]

    private static let log = Logger(subsystem: "com.mymole.app", category: "access")

    /// Granted, refused, or not known: none of the probes said either way.
    enum State: Equatable, Sendable {
        case granted, denied, unknown
    }

    /// Access is assumed while it's unknown, so a Mac without the probed
    /// folders isn't locked out; Settings says it couldn't tell.
    static var isGranted: Bool { state() != .denied }

    /// One listing per probe, at most three, and no prompt: listing a
    /// protected folder never asks the user.
    static func state(home: String = Home.path, list: (String) throws -> Void = { _ = try FileManager.default.contentsOfDirectory(atPath: $0) }) -> State {
        for rel in probes {
            do {
                try list(home + "/" + rel)
                log.debug("Full Disk Access probe \(rel, privacy: .public): readable")
                return .granted
            } catch let e as CocoaError where e.code == .fileReadNoPermission {
                // The underlying error can name paths: kept private in the log.
                log.debug("Full Disk Access probe \(rel, privacy: .public): no permission, \(String(describing: e.underlying), privacy: .private)")
                return .denied
            } catch {
                log.debug("Full Disk Access probe \(rel, privacy: .public): inconclusive, \(String(describing: error), privacy: .private)")
                continue
            }
        }
        return .unknown
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
