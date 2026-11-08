import Foundation

enum StatusCardID: String, Codable, CaseIterable, Identifiable {
    case health, cpu, memory, storage, diskIO, network, battery, processes
    var id: Self { self }

    var title: String {
        switch self {
        case .health: String(localized: "Health")
        case .cpu: String(localized: "CPU")
        case .memory: String(localized: "Memory")
        case .storage: String(localized: "Storage")
        case .diskIO: String(localized: "Disk I/O")
        case .network: String(localized: "Network")
        case .battery: String(localized: "Battery")
        case .processes: String(localized: "Top processes")
        }
    }

    var symbol: String {
        switch self {
        case .health: "heart.text.square"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .diskIO: "arrow.up.arrow.down"
        case .network: "network"
        case .battery: "battery.100percent"
        case .processes: "list.bullet.rectangle"
        }
    }
}

enum StatusCardSize: String, Codable, CaseIterable, Identifiable {
    case compact, standard, wide
    var id: Self { self }
    var span: Int { self == .wide ? 2 : 1 }
    var height: CGFloat { self == .compact ? 240 : 320 }
    var title: String {
        switch self {
        case .compact: String(localized: "Compact")
        case .standard: String(localized: "Standard")
        case .wide: String(localized: "Wide")
        }
    }
}

/// Only presentation preferences are saved: no readings or machine identities.
struct StatusLayout: Codable, Equatable {
    static let key = "status.layout.v1"
    struct Card: Codable, Equatable, Identifiable {
        let id: StatusCardID
        var size: StatusCardSize
        var visible: Bool
    }
    var cards: [Card]
    private var version = 1

    init(cards: [Card] = []) {
        var seen = Set<StatusCardID>()
        self.cards = cards.filter { seen.insert($0.id).inserted }
        self.cards += StatusCardID.allCases.filter { !seen.contains($0) }.map {
            Card(id: $0, size: $0 == .processes ? .wide : .standard, visible: true)
        }
    }

    var visible: [Card] { cards.filter(\.visible) }

    static func read(_ value: String) -> Self {
        guard value.utf8.count <= 16_384, let data = value.data(using: .utf8),
            let saved = try? JSONDecoder().decode(Self.self, from: data), saved.version == 1
        else {
            return Self()
        }
        return Self(cards: saved.cards)
    }

    var saved: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    mutating func setVisible(_ visible: Bool, for id: StatusCardID) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].visible = visible
    }

    mutating func setSize(_ size: StatusCardSize, for id: StatusCardID) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].size = size
    }

    mutating func move(_ id: StatusCardID, by offset: Int, visibleOnly: Bool = false) {
        let order = visibleOnly ? visible.map(\.id) : cards.map(\.id)
        guard let i = order.firstIndex(of: id), order.indices.contains(i + offset),
            let from = cards.firstIndex(where: { $0.id == id }), let to = cards.firstIndex(where: { $0.id == order[i + offset] })
        else { return }
        cards.swapAt(from, to)
    }

    mutating func move(from offsets: IndexSet, to destination: Int) {
        let moving = cards.enumerated().filter { offsets.contains($0.offset) }.map(\.element)
        guard !moving.isEmpty, (0...cards.count).contains(destination) else { return }
        let insertion = destination - offsets.filter { $0 < destination }.count
        cards = cards.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        cards.insert(contentsOf: moving, at: min(max(0, insertion), cards.count))
    }
}
