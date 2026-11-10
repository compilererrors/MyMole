import AppKit

/// Bulk choices refer to the displayed list, independently of highlighted rows.
struct ListedChoices: Sendable {
    enum State { case off, mixed, on }
    let checkable: Set<String>
    let clearable: Set<String>

    nonisolated init(_ rows: [FileRow]) {
        let editable = rows.filter { $0.size != nil && $0.canChoose }
        checkable = Set(editable.filter { $0.bulkCheckable && !$0.reviewBeforeChoosing }.map(\.id))
        clearable = Set(editable.map(\.id))
    }

    nonisolated func state(_ marks: Set<String>) -> State {
        if !checkable.isEmpty, checkable.isSubset(of: marks) { return .on }
        return clearable.isDisjoint(with: marks) ? .off : .mixed
    }
}

/// A native checkbox stays beside Name while columns scroll, resize or move.
final class TableChoiceHeader: NSTableHeaderView {
    let check = HeaderCheckbox(checkboxWithTitle: "", target: nil, action: nil)
    private var onChange: (() -> Void)?
    private var displayedState: NSControl.StateValue = .off

    override init(frame: NSRect) {
        super.init(frame: frame)
        check.controlSize = .small
        check.allowsMixedState = true
        check.target = self
        check.action = #selector(toggled)
        check.isHidden = true
        check.setAccessibilityIdentifier("table.checkAllListed")
        addSubview(check)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func install(on table: NSTableView) {
        let header = TableChoiceHeader(frame: table.headerView?.frame ?? NSRect(x: 0, y: 0, width: 0, height: 24))
        table.headerView = header
        if let column = table.tableColumns.first(where: { $0.identifier.rawValue == FileColumn.name.rawValue }) {
            column.headerCell = ChoiceNameHeaderCell(textCell: column.title)
        }
    }

    func update(state: ListedChoices.State, visible: Bool, enabled: Bool, help: String?, action: @escaping () -> Void) {
        check.isHidden = !visible
        check.isEnabled = enabled
        check.state = switch state { case .off: .off; case .mixed: .mixed; case .on: .on }
        displayedState = check.state
        check.setAccessibilityLabel(state == .on ? String(localized: "Uncheck All Listed") : String(localized: "Check All Listed"))
        check.toolTip = help ?? String(localized: "Check or uncheck eligible items in this list, including rows below the screen. Filters limit this choice. Highlighting rows is separate; nothing is removed here.")
        onChange = action
        if let cell = tableView?.tableColumns.first(where: { $0.identifier.rawValue == FileColumn.name.rawValue })?.headerCell as? ChoiceNameHeaderCell {
            cell.showsCheck = visible
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        positionCheck()
    }

    override func accessibilityChildren() -> [Any]? {
        var result = super.accessibilityChildren() ?? []
        if !check.isHidden, !result.contains(where: { ($0 as? NSView) === check }) { result.append(check) }
        return result
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        let target: HeaderCheckbox? = MainActor.assumeIsolated {
            !check.isHidden && check.accessibilityFrame().contains(point) ? check : nil
        }
        if let target { return target }
        return super.accessibilityHitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        positionCheck()
        super.draw(dirtyRect)
    }

    private func positionCheck() {
        guard let tableView else { return }
        let column = tableView.column(withIdentifier: .init(FileColumn.name.rawValue))
        guard column >= 0, !tableView.tableColumns[column].isHidden else { check.frame = .zero; return }
        let rect = headerRect(ofColumn: column)
        check.frame = NSRect(x: rect.minX + DS.Table.cellInset, y: rect.midY - 9, width: 18, height: 18)
    }

    @objc private func toggled() {
        check.state = displayedState
        onChange?()
    }
}

final class HeaderCheckbox: NSButton {
    override func accessibilityFrame() -> NSRect {
        MainActor.assumeIsolated { NSAccessibility.screenRect(fromView: self, rect: bounds) }
    }
}

private final class ChoiceNameHeaderCell: NSTableHeaderCell {
    var showsCheck = false
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var frame = cellFrame
        if showsCheck { frame.origin.x += DS.Table.tickStep; frame.size.width -= DS.Table.tickStep }
        super.drawInterior(withFrame: frame, in: controlView)
    }
}
