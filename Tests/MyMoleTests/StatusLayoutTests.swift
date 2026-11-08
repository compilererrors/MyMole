import Foundation
import Testing

@testable import MyMole

@Suite struct StatusLayoutTests {
    @Test func customizationRoundTripsAndEveryCardRemainsRecoverable() {
        var layout = StatusLayout()
        layout.setSize(.compact, for: .health)
        layout.setVisible(false, for: .network)
        layout.move(.memory, by: -1)
        #expect(StatusLayout.read(layout.saved) == layout)
        #expect(layout.cards[1].id == .memory)
        for id in StatusCardID.allCases { layout.setVisible(false, for: id) }
        #expect(StatusLayout.read(layout.saved).visible.isEmpty)
        layout.setVisible(true, for: .cpu)
        #expect(layout.visible.map(\.id) == [.cpu])
    }

    @Test func damagedUnknownAndOversizedPreferencesRecoverToDefaults() {
        #expect(StatusLayout.read("not json") == StatusLayout())
        #expect(StatusLayout.read("{\"version\":99,\"cards\":[]}") == StatusLayout())
        #expect(StatusLayout.read(String(repeating: "x", count: 20_000)) == StatusLayout())
        let duplicate = StatusLayout.Card(id: .cpu, size: .compact, visible: false)
        let normalized = StatusLayout(cards: [duplicate, duplicate])
        #expect(normalized.cards.count == StatusCardID.allCases.count)
        #expect(normalized.cards.first == duplicate)
    }

    @Test func visibleMovesAndDragMovesPreserveIdentityAndConfiguration() {
        var layout = StatusLayout()
        layout.setVisible(false, for: .cpu)
        layout.move(.memory, by: -1, visibleOnly: true)
        #expect(layout.visible.first?.id == .memory)
        let battery = layout.cards.first { $0.id == .battery }!
        layout.move(from: IndexSet(integer: 6), to: 0)
        #expect(layout.cards.first == battery)
        #expect(Set(layout.cards.map(\.id)).count == StatusCardID.allCases.count)
    }

    @Test func geometryDependsOnPreferencesAndWidthInsteadOfContentMeasurements() {
        let sizes: [StatusCardSize] = [.standard, .compact, .wide, .standard]
        let before = StatusGrid.frames(sizes: sizes, width: 700, spacing: 15)
        #expect(before[0].height == 320 && before[1].height == 240)
        #expect(before[2].width == 700 && before[2].minX == 0)
        for width in [CGFloat(1), 260, 700, 1200, .infinity] {
            let frames = StatusGrid.frames(sizes: sizes, width: width, spacing: 15)
            for i in frames.indices {
                #expect(frames[i].width > 0 && frames[i].minX >= 0)
                for j in frames.indices where j > i { #expect(!frames[i].intersects(frames[j])) }
            }
        }
    }

    @Test func aRecycledPIDCannotMatchTheAppTheUserConfirmed() {
        let target = StatusAppTarget(
            pid: 42, launched: Date(timeIntervalSince1970: 10), bundle: URL(fileURLWithPath: "/synthetic/Example.app"), name: "Example")
        #expect(target.matches(target))
        #expect(!target.matches(nil))
        #expect(
            !target.matches(StatusAppTarget(pid: 42, launched: Date(timeIntervalSince1970: 11), bundle: target.bundle, name: target.name)))
        #expect(
            !target.matches(
                StatusAppTarget(pid: 42, launched: target.launched, bundle: URL(fileURLWithPath: "/synthetic/Other.app"), name: target.name)
            ))
        #expect(!target.matches(StatusAppTarget(pid: 43, launched: target.launched, bundle: target.bundle, name: target.name)))
    }
}
