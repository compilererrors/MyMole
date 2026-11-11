import AppKit
import SwiftUI

/// The app's one quick animation, or none when Reduce Motion is on: a
/// notice or a bar then just appears, so nothing is said by movement alone.
enum Motion {
    static var snappy: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .snappy
    }

    static var content: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.2)
    }
}
