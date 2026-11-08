import Darwin
import Foundation

/// How files share space on disk. On APFS a clone (Finder's Duplicate
/// makes one) shares its blocks with the file it was made from, so moving
/// one of the two frees nothing while the other stays.
public enum FileSpace {
    /// Which clone family the file belongs to: a clone has the ID of the
    /// file it was made from, an independent copy one of its own. nil where
    /// the volume can't say. Links aren't followed.
    public static func cloneID(_ path: String) -> UInt64? {
        extended(path, ATTR_CMNEXT_CLONEID, as: UInt64.self)
    }

    /// One extended attribute of the file, if the volume returned it.
    private static func extended<T>(_ path: String, _ attribute: Int32, as: T.Type) -> T? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(attribute)
        // The reply: its length, the attributes the volume returned, then the value.
        var buffer = [UInt8](repeating: 0, count: 64)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
        let ok = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, options) == 0
        }
        guard ok else { return nil }
        return buffer.withUnsafeBytes { raw -> T? in
            let lengthSize = MemoryLayout<UInt32>.size
            let returned = raw.loadUnaligned(fromByteOffset: lengthSize, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(attribute) != 0 else { return nil }
            return raw.loadUnaligned(fromByteOffset: lengthSize + MemoryLayout<attribute_set_t>.size, as: T.self)
        }
    }
}
