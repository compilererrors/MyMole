import Foundation
import StorageKit
import Testing

@Suite struct LoadingSettingsTests {
    private let dir = FileManager.default.temporaryDirectory.appending(path: "loading-\(UUID().uuidString)")

    @Test func panesAreReadiedAtLaunchUnlessTurnedOff() {
        let d = testDefaults(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LoadingSettings.prefetch(in: d))
        d.set(false, forKey: LoadingSettings.prefetchKey)
        #expect(!LoadingSettings.prefetch(in: d))
    }

    @Test func theHistoryLengthStaysInItsRange() {
        let d = testDefaults(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LoadingSettings.history(in: d) == LoadingSettings.historyStandard)
        d.set(1, forKey: LoadingSettings.historyKey)
        #expect(LoadingSettings.history(in: d) == LoadingSettings.historyRange.lowerBound)
        d.set(10_000, forKey: LoadingSettings.historyKey)
        #expect(LoadingSettings.history(in: d) == LoadingSettings.historyRange.upperBound)
        d.set(45, forKey: LoadingSettings.historyKey)
        #expect(LoadingSettings.history(in: d) == 45)
    }
}
