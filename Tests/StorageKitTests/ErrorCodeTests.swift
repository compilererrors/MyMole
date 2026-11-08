import Foundation
import Testing

@testable import StorageKit

@Suite struct ErrorCodeTests {
    enum Synthetic: Error { case first, second(String) }

    struct Detailed: LocalizedError, CustomNSError {
        static let errorDomain = "com.vendor/Users/synthetic/Library"
        var errorCode: Int { 7 }
        var errorUserInfo: [String: Any] { [NSFilePathErrorKey: "/Users/synthetic/secret"] }
        var errorDescription: String? { "A file at /Users/synthetic/secret" }
    }

    @Test func aCodeHoldsTheAreaAndTheErrorsNumbersOnly() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 13, userInfo: [NSFilePathErrorKey: "/Users/synthetic/x"])
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [NSUnderlyingErrorKey: posix])
        #expect(ErrorCode(.keepList, cocoa).description == "MM-KEEP-C513.P13")
        #expect(ErrorCode(.systemClean, NSError(domain: NSOSStatusErrorDomain, code: -60006)).description == "MM-SYS-S-60006")
        #expect(ErrorCode(.uninstall, Synthetic.second("/Users/synthetic")).description.hasPrefix("MM-UNINST-"))
        #expect(ErrorCode(.uninstall, Synthetic.first) != ErrorCode(.uninstall, Synthetic.second("x")))
        // MyMole's own error types are named; their numbers are the case.
        #expect(ErrorCode(.keepList, FileLock.Failure.busy).description == "MM-KEEP-FileLockFailure1")
        #expect(ErrorCode.domain("StorageKit.FileLock.Failure") == "FileLockFailure")
        // A type at the top of its module goes by its own name, not the module's.
        #expect(ErrorCode.domain("MyMole.PrivilegedClientFailure") == "PrivilegedClientFailure")
    }

    @Test func nothingFromTheMessageOrDetailsGetsIn() {
        let code = ErrorCode(.projectRules, Detailed()).description
        #expect(!code.contains("synthetic") && !code.contains("Users") && !code.contains("/") && !code.contains(" "))
        #expect(code == ErrorCode(.projectRules, Detailed()).description)
        #expect(ErrorCode.domain("com.vendor.Thing").hasPrefix("X"))
        #expect(code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-.".contains($0)) })
    }

    @Test func underlyingErrorsStopAtThree() {
        var e = NSError(domain: NSPOSIXErrorDomain, code: 1)
        for i in 2...6 { e = NSError(domain: NSPOSIXErrorDomain, code: i, userInfo: [NSUnderlyingErrorKey: e]) }
        #expect(ErrorCode(.maintenance, e).reason == "P6.P5.P4")
    }
}
