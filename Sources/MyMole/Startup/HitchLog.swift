#if SMOKE
import Foundation
import StorageKit

/// The UI smoke build's record of every time the main thread was held up
/// for longer than a frame, for the resize checks in scripts/ui-smoke.sh.
/// A timer on the main queue ticks every 2 ms; a tick that arrives late
/// means the main thread was busy for that long, whatever kept it busy.
/// Each such stall is appended to `hitches.log` in the run folder as
/// "<wall-clock ms> <stall ms>". Only the smoke build has it.
@MainActor
enum HitchLog {
    private static var timer: DispatchSourceTimer?

    static func start() {
        guard timer == nil, let run = try? SyntheticRun.current() else { return }
        let url = URL(fileURLWithPath: run.root).appending(path: "hitches.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let out = FileHandle(forWritingAtPath: url.path) else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        var last = DispatchTime.now().uptimeNanoseconds
        source.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(200))
        source.setEventHandler {
            let now = DispatchTime.now().uptimeNanoseconds
            let late = Double(now - last) / 1_000_000 - 2
            last = now
            guard late > 12 else { return }
            let line = String(format: "%.0f %.1f\n", Date().timeIntervalSince1970 * 1_000, late)
            out.write(Data(line.utf8))
        }
        source.resume()
        timer = source
    }
}
#endif
