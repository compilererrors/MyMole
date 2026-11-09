import Foundation

/// Start cheap checks and metadata first. Content comparison follows the
/// cleanup walks, so hashing doesn't delay their first results.
@MainActor
struct SmartScanPipeline {
    struct Job {
        let start: () -> Void
        let wait: () async -> Void
    }

    let jobs: [Pane: Job]

    static func modules(system: Bool) -> [Pane] {
        [.clean, .installer, .duplicates, .uninstall, .optimize] + (system ? [.systemClean] : [])
    }

    func run(together: Bool, allowed: () -> Bool, starting: (Pane) -> Void = { _ in }) async {
        guard allowed(), !Task.isCancelled else { return }
        func start(_ pane: Pane) {
            guard allowed(), !Task.isCancelled, let job = jobs[pane] else { return }
            starting(pane)
            job.start()
        }
        func wait(_ pane: Pane) async { await jobs[pane]?.wait() }
        start(.optimize)
        start(.uninstall)
        start(.systemClean)
        if together {
            start(.installer)
            start(.clean)
            await wait(.installer)
            await wait(.clean)
        } else {
            await wait(.uninstall)
            await wait(.systemClean)
            for pane in [Pane.installer, .clean] {
                guard allowed(), !Task.isCancelled else { return }
                start(pane)
                await wait(pane)
            }
        }
        await wait(.uninstall)
        await wait(.systemClean)
        guard allowed(), !Task.isCancelled else { return }
        start(.duplicates)
        await wait(.duplicates)
        await wait(.optimize)
    }
}
