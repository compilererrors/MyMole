import Darwin
import Foundation

/// The lock Finder's Get Info sets (the owner's immutable flag). A locked
/// item can't be moved, so an uninstall unlocks it right before it moves,
/// as Finder does once you agree; a move that fails locks it again. The
/// system's own lock, which only root can clear, is never touched.
public enum Locks {
    public static func isLocked(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_flags & UInt32(UF_IMMUTABLE) != 0
    }

    /// False when it stays locked: the system's lock, or not the owner's to clear.
    @discardableResult
    public static func unlock(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_flags & UInt32(SF_IMMUTABLE) == 0 else { return false }
        return lchflags(path, st.st_flags & ~UInt32(UF_IMMUTABLE)) == 0
    }

    public static func lock(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        _ = lchflags(path, st.st_flags | UInt32(UF_IMMUTABLE))
    }

    /// Runs `move` on `path` with Finder's lock cleared first, and locks it
    /// again when the move didn't happen. Unlocked items move as they are.
    public static func moving<T>(_ path: String, moved: (T) -> Bool, _ move: () -> T) -> T? {
        let locked = isLocked(path)
        if locked, !unlock(path) { return nil }
        let result = move()
        if locked, !moved(result) { lock(path) }
        return result
    }
}

extension TrashBackend {
    /// The same moves, with items locked in Finder unlocked first.
    public func unlockingLocked() -> TrashBackend {
        let base = self
        return TrashBackend { path in
            Locks.moving(path, moved: { $0.trashed != nil }) { base.moveOne(path) }
                ?? (nil, "Locked, and it couldn't be unlocked")
        }
    }
}
