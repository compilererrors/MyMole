import Foundation
import SystemKit
import Testing

@testable import MyMole

@Suite struct StatusLayoutTests {
    @Test func customizationRoundTripsAndEveryCardRemainsRecoverable() {
        var layout = StatusLayout()
        layout.setSize(.compact, for: .health)
        layout.setVisible(false, for: .network)
        layout.move(.memory, by: -1)
        #expect(StatusLayout.read(layout.saved) == layout)
        #expect(layout.cards.first?.id == .memory)
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
        layout.move(from: IndexSet(integer: layout.cards.firstIndex { $0.id == .battery }!), to: 0)
        #expect(layout.cards.first == battery)
        #expect(Set(layout.cards.map(\.id)).count == StatusCardID.allCases.count)
    }

    @Test func geometryDependsOnPreferencesAndWidthInsteadOfContentMeasurements() {
        let cards: [StatusLayout.Card] = [
            .init(id: .cpu, size: .standard, visible: true), .init(id: .diskIO, size: .compact, visible: true),
            .init(id: .processes, size: .wide, visible: true), .init(id: .memory, size: .standard, visible: true),
        ]
        let before = StatusGrid.frames(cards: cards, width: 700, spacing: 15)
        #expect(before[0].height == 200 && before[1].height == 200)
        #expect(before[2].width == 700 && before[2].minX == 0)
        for width in [CGFloat(1), 260, 700, 1200, .infinity] {
            let frames = StatusGrid.frames(cards: cards, width: width, spacing: 15)
            for i in frames.indices {
                #expect(frames[i].width > 0 && frames[i].minX >= 0)
                for j in frames.indices where j > i { #expect(!frames[i].intersects(frames[j])) }
            }
        }
    }

    @Test func rowEdgesStayAlignedAndEveryRowFillsTheAvailableWidth() {
        let widths: [CGFloat] = [1, 260, 575, 590, 700, 900, 1120, 1600, .infinity]
        for compact in [false, true] {
            for sample in 0..<64 {
                let cards = StatusCardID.allCases.enumerated().compactMap { index, id -> StatusLayout.Card? in
                    guard (sample & (1 << (index % 6))) == 0 else { return nil }
                    return .init(id: id, size: StatusCardSize.allCases[(index + sample) % 3], visible: true)
                }
                for width in widths {
                    let spacing: CGFloat = compact ? 12 : 15
                    let expectedWidth = width.isFinite ? max(1, width) : 900
                    let frames = StatusGrid.frames(cards: cards, width: width, spacing: spacing, compactDensity: compact)
                    #expect(frames.count == cards.count)
                    let rows = Dictionary(grouping: frames, by: \.minY).sorted { $0.key < $1.key }
                    var previousBottom: CGFloat = -spacing
                    for (top, row) in rows {
                        #expect(abs(top - previousBottom - spacing) < 0.001)
                        var right: CGFloat = -spacing
                        for frame in row.sorted(by: { $0.minX < $1.minX }) {
                            #expect(abs(frame.minX - right - spacing) < 0.001)
                            #expect(frame.width > 0 && frame.height == row[0].height)
                            right = frame.maxX
                        }
                        #expect(abs(right - expectedWidth) < 0.001)
                        previousBottom = top + row[0].height
                    }
                }
            }
        }
    }

    @Test func showingHiddenCardsAndDroppingPreserveSizeAndRelativeOrder() {
        var layout = StatusLayout()
        layout.setSize(.wide, for: .cpu)
        layout.setSize(.compact, for: .network)
        layout.setVisible(false, for: .memory)
        let previous = layout.cards
        layout.move(.battery, before: .cpu)
        #expect(layout.cards.first?.id == .battery)
        #expect(layout.cards.filter { $0.id != .battery } == previous.filter { $0.id != .battery })
        let moved = layout
        layout.move(.cpu, before: .memory)
        #expect(layout == moved)
        layout.move(.battery, before: nil)
        #expect(layout.cards.last?.id == .battery)
        for id in StatusCardID.allCases { layout.setVisible(false, for: id) }
        let hidden = layout.cards
        #expect(StatusLayout.read(layout.saved).hidden.count == StatusCardID.allCases.count)
        layout.showAll()
        #expect(layout.cards.map(\.id) == hidden.map(\.id))
        #expect(layout.cards.map(\.size) == hidden.map(\.size))
        #expect(layout.visible.count == StatusCardID.allCases.count)
    }

    @Test func aDragIsLimitedToItsLayoutSessionAndVisibleCards() throws {
        let session = UUID()
        let drag = StatusCardDrag(card: .cpu, session: session)
        var layout = StatusLayout()
        #expect(drag.canMove(in: layout, session: session, before: .memory))
        #expect(drag.canMove(in: layout, session: session, before: nil))
        #expect(!drag.canMove(in: layout, session: UUID(), before: .memory))
        #expect(!drag.canMove(in: layout, session: session, before: .cpu))
        layout.setVisible(false, for: .memory)
        #expect(!drag.canMove(in: layout, session: session, before: .memory))
        layout.setVisible(false, for: .cpu)
        #expect(!drag.canMove(in: layout, session: session, before: nil))
        let data = try JSONEncoder().encode(drag)
        #expect(try JSONDecoder().decode(StatusCardDrag.self, from: data).card == .cpu)
        #expect(try JSONSerialization.jsonObject(with: data) as? [String: String] == ["card": "cpu", "session": session.uuidString])
    }

    @Test func defaultOverviewUsesLessHeightAndLegacyPreferencesKeepTheirOrder() {
        let layout = StatusLayout()
        let frames = StatusGrid.frames(cards: layout.visible, width: 1120, spacing: 15)
        #expect(layout.visible.prefix(3).map(\.id) == [.cpu, .memory, .storage])
        #expect((frames.map(\.maxY).max() ?? 0) <= 680)
        let legacy = "{\"version\":1,\"cards\":[{\"id\":\"health\",\"size\":\"wide\",\"visible\":false},{\"id\":\"cpu\",\"size\":\"compact\",\"visible\":true}]}"
        let restored = StatusLayout.read(legacy)
        #expect(restored.cards[0].id == .health && !restored.cards[0].visible && restored.cards[0].size == .wide)
        #expect(restored.cards[1].id == .cpu && restored.cards[1].size == .compact)
        #expect(StatusLayout.read(restored.saved) == restored)
        #expect(Set(restored.cards.map(\.id)) == Set(StatusCardID.allCases))
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

    @Test func networkOverviewKeepsItsNamedInterfaceWithoutSummingAVPNCopy() {
        let physical = SystemSnapshot.Interface(name: "en0", address: nil, received: 12_000, sent: 4_000)
        let tunnel = SystemSnapshot.Interface(name: "utun1", address: nil, received: 12_000, sent: 4_000)
        let peer = SystemSnapshot.Interface(name: "awdl0", address: nil, received: 0, sent: 0)
        #expect(StatusTelemetry.interface(in: [tunnel, physical], selected: nil) == physical)
        #expect(StatusTelemetry.interface(in: [peer, tunnel, physical], selected: nil) == physical)
        #expect(StatusTelemetry.interface(in: [physical, tunnel], selected: tunnel.id) == tunnel)
        #expect(StatusTelemetry.interface(in: [physical], selected: tunnel.id) == physical)
        #expect(StatusTelemetry.interface(in: [], selected: physical.id) == nil)
    }
}
