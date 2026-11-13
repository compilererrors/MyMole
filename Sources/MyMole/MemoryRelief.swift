import Dispatch
import Foundation

/// Whether MyMole gives memory back when macOS runs short, chosen in
/// Settings → Performance. Off by default, so nothing is let go unless the
/// user asks for it on a Mac that gets sluggish.
enum MemoryRelief {
    static let defaultsKey = "performance.memoryRelief"

    static func isOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}

/// Tells the app when macOS runs short of memory; what's let go then is
/// up to `MemoryRelief`.
@MainActor
final class MemoryPressureWatch {
    enum Level { case warning, critical }

    private let source: DispatchSourceMemoryPressure

    init(_ handle: @escaping @MainActor (Level) -> Void) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [source] in
            let level: Level = source.data.contains(.critical) ? .critical : .warning
            MainActor.assumeIsolated { handle(level) }
        }
        source.resume()
    }

    deinit { source.cancel() }
}

extension AppModel {
    /// What MyMole lets go of when macOS asks for memory. A warning stops
    /// scans started ahead of need and empties caches that fill again on
    /// demand. Critical pressure also lets go of a finished disk map that
    /// isn't on screen. Nothing the user is looking at, has chosen, is
    /// moving or can still undo is touched.
    func relieveMemory(_ level: MemoryPressureWatch.Level) {
        MemoryRelief.relieve(level, enabled: MemoryRelief.isOn(), storage: storage, projects: projects,
                             diskMapOnScreen: pane == .diskMap)
    }
}

extension MemoryRelief {
    /// Lets go of what `AppModel.relieveMemory` describes, only when the
    /// setting is on; off, a pressure event changes nothing.
    @MainActor static func relieve(_ level: MemoryPressureWatch.Level, enabled: Bool, storage: StorageModel,
                                   projects: ProjectsModel, diskMapOnScreen: Bool) {
        guard enabled else { return }
        storage.relieveMemory(critical: level == .critical, onScreen: diskMapOnScreen)
        projects.relieveMemory()
        AppIcons.release()
        ChartLayouts.removeAll()
    }
}
