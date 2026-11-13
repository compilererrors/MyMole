import AppKit
import Testing

@testable import MyMole

@MainActor @Suite(.serialized) struct HorizontalDragHandleTests {
    @Test func accessibilityEditsStopImmediatelyWhenDisabled() {
        let handle = HorizontalDragHandleView()
        var presses = 0, adjustments: [Int] = []
        handle.onPress = { presses += 1 }
        handle.onAdjust = { adjustments.append($0) }
        #expect(handle.accessibilityPerformPress())
        #expect(handle.accessibilityPerformIncrement())
        #expect(handle.accessibilityPerformDecrement())
        #expect(presses == 1 && adjustments == [1, -1])
        handle.isEnabled = false
        #expect(!handle.acceptsFirstResponder)
        #expect(!handle.accessibilityPerformPress())
        #expect(!handle.accessibilityPerformIncrement())
        #expect(!handle.accessibilityPerformDecrement())
        #expect(presses == 1 && adjustments == [1, -1])
    }

    @Test func keyboardAlternativesUseTheSameWidthEdits() throws {
        let handle = HorizontalDragHandleView()
        var presses = 0, adjustments: [Int] = []
        handle.onPress = { presses += 1 }
        handle.onAdjust = { adjustments.append($0) }
        for (code, characters) in [(UInt16(123), "\u{F702}"), (124, "\u{F703}"), (49, " "), (36, "\r")] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                     timestamp: 1, windowNumber: 0, context: nil,
                                                     characters: characters, charactersIgnoringModifiers: characters,
                                                     isARepeat: false, keyCode: code))
            handle.keyDown(with: event)
        }
        #expect(adjustments == [-1, 1] && presses == 2)
        handle.separator = true
        #expect(!handle.accessibilityPerformPress(), "A splitter offers width adjustments rather than a no-op press")
        #expect(handle.accessibilityPerformIncrement())
        #expect(adjustments == [-1, 1, 1] && presses == 2)
    }
}
