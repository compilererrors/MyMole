import Foundation
import Testing

@testable import MyMole

/// Phrases of the interface and the string catalog they're collected in.
@MainActor
@Suite struct PhraseTests {
    @Test func aPhraseReadsAsWrittenInEnglishAndAValueAsItIs() {
        #expect(Phrase("Move to Trash").string == "Move to Trash")
        let n = 3
        #expect(Phrase("\(n) apps").string == "3 apps")
        // A file named like a phrase is still shown as it is.
        #expect(Phrase(verbatim: "Settings").string == "Settings")
        #expect(Phrase(verbatim: "%@ 100%").string == "%@ 100%")
    }

    @Test func paneNamesAndNoticesComeFromTheCatalogAPI() {
        // Built with String(localized:), they read as written in English.
        #expect(Pane.clean.title == "Deep Clean")
        #expect(ModuleState.partial.text == "partly read")
    }

    /// The catalog in the repository: English source, and every phrase the
    /// panes and notices use is in it. scripts/sync-strings.sh keeps it in
    /// step with the code; CI checks that.
    @Test func theCatalogHoldsThePhrasesOfThePanes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Localization/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["sourceLanguage"] as? String == "en")
        let strings = try #require(catalog["strings"] as? [String: Any])
        for pane in Pane.allCases { #expect(strings[pane.title] != nil, "\(pane.title)") }
        for key in ["Move to Trash", "Moved %@ to the Trash", "Restored %lld; %lld couldn't be put back. Undo tries those again.",
                    "Wait for the scan to finish.", "Copy Error Code",
                    // Captions of the design components, and text built outside a view.
                    "found in %@ items", "kept", "Go to %@", "%@ is open. Quit it first.", "%lld of %lld put back"] {
            #expect(strings[key] != nil, "\(key)")
        }
        let stale = strings.filter { ($0.value as? [String: Any])?["extractionState"] as? String == "stale" }
        #expect(stale.isEmpty, "\(stale.keys.sorted())")
    }
}
