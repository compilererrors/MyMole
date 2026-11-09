import Testing

@testable import MyMole

@Suite struct SettingsSearchTests {
    private func find(_ query: String, sandboxed: Bool = false) -> [SettingsSection] {
        SettingsSection.matching(query, sandboxed: sandboxed, systemTasks: !sandboxed)
    }

    @Test func findsControlsByTheirWordsAndPurpose() {
        #expect(find("dark theme") == [.appearance])
        #expect(find("ask again").contains(.confirmations))
        #expect(find("Open at login").contains(.menuBar))
        #expect(find("Open at login").contains(.uninstall) == false)
        #expect(find("uninstall MyMole") == [.uninstall])
        #expect(find("prefetch cache").contains(.loading))
        #expect(find("Show menu bar").contains(.menuBar))
        #expect(find("Notify me when the disk is nearly full").contains(.background))
        #expect(find("Installers").contains(.confirmations))
        #expect(find("App Management").contains(.appManagement))
        #expect(find("cannot move Trash").contains(.appManagement))
        #expect(find("unfindable-synthetic-setting").isEmpty)
    }

    @Test func editionSpecificSettingsStayOutOfSearchResults() {
        let direct = find("")
        #expect(direct.contains(.systemTasks) && direct.contains(.systemKeep))
        #expect(!direct.contains(.folderAccess))
        let sandboxed = find("", sandboxed: true)
        #expect(sandboxed.contains(.folderAccess))
        #expect(!sandboxed.contains(.systemTasks) && !sandboxed.contains(.systemKeep))
        #expect(sandboxed.contains(.uninstall) && sandboxed.contains(.confirmations))
    }

    @Test func commandsCanFocusEveryExistingSearchIncludingSettings() {
        for pane in [Pane.settings, .diskMap, .duplicates, .projects, .startup] { #expect(pane.hasSearch) }
        #expect(!Pane.history.hasSearch)
    }
}
