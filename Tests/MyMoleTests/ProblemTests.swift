import Foundation
import StorageKit
import Testing

@testable import MyMole

@MainActor @Suite struct ProblemTests {
    @Test func aProblemFromAnErrorCarriesItsCode() {
        let error = NSError(
            domain: NSCocoaErrorDomain, code: 260, userInfo: [NSFilePathErrorKey: "/Users/synthetic/Library/keep.json"])
        let problem = Problem(.keepList, error)
        #expect(problem.code?.description == "MM-KEEP-C260")
        #expect(problem.description.hasSuffix("Error code MM-KEEP-C260."))
        #expect(Problem("Wait for it.").code == nil && Problem("Wait for it.").description == "Wait for it.")
    }

    @Test func theCopiedReportHoldsOnlyTheCodeVersionAndSystem() {
        let code = ErrorCode(.systemClean, NSError(domain: NSPOSIXErrorDomain, code: 1, userInfo: [NSFilePathErrorKey: "/Users/synthetic"]))
        let report = CopyErrorCodeButton.report(code, info: ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "7"], edition: .appStore)
        #expect(report.hasPrefix("MM-SYS-P1 · MyMole 1.0 (7), App Store edition, macOS "))
        #expect(!report.contains("synthetic") && !report.contains("/"))
        #expect(CopyErrorCodeButton.report(code, info: nil, edition: .direct).contains("MyMole development build, direct edition"))
    }
}

@Suite struct LinksTests {
    /// The website and support open as they are, over HTTPS, and carry
    /// nothing of the user's: no query, no error code.
    @Test func theLinksAreFixedHTTPSAddresses() {
        #expect(Links.website.absoluteString == "https://mymole.viktornyberg.com")
        #expect(Links.support.absoluteString == "https://viktornyberg.com/#support")
        for url in [Links.website, Links.support] {
            #expect(url.scheme == "https" && url.query == nil && url.user == nil)
        }
    }
}

@MainActor @Suite struct IncompleteEmptyTests {
    @Test func anEmptyIncompleteResultNamesWhatCouldntBeRead() {
        let text = DSIncompleteEmpty.explanation(["/Users/synthetic/Downloads", "/Applications"])
        #expect(text.contains("/Applications") && text.contains("may not be everything"))
        let many = DSIncompleteEmpty.explanation((1...5).map { "/Volumes/Synthetic\($0)" })
        #expect(many.contains("and 2 more") && !many.contains("Synthetic4"))
    }
}
