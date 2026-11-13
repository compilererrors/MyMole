#if SMOKE
import AppKit
import StorageKit

/// The UI smoke build's resize check (`scripts/ui-smoke.sh --resize-only`):
/// the whole app, launched on a synthetic home, resizes its own window and
/// drags its sidebar divider a frame at a time in each pane, while launch's
/// scans run as they would for a user. Each step's own main-thread time and
/// every stall `HitchLog` saw during the sweep go to `resize-report.txt` in
/// the run folder; then the app quits. No pointer or Accessibility access is
/// needed, so nothing else on the screen is touched.
@MainActor
enum ResizeExercise {
    static let environment = ProcessInfo.processInfo.environment
    /// One pane, for a long sweep to sample (MYMOLE_SMOKE_RESIZE_PANE), or all of them.
    static let panes: [Pane] = environment["MYMOLE_SMOKE_RESIZE_PANE"].flatMap(Pane.init(rawValue:)).map { [$0] }
        ?? [.dashboard, .diskMap, .projects, .status, .uninstall, .clean, .duplicates]
    static let steps = environment["MYMOLE_SMOKE_RESIZE_STEPS"].flatMap(Int.init) ?? 180

    static func runIfAsked(_ app: AppModel) {
        guard ProcessInfo.processInfo.environment["MYMOLE_SMOKE_RESIZE"] == "1", let run = try? SyntheticRun.current() else { return }
        Task { @MainActor in
            // Launch's own work is under way, as a user meets it.
            try? await Task.sleep(for: .seconds(4))
            let report = URL(fileURLWithPath: run.root).appending(path: "resize-report.txt")
            var lines: [String] = [] {
                // Written after every sweep, so a run that stalls still says how far it got.
                didSet { try? (lines.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8) }
            }
            lines.append("resize started with \(mainWindow().map { "window \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "no window")")
            for pane in panes where pane.isAvailable {
                app.pane = pane
                try? await Task.sleep(for: .seconds(2))
                guard let window = mainWindow() else { lines.append("resize \(pane.rawValue) no-window"); continue }
                // Whose toolbar the window has, and what is on it.
                let toggles = NSApp.target(forAction: #selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil).map { "\(type(of: $0))" } ?? "none"
                let all = views(NSView.self, in: window.contentView)
                lines.append("views \(pane.rawValue) all=\(all.count) hosting=\(all.filter { String(describing: type(of: $0)).hasPrefix("NSHostingView") }.count) tables=\(all.filter { $0 is NSTableView }.count) splits=\(all.filter { $0 is NSSplitView }.count)")
                lines.append("toolbar \(pane.rawValue) \(window.toolbar?.identifier ?? "none") sidebar-button-target=\(toggles) items="
                             + (window.toolbar?.items.map { $0.label.isEmpty ? $0.itemIdentifier.rawValue : $0.label } ?? []).joined(separator: "|"))
                let origin = window.frame.origin
                lines.append(await sweep("\(pane.rawValue) window", run: run) { step in
                    let width = 1_100 + Double(step % 60) * 6
                    window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: 820)), display: true)
                })
                if environment["MYMOLE_SMOKE_RESIZE_PROBE"] == "1" {
                    // Attribution: the same sweep where no toolbar item overflows, and with no toolbar.
                    lines.append(await sweep("\(pane.rawValue) window-wide", run: run) { step in
                        window.setFrame(NSRect(origin: origin, size: NSSize(width: 1_900 + Double(step % 60) * 6, height: 820)), display: true)
                    })
                    window.toolbar?.isVisible = false
                    lines.append(await sweep("\(pane.rawValue) window-no-toolbar", run: run) { step in
                        window.setFrame(NSRect(origin: origin, size: NSSize(width: 1_100 + Double(step % 60) * 6, height: 820)), display: true)
                    })
                    window.toolbar?.isVisible = true
                }
                window.setFrame(NSRect(origin: origin, size: NSSize(width: 1_300, height: 820)), display: true)
                if pane == .diskMap, let handle = views(HorizontalDragHandleView.self, in: window.contentView)
                    .first(where: { $0.accessibilityIdentifier() == "storage.list-width" }) {
                    // Dragging the divider before the folder list: the pointer's
                    // offset from where the drag began, a frame at a time.
                    lines.append(await sweep("diskMap folder-list", run: run) { step in
                        handle.onChange(CGSize(width: -Double(step % 60) * 5, height: 0))
                    })
                    handle.onCancel()
                }
                // The sidebar first, then every right-hand panel the pane has (Projects' inspector).
                let splits = allSplits(in: window.contentView)
                if splits.isEmpty { lines.append("resize \(pane.rawValue) no-split-view") }
                for (i, split) in splits.enumerated() {
                    let name = i == 0 ? "sidebar" : "right-panel-\(i)"
                    let start = split.subviews.first?.frame.width ?? 220
                    lines.append(await sweep("\(pane.rawValue) \(name)", run: run) { step in
                        let position = i == 0 ? 190 + CGFloat(step % 60) * 2 : split.bounds.width - (340 + CGFloat(step % 60) * 3)
                        split.setPosition(position, ofDividerAt: 0)
                        split.layoutSubtreeIfNeeded()
                    })
                    split.setPosition(start, ofDividerAt: 0)
                }
                // The same dividers dragged with the pointer, through AppKit's
                // own tracking: a drag event every frame, as a hand gives them.
                if pane == .diskMap, let handle = views(HorizontalDragHandleView.self, in: window.contentView)
                    .first(where: { $0.accessibilityIdentifier() == "storage.list-width" }) {
                    lines.append(await pointerDrag("diskMap drag-folder-list", run: run, in: window,
                                                   at: handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)) {
                        handle.superview.map { "\(Int($0.bounds.width - handle.frame.maxX))" } ?? "-"
                    })
                }
                for (i, split) in allSplits(in: window.contentView).enumerated() {
                    guard let first = split.arrangedSubviews.first ?? split.subviews.first else { continue }
                    let divider = NSPoint(x: first.frame.maxX + split.dividerThickness / 2, y: split.bounds.midY)
                    lines.append(await pointerDrag("\(pane.rawValue) drag-\(i == 0 ? "sidebar" : "right-panel-\(i)")", run: run, in: window,
                                                   at: split.convert(divider, to: nil), leftward: i > 0) {
                        "\(Int((split.arrangedSubviews.last ?? split.subviews.last)?.frame.width ?? 0))"
                    })
                }
            }
            lines.append("resize done")
            NSApp.terminate(nil)
        }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil && $0.frame.width > 400 }
    }

    private static func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// Every split view in the window, outermost first.
    private static func allSplits(in view: NSView?) -> [NSSplitView] {
        guard let view else { return [] }
        var found: [NSSplitView] = []
        if let split = view as? NSSplitView, split.arrangedSubviews.count >= 2 || split.subviews.count >= 2 { found.append(split) }
        for child in view.subviews { found += allSplits(in: child) }
        return found
    }

    /// A press on `point` (window coordinates), then a drag event every
    /// 16 ms moving up to 150 points and back, then the release, all from a
    /// main-queue timer while AppKit tracks the drag. How late each event
    /// came is the time the main thread was busy with the one before: the
    /// frame pacing a hand would see. `width` says how wide the panel ended
    /// up halfway, to show the drag moved it.
    private static func pointerDrag(_ name: String, run: SyntheticRun, in window: NSWindow, at point: NSPoint,
                                    leftward: Bool = false, width: @escaping @MainActor () -> String) async -> String {
        try? name.write(toFile: run.root + "/sweeping.txt", atomically: true, encoding: .utf8)
        let started = Date().timeIntervalSince1970 * 1_000
        let drag = PointerDrag(window: window, point: point, steps: steps, leftward: leftward, width: width)
        drag.start()
        // The press returns when the release has been tracked.
        while !drag.done { try? await Task.sleep(for: .milliseconds(16)) }
        let ended = Date().timeIntervalSince1970 * 1_000
        try? await Task.sleep(for: .milliseconds(300))
        let stalls = hitches(run: run, from: started, to: ended + 250)
        let sorted = drag.gaps.sorted()
        func pct(_ f: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * f))] }
        return String(format: "resize %@ events=%d gap_p50=%.1fms gap_p95=%.1fms gap_max=%.1fms stalls_over_16ms=%d worst_stall=%.1fms panel_width_halfway=%@",
                      name, sorted.count, pct(0.5), pct(0.95), sorted.last ?? 0, stalls.filter { $0 > 16.7 }.count, stalls.max() ?? 0, drag.halfway)
    }

    /// One step a frame: the change, then the layout and drawing it needs
    /// now, timed; the stalls in between come from `HitchLog`.
    private static func sweep(_ name: String, run: SyntheticRun, _ apply: (Int) -> Void) async -> String {
        var samples: [Double] = []
        let before = UserDefaults.standard.dictionaryRepresentation()
        nonisolated(unsafe) var notes = 0
        nonisolated(unsafe) var poster = ""
        let token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
            notes += 1
            if poster.isEmpty { poster = Thread.callStackSymbols.dropFirst(2).prefix(14).map { $0.split(separator: " ", maxSplits: 3).last.map(String.init) ?? "" }.joined(separator: " <- ") }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        // Names the sweep under way, for a profiler the script starts on it.
        try? name.write(toFile: run.root + "/sweeping.txt", atomically: true, encoding: .utf8)
        let started = Date().timeIntervalSince1970 * 1_000
        var cpu: [Double] = []
        var mismatches = 0
        func threadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000 }
        for step in 0..<steps {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let c0 = threadCPU()
            apply(step)
            mainWindow()?.contentView?.layoutSubtreeIfNeeded()
            mainWindow()?.displayIfNeeded()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            // The panes follow the window: their split spans its content.
            if let window = mainWindow(), let split = allSplits(in: window.contentView).first,
               abs(split.frame.width - window.contentLayoutRect.width) > 1 && abs(split.frame.width - window.frame.width) > 1 {
                mismatches += 1
            }
            // The main thread's own time: less than the step when it waited for a core.
            cpu.append(threadCPU() - c0)
            try? await Task.sleep(for: .milliseconds(16))
        }
        let ended = Date().timeIntervalSince1970 * 1_000
        // Any setting written while resizing wakes every `@AppStorage` in the app.
        let written = UserDefaults.standard.dictionaryRepresentation().filter { key, value in
            (before[key] as? NSObject) != (value as? NSObject)
        }.keys.sorted()
        // Let the last stalls reach the log.
        try? await Task.sleep(for: .milliseconds(300))
        let stalls = hitches(run: run, from: started, to: ended + 250)
        // When the longest stall came: in the first steps, in the middle, or after the sweep.
        let worstAt = stallTimes(run: run, from: started, to: ended + 250).max { $0.1 < $1.1 }
            .map { at, _ in String(format: "%.0f%%", (at - started) / max(1, ended - started) * 100) } ?? "-"
        let sorted = samples.sorted()
        func pct(_ f: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * f))] }
        return String(format: "resize %@ steps=%d step_p50=%.1fms step_p95=%.1fms step_max=%.1fms stalls_over_16ms=%d worst_stall=%.1fms stall_total=%.0fms settings_written=%@",
                      name, samples.count, pct(0.5), pct(0.95), sorted.last ?? 0,
                      stalls.filter { $0 > 16.7 }.count, stalls.max() ?? 0, stalls.reduce(0, +),
                      written.isEmpty ? "none" : written.joined(separator: ","))
            + String(format: " cpu_p50=%.1fms cpu_p95=%.1fms", cpu.sorted()[cpu.count / 2], cpu.sorted()[min(cpu.count - 1, cpu.count * 95 / 100)])
            + " defaults_notes=\(notes) frame_mismatches=\(mismatches) worst_stall_at=\(worstAt)" + (poster.isEmpty ? "" : " first_poster=" + poster)
    }

    private static func stallTimes(run: SyntheticRun, from: Double, to: Double) -> [(Double, Double)] {
        let text = (try? String(contentsOfFile: run.root + "/hitches.log", encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 2, let at = Double(parts[0]), let ms = Double(parts[1]), at >= from, at <= to else { return nil }
            return (at, ms)
        }
    }

    private static func hitches(run: SyntheticRun, from: Double, to: Double) -> [Double] {
        let text = (try? String(contentsOfFile: run.root + "/hitches.log", encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 2, let at = Double(parts[0]), let ms = Double(parts[1]), at >= from, at <= to else { return nil }
            return ms
        }
    }
}


/// A press, a drag event every 16 ms and a release, posted by a run-loop
/// timer and started from a run-loop block rather than the main queue:
/// AppKit tracks the drag in a run loop of its own, which can't take the
/// main queue's work while one of its blocks is still running.
@MainActor
private final class PointerDrag: NSObject {
    let window: NSWindow
    let point: NSPoint
    let steps: Int
    let leftward: Bool
    let width: @MainActor () -> String
    private(set) var gaps: [Double] = []
    private(set) var halfway = "-"
    private(set) var done = false
    private var step = 0
    private var last = DispatchTime.now().uptimeNanoseconds
    private var timer: Timer?

    init(window: NSWindow, point: NSPoint, steps: Int, leftward: Bool, width: @escaping @MainActor () -> String) {
        self.window = window
        self.point = point
        self.steps = steps
        self.leftward = leftward
        self.width = width
    }

    func start() {
        let timer = Timer(timeInterval: 0.016, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.perform(inModes: [.common]) { [self] in
            MainActor.assumeIsolated { if let down = event(.leftMouseDown, point, 0) { window.sendEvent(down) } }
        }
    }

    private func event(_ type: NSEvent.EventType, _ at: NSPoint, _ number: Int) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1,
                           pressure: type == .leftMouseUp ? 0 : 1)
    }

    @objc private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        if step > 0 { gaps.append(Double(now - last) / 1_000_000) }
        last = now
        step += 1
        if step == steps / 2 { halfway = width() }
        if step >= steps {
            if let up = event(.leftMouseUp, point, step) { NSApp.postEvent(up, atStart: false) }
            timer?.invalidate()
            done = true
            return
        }
        let phase = Double(step % 60) / 60
        let dx = (phase < 0.5 ? phase : 1 - phase) * 300 * (leftward ? -1 : 1)
        if let drag = event(.leftMouseDragged, NSPoint(x: point.x + dx, y: point.y), step) { NSApp.postEvent(drag, atStart: false) }
    }
}
#endif
