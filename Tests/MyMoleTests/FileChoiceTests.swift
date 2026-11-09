import AppKit
import Testing
@testable import MyMole

@MainActor @Suite struct FileChoiceTests {
    @Test func requestingReviewDoesNotShowAnUnapprovedCheckboxAsSelected() throws {
        let cell = FileNameCell(identifier: .init("synthetic-review"))
        var calls = 0
        var row = FileRow(id: "/synthetic/review", name: "Uncertain match", size: 100, canChoose: true, reviewBeforeChoosing: true)
        cell.configure(row, marked: false) { calls += 1 }
        let checkbox = try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
        checkbox.performClick(nil)
        #expect(calls == 1 && checkbox.state == .off)
        row.reviewBeforeChoosing = false
        cell.configure(row, marked: true) { calls += 1 }
        #expect(checkbox.state == .on)
        checkbox.performClick(nil)
        #expect(calls == 2 && checkbox.state == .off)
    }
    @Test func protectedAndRequiredChoicesIgnoreClicksAndReuseRemainsEditable() throws {
        let cell = FileNameCell(identifier: .init("synthetic-choice"))
        var calls = 0
        var row = FileRow(id: "/synthetic/item", name: "Example item", size: 1024, canChoose: false, choiceHelp: "Required in this review")
        cell.configure(row, marked: true) { calls += 1 }
        let checkbox = try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
        cell.setChoosingEnabled(true)
        checkbox.performClick(nil)
        #expect(!checkbox.isEnabled && checkbox.state == .on && calls == 0)
        #expect(checkbox.toolTip == "Required in this review")

        row.canChoose = true
        row.size = nil
        cell.configure(row, marked: false, dimUnmeasured: false) { calls += 1 }
        cell.setChoosingEnabled(true)
        checkbox.performClick(nil)
        #expect(!checkbox.isEnabled && calls == 0)

        row.size = 1024
        cell.configure(row, marked: false) { calls += 1 }
        checkbox.performClick(nil)
        #expect(checkbox.isEnabled && checkbox.state == .on && calls == 1)
    }
}
