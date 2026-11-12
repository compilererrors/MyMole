import AppKit
import Testing

@testable import MyMole

@MainActor @Suite struct FileNameCellTests {
    @Test func cachedTextAdaptsToWidthsSubtitlesAndReusedNames() throws {
        let cell = FileNameCell(identifier: .init("synthetic-layout"))
        var row = FileRow(id: "/synthetic/item", name: "aVeryLongUnbrokenSyntheticComponent followed by readable parts.data", size: 1_024)
        cell.configure(row, marked: nil) {}
        let label = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first)
        for width: CGFloat in [130, 600, 130, 600] {
            cell.setFrameSize(NSSize(width: width, height: 40))
            cell.layoutSubtreeIfNeeded()
            #expect(label.maximumNumberOfLines == (width < 200 ? 1 : 2))
            #expect(cell.bounds.contains(label.frame))
        }
        row.subtitle = "Synthetic subtitle"
        cell.configure(row, marked: nil) {}
        cell.layoutSubtreeIfNeeded()
        #expect(label.maximumNumberOfLines == 1 && label.stringValue == row.name)
        row.name = "Different synthetic name"
        row.subtitle = nil
        cell.configure(row, marked: nil) {}
        cell.layoutSubtreeIfNeeded()
        #expect(label.stringValue == Breakable.text(row.name))
        #expect(label.maximumNumberOfLines == 2)
    }

    @Test func finishingAReadOnlyPreviewRevealsTheCurrentChoice() throws {
        let cell = FileNameCell(identifier: .init("synthetic-preview"))
        cell.frame = NSRect(x: 0, y: 0, width: 400, height: 44)
        var row = FileRow(id: "/synthetic/example.dat", name: "Example.dat", size: 1_024)
        row.canChoose = false
        cell.configure(row, marked: nil) {}
        let check = try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
        #expect(check.isHidden && !check.isEnabled)
        row.canChoose = true
        cell.configure(row, marked: nil) {}
        cell.setMarked(true)
        cell.layoutSubtreeIfNeeded()
        #expect(!check.isHidden && check.isEnabled && check.state == .on)
        #expect(check.frame.width == 18 && cell.bounds.contains(check.frame))
        cell.setMarked(false)
        #expect(!check.isHidden && check.state == .off)
    }

    @Test func returningToReadOnlyHidesTheChoiceAndRemovesItsLayoutSpace() throws {
        let cell = FileNameCell(identifier: .init("synthetic-read-only"))
        cell.frame = NSRect(x: 0, y: 0, width: 400, height: 44)
        cell.configure(FileRow(id: "/synthetic/example.dat", name: "Example.dat", size: 1_024), marked: true) {}
        cell.layoutSubtreeIfNeeded()
        let check = try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
        let icon = try #require(cell.subviews.compactMap { $0 as? NSImageView }.first)
        let chosenInset = icon.frame.minX
        cell.setMarked(nil)
        cell.layoutSubtreeIfNeeded()
        #expect(check.isHidden && check.state == .off)
        #expect(icon.frame.minX < chosenInset)
    }
}
