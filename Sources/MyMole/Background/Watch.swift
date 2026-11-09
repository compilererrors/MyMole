import AppKit
import StorageKit
import SwiftUI
import SystemKit
import UserNotifications

/// What MyMole does on its own while it runs: a scan now and then, and a
/// notification when the disk is nearly full or a scan found a lot.
/// Nothing is ever removed in the background.
enum WatchSettings {
    static let scanKey = "background.scan"
    static let diskKey = "background.notifyDisk"
    static let findsKey = "background.notifyFinds"
    static let trashedAppsKey = "background.notifyTrashedApps"
    static let busyKey = "background.notifyBusy"
    static let stateKey = "background.alerts"

    enum Cadence: String, CaseIterable, Identifiable {
        case off, daily, weekly

        static let standard = Cadence.daily
        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: String(localized: "Off")
            case .daily: String(localized: "Daily")
            case .weekly: String(localized: "Weekly")
            }
        }

        var interval: TimeInterval? {
            switch self {
            case .off: nil
            case .daily: 86_400
            case .weekly: 7 * 86_400
            }
        }
    }

    static func cadence(in defaults: UserDefaults = .standard) -> Cadence {
        defaults.string(forKey: scanKey).flatMap(Cadence.init) ?? .standard
    }
}

/// When MyMole speaks up, decided from readings and the clock it's given.
/// Each kind says its piece once and then waits: the disk until it has had
/// room again or a week has passed, the finds until a week has passed or
/// they've grown by as much again.
struct Alerts: Codable, Equatable {
    var diskSaidAt: Date?
    /// Set once free space is back above the upper mark.
    var diskArmed = true
    var findsSaidAt: Date?
    var findsSaidBytes: Int64 = 0

    static let week: TimeInterval = 7 * 86_400
    static let day: TimeInterval = 86_400
    /// A pane found at least this much before it's worth a notification.
    static let findsMinimum: Int64 = 5_000_000_000

    /// Below this much free space the disk is nearly full: a tenth of the
    /// disk, but never more than 25 GB, so a big disk isn't called full early.
    static func lowMark(total: Int64) -> Int64 { min(total / 10, 25_000_000_000) }

    /// Whether to say now that the disk is nearly full.
    mutating func diskIsLow(free: Int64, total: Int64, now: Date) -> Bool {
        let mark = Self.lowMark(total: total)
        guard total > 0, free < mark else {
            // Room again, with some to spare: the next time counts as new.
            if free >= mark + mark / 2 { diskArmed = true }
            return false
        }
        guard diskArmed || now.timeIntervalSince(diskSaidAt ?? .distantPast) >= Self.week else { return false }
        diskArmed = false
        diskSaidAt = now
        return true
    }

    /// Whether to say now what a scan found; `largest` is the most one pane found.
    mutating func findsAreWorthSaying(largest: Int64, now: Date) -> Bool {
        guard largest >= Self.findsMinimum else { return false }
        let since = now.timeIntervalSince(findsSaidAt ?? .distantPast)
        guard since >= Self.week || (since >= Self.day && largest >= findsSaidBytes + Self.findsMinimum) else { return false }
        findsSaidAt = now
        findsSaidBytes = largest
        return true
    }

    static func load(from defaults: UserDefaults) -> Alerts {
        defaults.data(forKey: WatchSettings.stateKey).flatMap { try? JSONDecoder().decode(Alerts.self, from: $0) } ?? Alerts()
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: WatchSettings.stateKey) }
    }
}

/// Processes that have kept a core busy for a long time, decided from
/// readings and the clock they're given: each is named once a day at most.
struct BusyProcesses: Equatable {
    /// Percent of one core.
    static let threshold = 90.0
    static let lasting: TimeInterval = 10 * 60
    /// Busy by design, or not the user's to do anything about.
    static let ignored: Set<String> = ["kernel_task", "MyMole", "WindowServer", "mds_stores", "mdworker_shared", "backupd"]

    /// Readings further apart than this (the Mac slept, the app was in the
    /// background) don't show the process stayed busy between them.
    static let longestGap: TimeInterval = 3 * 60

    struct Run: Equatable {
        let name: String
        let since: Date
    }

    /// When each process, by its process ID, became busy, in an unbroken
    /// run of readings: two apps of one name, or an app started again, are
    /// runs of their own.
    var busySince: [Int32: Run] = [:]
    /// Named at most once a day for each app name.
    var saidAt: [String: Date] = [:]
    var lastReading: Date?

    /// The processes to name now.
    mutating func observe(_ processes: [SystemSnapshot.Process], now: Date) -> [String] {
        if let last = lastReading, now.timeIntervalSince(last) > Self.longestGap { busySince = [:] }
        lastReading = now
        let busy = processes.filter { $0.cpu >= Self.threshold && !Self.ignored.contains($0.name) }
        let byPID = Dictionary(busy.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })
        // Gone, below the mark, or a new process under an old number: the run ends.
        busySince = busySince.filter { byPID[$0.key] == $0.value.name }
        for p in busy where busySince[p.pid] == nil { busySince[p.pid] = Run(name: p.name, since: now) }
        var say: [String] = []
        for run in busySince.values
        where now.timeIntervalSince(run.since) >= Self.lasting && now.timeIntervalSince(saidAt[run.name] ?? .distantPast) >= Alerts.day {
            saidAt[run.name] = now
            if !say.contains(run.name) { say.append(run.name) }
        }
        return say.sorted()
    }
}

/// One notification: what it says and the pane a click on it opens.
struct Alert: Sendable, Equatable {
    enum Kind: String, Sendable { case disk, finds, trashedApp, busy }

    let kind: Kind
    let title: String
    let body: String
    let pane: String
    /// What a click opens besides the pane, if anything.
    var action: String? = nil

    static let paneKey = "pane"
    static let actionKey = "action"
    /// A click opens what removed apps left in the Library.
    static let showOrphans = "orphans"

    static func busy(_ name: String) -> Alert {
        Alert(
            kind: .busy, title: String(localized: "\(name) has kept the processor busy"),
            body: String(localized: "It has used a whole core for \(Int(BusyProcesses.lasting / 60)) minutes or more, and may be stuck. Look at it in Live Status, or quit it if you don't need it."),
            pane: Pane.status.rawValue)
    }

    static func trashed(_ app: String, left bytes: Int64) -> Alert {
        Alert(
            kind: .trashedApp, title: String(localized: "\(app) is in the Trash"),
            body: String(localized: "It left \(ByteSize.format(bytes)) of settings, caches and data in your Library. Click to look at them."),
            pane: Pane.uninstall.rawValue, action: showOrphans)
    }

    static func disk(free: Int64, total: Int64, finds: String?) -> Alert {
        let room = String(localized: "\(ByteSize.format(free)) of \(ByteSize.format(total)) is free.")
        let hint = finds.map { String(localized: "The last scans found: \($0).") } ?? String(localized: "Open MyMole to see what could go.")
        return Alert(kind: .disk, title: String(localized: "Your disk is nearly full"), body: room + " " + hint, pane: Pane.dashboard.rawValue)
    }

    static func finds(_ found: [(pane: Pane, bytes: Int64)]) -> Alert? {
        guard let first = found.first else { return nil }
        return Alert(kind: .finds, title: String(localized: "MyMole found things to clean"), body: summary(found), pane: first.pane.rawValue)
    }

    /// "Projects 48,8 GB · Installers 3,1 GB": each pane by itself. The
    /// panes' findings can overlap, so they're never added up.
    static func summary(_ found: [(pane: Pane, bytes: Int64)]) -> String {
        found.map { "\($0.pane.title) \(ByteSize.format($0.bytes))" }.joined(separator: " · ")
    }
}

/// Posts local notifications. The notification centre needs an app's
/// identity, so outside an app bundle (a test run, `swift run`) nothing is
/// asked and nothing is posted.
struct Notifier: Sendable {
    var authorize: @Sendable () async -> Bool
    var post: @Sendable (Alert) async -> Void

    static let none = Notifier(authorize: { false }, post: { _ in })

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    @MainActor static func notificationsDenied() async -> Bool {
        guard isAvailable else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .denied
    }

    static var live: Notifier {
        guard isAvailable else { return .none }
        return Notifier(
            authorize: { (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false },
            post: { alert in
                let content = UNMutableNotificationContent()
                content.title = alert.title
                content.body = alert.body
                content.userInfo = [Alert.paneKey: alert.pane, Alert.actionKey: alert.action ?? ""]
                // One of each kind at a time: a newer one takes the older one's place.
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.kind.rawValue, content: content, trigger: nil))
            })
    }
}

/// Runs the background scan on its schedule and posts what's worth saying.
@MainActor
final class Watch {
    private let defaults: UserDefaults
    private let notifier: Notifier
    private var scheduler: NSBackgroundActivityScheduler?
    private var scheduled: WatchSettings.Cadence = .off

    init(defaults: UserDefaults = .standard, notifier: Notifier = .live) {
        self.defaults = defaults
        self.notifier = notifier
    }

    /// Asks macOS for permission to notify; false when the user said no.
    func authorize() async -> Bool { await notifier.authorize() }

    func pause() {
        scheduler?.invalidate()
        scheduler = nil
        scheduled = .off
    }

    /// Sets the schedule to the saved cadence. macOS picks the moment
    /// within the interval, when the Mac has power and time to spare, and
    /// remembers the last run across launches.
    func schedule(_ scan: @escaping @MainActor () async -> Void) {
        let cadence = WatchSettings.cadence(in: defaults)
        guard cadence != scheduled else { return }
        scheduled = cadence
        scheduler?.invalidate()
        scheduler = nil
        guard let interval = cadence.interval, let id = Bundle.main.bundleIdentifier else { return }
        let s = NSBackgroundActivityScheduler(identifier: id + ".background-scan")
        s.repeats = true
        s.interval = interval
        s.tolerance = interval / 4
        s.qualityOfService = .utility
        s.schedule { done in
            Task { @MainActor in
                await scan()
                done(.finished)
            }
        }
        scheduler = s
    }

    /// Says the disk is nearly full when it is and that's news.
    func check(_ volume: SystemSnapshot.Volume?, finds: [(pane: Pane, bytes: Int64)], now: Date = Date()) async {
        guard defaults.bool(forKey: WatchSettings.diskKey), let volume else { return }
        var state = Alerts.load(from: defaults)
        let before = state
        let say = state.diskIsLow(free: volume.available, total: volume.total, now: now)
        if state != before { state.save(to: defaults) }
        if say { await notifier.post(.disk(free: volume.available, total: volume.total, finds: finds.isEmpty ? nil : Alert.summary(finds))) }
    }

    var notifiesTrashedApps: Bool { defaults.bool(forKey: WatchSettings.trashedAppsKey) }
    private var busy = BusyProcesses()

    /// Names a process that has kept a core busy for long, when that's turned on.
    func observe(_ processes: [SystemSnapshot.Process], now: Date = Date()) async {
        guard defaults.bool(forKey: WatchSettings.busyKey) else {
            busy = BusyProcesses()
            return
        }
        for name in busy.observe(processes, now: now) { await notifier.post(.busy(name)) }
    }

    /// Says that an app just put in the Trash left things in the Library.
    func trashedApp(_ name: String, left bytes: Int64) async {
        guard notifiesTrashedApps, bytes > 0 else { return }
        await notifier.post(.trashed(name, left: bytes))
    }

    /// Says what a background scan found when it's a lot and that's news.
    func scanned(_ finds: [(pane: Pane, bytes: Int64)], now: Date = Date()) async {
        guard defaults.bool(forKey: WatchSettings.findsKey), let alert = Alert.finds(finds) else { return }
        var state = Alerts.load(from: defaults)
        guard state.findsAreWorthSaying(largest: finds.map(\.bytes).max() ?? 0, now: now) else { return }
        state.save(to: defaults)
        await notifier.post(alert)
    }
}

extension AppModel {
    /// What the last scan of a pane found that could go.
    func found(_ pane: Pane) -> Int64 {
        switch pane {
        case .projects: projects.freeableBytes
        case .installer: installers.totalBytes
        case .clean: deepClean.totalBytes
        case .systemClean: systemClean.totalBytes
        case .duplicates: duplicates.spareBytes
        default: 0
        }
    }

    /// The panes that found something, most first.
    var finds: [(pane: Pane, bytes: Int64)] {
        [Pane.projects, .clean, .installer, .duplicates, .systemClean].filter(\.isAvailable)
            .map { ($0, found($0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }

    /// The longest a background scan is waited for before its findings are read.
    static let backgroundScanLimit: Duration = .seconds(30 * 60)

    /// A scan MyMole starts by itself: only with access, and never beside a
    /// scan, a move to the Trash or an Undo that's already running. Scans
    /// only read; what they find waits for the user.
    func backgroundScan() async {
        guard canScan, !anyScanRunning, !smartScanning, takeBackBlocker == nil, !TrashJobs.shared.isBusy else { return }
        let started = Date()
        scanAll(background: true)
        projects.scan(background: true)
        let deadline = ContinuousClock.now + Self.backgroundScanLimit
        // A scan reports that it started a moment after it's asked for.
        try? await Task.sleep(for: .milliseconds(500))
        while anyScanRunning || smartScanning, ContinuousClock.now < deadline { try? await Task.sleep(for: .seconds(1)) }
        // Only what this run found is news: a pane whose scan was stopped
        // (access taken back, a move began) still shows what it had before.
        guard canScan else { return }
        await watch.scanned(finds(since: started))
    }

    /// The panes whose scan finished at or after `date`, with what they found.
    func finds(since date: Date) -> [(pane: Pane, bytes: Int64)] {
        finds.filter { scannedAt(of: $0.pane).map { $0 >= date } ?? false }
    }

    func scannedAt(of pane: Pane) -> Date? {
        switch pane {
        case .projects: projects.scannedAt
        case .installer: installers.scannedAt
        case .clean: deepClean.scannedAt
        case .systemClean: systemClean.scannedAt
        case .duplicates: duplicates.scannedAt
        default: nil
        }
    }
}

extension AppModel {
    /// Apps that arrived in the Trash since the last look, and what they
    /// left in the Library: an app dragged to the Trash in Finder leaves its
    /// settings, caches and data behind. What lay there at launch is only
    /// noted; nothing is said about it.
    func checkTrashedApps() async {
        guard let listing = trash.listing else { return }
        let names = Set(listing.entries.map(\.name).filter { $0.hasSuffix(".app") })
        let arrived = names.subtracting(trashedAppsSeen ?? names)
        trashedAppsSeen = names
        guard !arrived.isEmpty, watch.notifiesTrashedApps else { return }
        let installed = apps.apps
        let folder = listing.folder
        for name in arrived.sorted() {
            let left = await Task.detached(priority: .utility) { () -> Int64 in
                guard let app = AppFinder.read(folder + "/" + name) else { return 0 }
                return AppLeftovers.find(for: app, installed: installed).reduce(0) { $0 + $1.bytes }
            }.value
            await watch.trashedApp(String(name.dropLast(4)), left: left)
        }
    }
}

