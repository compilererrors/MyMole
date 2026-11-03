import StorageKit
import SwiftUI

/// How recently a project was worked on, from the newest change anywhere
/// in its footprint. Hot projects are the ones growing right now; dormant
/// ones are where old build output and sessions pile up unnoticed.
enum Heat: Int, CaseIterable, Comparable {
    case today, week, month, dormant

    init(_ last: Date, now: Date = Date()) {
        let days = now.timeIntervalSince(last) / 86_400
        self = days < 1 ? .today : days < 7 ? .week : days < 30 ? .month : .dormant
    }

    static func < (a: Heat, b: Heat) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .today: "Active today"
        case .week: "Active this week"
        case .month: "Active this month"
        case .dormant: "Dormant"
        }
    }

    var symbol: String { self == .dormant ? "moon.zzz" : "flame.fill" }

    var color: Color {
        switch self {
        case .today: .red
        case .week: .orange
        case .month: .yellow
        case .dormant: .secondary
        }
    }

    var nsColor: NSColor {
        switch self {
        case .today: .systemRed
        case .week: .systemOrange
        case .month: .systemYellow
        case .dormant: .tertiaryLabelColor
        }
    }
}

extension FootprintCategory {
    var color: Color {
        switch self {
        case .source: Color(hue: 0.60, saturation: 0.08, brightness: 0.62)
        case .git: Color(hue: 0.07, saturation: 0.45, brightness: 0.70)
        case .dependencies: Color(hue: 0.76, saturation: 0.50, brightness: 0.88)
        case .build: Color(hue: 0.60, saturation: 0.60, brightness: 0.92)
        case .caches: Color(hue: 0.48, saturation: 0.55, brightness: 0.80)
        case .localData: Color(hue: 0.08, saturation: 0.65, brightness: 0.95)
        case .worktrees: Color(hue: 0.68, saturation: 0.45, brightness: 0.80)
        case .agentSessions: Color(hue: 0.92, saturation: 0.50, brightness: 0.92)
        case .appData: Color(hue: 0.36, saturation: 0.50, brightness: 0.78)
        case .marked: Color(hue: 0.14, saturation: 0.70, brightness: 0.92)
        case .kept: Color(hue: 0.60, saturation: 0.05, brightness: 0.45)
        }
    }
}
