import Foundation
import Testing

@testable import MyMole

@Suite struct DiskMapSkipsTests {
    private func defaults() -> UserDefaults {
        testDefaults(in: FileManager.default.temporaryDirectory.appending(path: "skips-\(UUID().uuidString)"))
    }

    @Test func skipsAreKeptOnceAndFoundUnderTheMappedFolder() {
        let d = defaults()
        DiskMapSkips.add("/synthetic/home/Movies", in: d)
        DiskMapSkips.add("/synthetic/home/Movies", in: d)
        DiskMapSkips.add("/synthetic/other", in: d)
        #expect(DiskMapSkips.paths(in: d) == ["/synthetic/home/Movies", "/synthetic/other"])
        let under = DiskMapSkips.under("/synthetic/home", in: d)
        #expect(under.full == ["/synthetic/home/Movies"] && under.relative == ["Movies"])
        DiskMapSkips.remove("/synthetic/home/Movies", in: d)
        #expect(DiskMapSkips.under("/synthetic/home", in: d).full.isEmpty)
    }

    @Test func aSavedFilterIsNamedByWhatItFilters() throws {
        var f = BrowseFilter()
        f.query = "invoice"
        f.kind = .documents
        #expect(SavedFilter.name(for: f).hasPrefix("“invoice” · "))
        let d = defaults()
        SavedFilter.save([SavedFilter(name: "x", filter: f)], in: d)
        #expect(SavedFilter.all(in: d).first?.filter == f)
    }
}
