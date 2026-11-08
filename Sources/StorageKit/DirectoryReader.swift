import Darwin
import Foundation

/// One directory entry with exactly the metadata the scanner needs.
struct Entry {
    enum Kind { case file, folder, symlink, other }
    let name: String
    let kind: Kind
    /// Bytes actually allocated on disk (not the logical length), so sparse
    /// and compressed files count what they really cost.
    let allocated: Int64
    let linkCount: UInt32
    let fileID: UInt64
    let device: Int32
    let modified: TimeInterval
}

enum ReadOutcome { case ok, denied, failed, cancelled }

/// Reads whole directories with `getattrlistbulk(2)`: one system call
/// returns a batch of entries with their attributes, instead of a `readdir`
/// plus a `stat` per entry. On file systems that don't support it, falls
/// back to `readdir` + `fstatat`.
enum DirectoryReader {
    // attr.h bit values, spelled out as UInt32 (the macros don't all import
    // with a usable type).
    private static let cmnReturned: UInt32 = 0x8000_0000
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileAllocSize: UInt32 = 0x0000_0004
    /// FSOPT_PACK_INVAL_ATTRS: every requested attribute gets its slot even
    /// when invalid, so each record has a fixed layout to walk.
    private static let packInvalid: UInt64 = 0x0000_0008
    private static let bufferSize = 256 * 1024

    static func read(_ path: String, isCancelled: () -> Bool = { false }, _ body: (Entry) -> Void) -> ReadOutcome {
        guard !isCancelled() else { return .cancelled }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == EACCES || errno == EPERM ? .denied : .failed }
        defer { close(fd) }

        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = cmnReturned | cmnName | cmnDevID | cmnObjType | cmnModTime | cmnFileID | cmnError
        list.fileattr = fileLinkCount | fileAllocSize

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var outcome = ReadOutcome.ok
        while true {
            guard !isCancelled() else { return .cancelled }
            let count = getattrlistbulk(fd, &list, buffer, bufferSize, packInvalid)
            if count < 0 {
                if errno == ENOTSUP || errno == EINVAL { return readFallback(fd: fd, isCancelled: isCancelled, body) }
                return errno == EACCES || errno == EPERM ? .denied : .failed
            }
            if count == 0 { return outcome }
            var record = buffer
            for _ in 0..<count {
                guard !isCancelled() else { return .cancelled }
                let length = Int(record.loadUnaligned(as: UInt32.self))
                if let e = parse(record + 4) { body(e) } else { outcome = .failed }
                record += length
            }
        }
    }

    /// Walks one record. With PACK_INVAL every requested attribute is present.
    /// Order: the returned-set, then the error code (getattrlistbulk(2) puts
    /// it right after the returned-set, not in bit order), then the rest in
    /// attr.h bit order: name, devid, objtype, modtime, fileid, and finally
    /// the file attributes.
    private static func parse(_ start: UnsafeMutableRawPointer) -> Entry? {
        var p = start
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size
        let error = p.loadUnaligned(as: UInt32.self)
        p += 4
        let required = cmnName | cmnDevID | cmnObjType | cmnModTime | cmnFileID
        guard error == 0, returned.commonattr & required == required else { return nil }

        let nameRef = p.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (p + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        p += MemoryLayout<attrreference_t>.size
        let device = p.loadUnaligned(as: Int32.self)
        p += 4
        let objType = p.loadUnaligned(as: UInt32.self)
        p += 4
        let mod = p.loadUnaligned(as: timespec.self)
        p += MemoryLayout<timespec>.size
        let fileID = p.loadUnaligned(as: UInt64.self)
        p += 8
        let links = p.loadUnaligned(as: UInt32.self)
        p += 4
        let alloc = p.loadUnaligned(as: Int64.self)

        if name.isEmpty { return nil }
        let kind: Entry.Kind =
            switch objType {
            case 1: .file  // VREG
            case 2: .folder  // VDIR
            case 5: .symlink  // VLNK
            default: .other
            }
        let hasAlloc = returned.fileattr & fileAllocSize != 0
        return Entry(
            name: name, kind: kind, allocated: hasAlloc ? alloc : 0,
            linkCount: returned.fileattr & fileLinkCount != 0 ? links : 1,
            fileID: fileID, device: device,
            modified: TimeInterval(mod.tv_sec) + TimeInterval(mod.tv_nsec) / 1e9)
    }

    static func readFallback(fd: Int32, isCancelled: () -> Bool = { false }, _ body: (Entry) -> Void) -> ReadOutcome {
        let dupFD = dup(fd)
        guard dupFD >= 0 else { return .failed }
        guard let dir = fdopendir(dupFD) else {
            close(dupFD)
            return .failed
        }
        defer { closedir(dir) }
        var outcome = ReadOutcome.ok
        while true {
            guard !isCancelled() else { return .cancelled }
            // readdir's nil means either EOF or an error; another system
            // call's errno mustn't turn a complete directory into a failure.
            errno = 0
            guard let ent = readdir(dir) else { return errno == 0 ? outcome : .failed }
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                outcome = .failed
                continue
            }
            let type = st.st_mode & S_IFMT
            let kind: Entry.Kind =
                type == S_IFREG ? .file : type == S_IFDIR ? .folder : type == S_IFLNK ? .symlink : .other
            body(
                Entry(
                    name: name, kind: kind, allocated: Int64(st.st_blocks) * 512,
                    linkCount: UInt32(st.st_nlink), fileID: UInt64(st.st_ino), device: st.st_dev,
                    modified: TimeInterval(st.st_mtimespec.tv_sec)))
        }
    }

    /// Device of a path, to keep the walk on one volume.
    static func device(of path: String) -> Int32? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_dev : nil
    }
}

/// A folder's names for the searches that list a few known folders.
public enum DirectoryListing {
    /// The names in `dir`; empty when it isn't there, which is normal for
    /// a folder that's only sometimes present, and nil when it is there
    /// but can't be read, so a search knows it didn't see everything.
    public static func names(_ dir: String) -> [String]? {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir) { return names }
        var st = stat()
        return lstat(dir, &st) != 0 && errno == ENOENT ? [] : nil
    }
}
