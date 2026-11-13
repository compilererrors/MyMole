import Darwin
import Foundation

/// How files share space on disk. On APFS a clone (Finder's Duplicate,
/// `cp -c` and the simulator make them) shares its blocks with the file it
/// was made from, so moving one of the two frees nothing while the other
/// stays.
public enum FileSpace {
    /// What the volume says about a file's blocks.
    public struct Sharing: Sendable, Hashable {
        /// Which clone family the file belongs to: a clone has the ID of
        /// the file it was made from, an independent copy one of its own.
        /// A clone that is partly rewritten gets an ID of its own while it
        /// still shares the rest.
        public var cloneID: UInt64?
        /// How many files hold the family's blocks, this one included.
        /// nil where the volume doesn't count them; a compressed file reads
        /// 0, its data being kept where the count doesn't look.
        public var cloneCount: UInt32?
        /// The blocks no other file uses, read only for a file the volume
        /// says may share some: a compressed file reads 0 here whatever it
        /// takes, so without the flag its allocated size is what it frees.
        public var privateBytes: Int64?
        /// Every block is shared with the rest of the family: the file is a
        /// whole clone, not one rewritten in part since.
        public var sharesAllBlocks: Bool

        public init(cloneID: UInt64? = nil, cloneCount: UInt32? = nil, privateBytes: Int64? = nil, sharesAllBlocks: Bool = false) {
            self.cloneID = cloneID
            self.cloneCount = cloneCount
            self.privateBytes = privateBytes
            self.sharesAllBlocks = sharesAllBlocks
        }

        /// The attributes as `getattrlist` packs them for `requested`, after
        /// the returned-attribute set: private size, clone ID, flags, count.
        fileprivate static func unpack(_ raw: UnsafeRawPointer, returned: attrgroup_t) -> Sharing? {
            func has(_ bit: Int32) -> Bool { returned & attrgroup_t(bit) != 0 }
            guard returned & attrgroup_t(requested) != 0 else { return nil }
            let privateSize = raw.loadUnaligned(as: Int64.self)
            let cloneID = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            let flags = raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
            let count = raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self)
            let mayShare = has(ATTR_CMNEXT_EXT_FLAGS) && flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
            return Sharing(
                cloneID: has(ATTR_CMNEXT_CLONEID) ? cloneID : nil,
                cloneCount: has(ATTR_CMNEXT_CLONE_REFCNT) ? count : nil,
                privateBytes: mayShare && has(ATTR_CMNEXT_PRIVATESIZE) ? max(privateSize, 0) : nil,
                sharesAllBlocks: mayShare && flags & UInt64(EF_SHARES_ALL_BLOCKS) != 0)
        }
    }

    /// The extended common attributes `Sharing` is read from, in the order
    /// they are packed.
    private static let requested = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS | ATTR_CMNEXT_CLONE_REFCNT

    /// The file's sharing in one call; nil where the volume answers none of
    /// it. Links aren't followed.
    public static func sharing(_ path: String) -> Sharing? {
        sharing { request, buffer, options in getattrlist(path, &request, buffer.baseAddress, buffer.count, options) }
    }

    /// The sharing of `name` inside the open folder `dir`, without following a link.
    static func sharing(at dir: Int32, _ name: String) -> Sharing? {
        sharing { request, buffer, options in getattrlistat(dir, name, &request, buffer.baseAddress, buffer.count, UInt(options)) }
    }

    private static func sharing(_ call: (inout attrlist, UnsafeMutableRawBufferPointer, UInt32) -> Int32) -> Sharing? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(requested)
        // Every requested attribute gets its slot, in attr.h bit order,
        // after the reply's length and the attributes the volume returned.
        var buffer = [UInt8](repeating: 0, count: 128)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS)
        let ok = buffer.withUnsafeMutableBytes { raw in call(&request, raw, options) == 0 }
        guard ok else { return nil }
        return buffer.withUnsafeBytes { raw -> Sharing? in
            let offset = MemoryLayout<UInt32>.size
            let returned = raw.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
            return Sharing.unpack(raw.baseAddress! + offset + MemoryLayout<attribute_set_t>.size, returned: returned.forkattr)
        }
    }
}
