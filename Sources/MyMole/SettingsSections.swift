import Foundation

/// Search describes controls, rather than indexing private paths in their values.
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, menuBar, background, performance, loading, diskMap, confirmations
    case diskAccess, appManagement, timings, folderAccess, systemTasks, keep, systemKeep, about, uninstall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: String(localized: "Appearance")
        case .menuBar: String(localized: "Menu Bar")
        case .background: String(localized: "In the Background")
        case .performance: String(localized: "Performance")
        case .loading: String(localized: "Loading and Memory")
        case .diskMap: String(localized: "Disk Map")
        case .confirmations: String(localized: "Confirmations")
        case .diskAccess: String(localized: "Full Disk Access")
        case .appManagement: String(localized: "App Management")
        case .timings: String(localized: "Timings")
        case .folderAccess: String(localized: "Folder Access")
        case .systemTasks: String(localized: "System Tasks")
        case .keep: String(localized: "Deep Clean Keep List")
        case .systemKeep: String(localized: "System Clean Keep List")
        case .about: String(localized: "About")
        case .uninstall: String(localized: "Uninstall MyMole")
        }
    }

    private var terms: String {
        switch self {
        case .appearance: String(localized: "Appearance Theme Layout Table lines light dark system density compact spacious grid rows Native Graphite Blue Fjord Paper")
        case .menuBar: String(localized: "Show MyMole in the menu bar Show free space beside the icon Open MyMole at login Open Login Items launch startup close window quit")
        case .background: String(localized: "Scan in the background Notify me when the disk is nearly full Notify me when a scan finds a lot to clean Notify me when an app in the Trash left things behind Notify me when an app keeps the processor busy notifications alerts schedule daily weekly")
        case .performance: String(localized: "Scan speed Gentle Light Balanced Full Default Reset threads processor power")
        case .loading: String(localized: "Get every pane ready at launch Disk map history scans per folder Saved results Each kind Clear Saved Results Remove prefetch memory cache storage")
        case .diskMap: String(localized: "excluded skipped folders scan again browse")
        case .confirmations: String(localized: "ask again dialogs warnings trash delete safety restore reset remember")
        case .diskAccess: String(localized: "permissions privacy protected folders settings")
        case .appManagement: String(localized: "permissions privacy uninstall cannot move Trash administrator approval delete other apps Finder")
        case .timings: String(localized: "Keep timings of the interface Copy Timings Clear benchmark slow speed median p95 filter sort redraw menus first content")
        case .folderAccess: String(localized: "Your home folder Applications The startup disk Give Access Take Back permissions bookmarks sandbox")
        case .systemTasks: String(localized: "administrator password root helper privileged")
        case .keep, .systemKeep: String(localized: "Always Keep Remove Try Again Discard Change protected files folders never remove safety rules")
        case .about: String(localized: "MyMole License Support website source available")
        case .uninstall: String(localized: "remove MyMole itself self uninstall quit leftovers settings caches data")
        }
    }

    static func matching(_ query: String, sandboxed: Bool, systemTasks: Bool) -> [Self] {
        let search = TextQuery(query)
        return allCases.filter { section in
            if section == .folderAccess, !sandboxed { return false }
            if section == .systemTasks, sandboxed { return false }
            if section == .systemKeep, !systemTasks { return false }
            let actions = section == .confirmations ? ConfirmationAction.allCases.map(\.title).joined(separator: " ") : ""
            return search.matches(section.title, section.terms, actions)
        }
    }
}
