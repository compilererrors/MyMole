import AppKit
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

    static var isGranted: Bool {
        let home = URL(fileURLWithPath: Home.path)
        for rel in probes {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: home.appending(path: rel).path)
                return true
            } catch let e as CocoaError where e.code == .fileReadNoPermission {
                return false
            } catch {
                continue
            }
        }
        return true
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
