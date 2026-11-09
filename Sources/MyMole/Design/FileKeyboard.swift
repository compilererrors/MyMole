import AppKit

enum GridKeyboard {
    enum Direction { case left, right, up, down }
    static func next(from index: Int, count: Int, columns: Int, direction: Direction) -> Int {
        guard count > 0 else { return 0 }
        let index = min(max(0, index), count - 1)
        let columns = min(max(1, columns), count)
        switch direction {
        case .left: return max(0, index - 1)
        case .right: return min(count - 1, index + 1)
        case .up: return index < columns ? index : index - columns
        case .down:
            return index / columns == (count - 1) / columns ? index : index + min(columns, count - 1 - index)
        }
    }
}

enum FileKeyboard {
    enum Action: Equatable { case menu, copyAbsolutePath }

    static func action(_ event: NSEvent) -> Action? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if ([36, 76].contains(event.keyCode) && flags == .control) || (event.keyCode == 109 && flags == .shift) { return .menu }
        if flags == [.command, .option], event.charactersIgnoringModifiers?.lowercased() == "c" { return .copyAbsolutePath }
        return nil
    }
}

extension NSTableView {
    /// Anchor inside the visible name column, even when columns extend
    /// beyond the viewport. Keyboard menus act on the selection, not an old click.
    func showKeyboardMenu(_ menu: NSMenu) {
        guard selectedRow >= 0, menu.numberOfItems > 0 else { return }
        scrollRowToVisible(selectedRow)
        let row = rect(ofRow: selectedRow).intersection(visibleRect)
        guard !row.isEmpty else { return }
        menu.popUp(positioning: nil, at: CGPoint(x: row.minX + min(80, row.width / 3), y: row.midY), in: self)
    }
}
