import Foundation
import Synchronization

/// A large list of files kept on disk instead of in memory, the way Inkline
/// opens a document it can't keep resident and QuikZip keeps only its hot
/// pages: fixed-size records in one file, their paths in another, read back
/// a page at a time through a small least-recently-used set of pages.
/// Sorting and filtering read the records off the main thread and return an
/// order of row numbers, four bytes a row, so the rows themselves stay on
/// disk.
///
/// It's a cache of one result: it lives in its own folder under `base`,
/// holds only the rows it was written with, and is deleted by `remove()`,
/// when the last reference to it goes, or by `removeAll(in:)` at launch. A write that fails leaves
/// nothing behind and throws, so the caller keeps its rows in memory.
public final class SpillTable: @unchecked Sendable {
    public struct Row: Sendable, Hashable {
        public let path: String
        public let size: Int64
        public let modified: Date
        public let kind: FileKind
        public let isFolder: Bool

        public init(path: String, size: Int64, modified: Date, kind: FileKind, isFolder: Bool = false) {
            self.path = path
            self.size = size
            self.modified = modified
            self.kind = kind
            self.isFolder = isFolder
        }

        public var name: String { (path as NSString).lastPathComponent }
        public var folder: String { (path as NSString).deletingLastPathComponent }
    }

    public enum Order: Sendable { case size, modified, name, kind, folder }

    public enum Failure: Error { case write, damaged }

    /// size Int64, modified Double, path offset UInt64, path length UInt32, kind UInt8, folder UInt8, padding.
    static let recordSize = 32
    public static let pageRows = 256

    public let count: Int
    public let folder: URL
    private let base: URL
    private let records: FileHandle
    private let strings: FileHandle
    private let pageLimit: Int
    private struct Pages {
        var rows: [Int: [Row]] = [:]
        var order: [Int] = []
    }
    private let pages = Mutex(Pages())
    private let removed = Atomic<Bool>(false)

    /// Where spilled results live: the app's caches folder.
    public static var defaultBase: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "MyMole/Spill")
    }

    /// Writes `rows` to a new table under `base`; `hotBytes` is what its
    /// cached pages may take in memory. `stop` abandons the write.
    public init(writing rows: some Collection<Row>, in base: URL = SpillTable.defaultBase, hotBytes: Int = 8 << 20,
                stop: () -> Bool = { false }) throws {
        let folder = base.appending(path: UUID().uuidString)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let recordsURL = folder.appending(path: "records"), stringsURL = folder.appending(path: "strings")
            guard fm.createFile(atPath: recordsURL.path, contents: nil), fm.createFile(atPath: stringsURL.path, contents: nil),
                  let recordOut = FileHandle(forWritingAtPath: recordsURL.path), let stringOut = FileHandle(forWritingAtPath: stringsURL.path)
            else { throw Failure.write }
            defer { try? recordOut.close(); try? stringOut.close() }
            var recordChunk = Data(capacity: Self.recordSize * Self.pageRows)
            var stringChunk = Data(capacity: 64 << 10)
            var offset: UInt64 = 0
            var written = 0
            for row in rows {
                if written % Self.pageRows == 0, stop() { throw Failure.write }
                let bytes = Array(row.path.utf8)
                var record = [UInt8](repeating: 0, count: Self.recordSize)
                Self.put(row.size, at: 0, in: &record)
                Self.put(row.modified.timeIntervalSinceReferenceDate.bitPattern, at: 8, in: &record)
                Self.put(offset, at: 16, in: &record)
                Self.put(UInt32(bytes.count), at: 24, in: &record)
                record[28] = UInt8(row.kind.rawValue)
                record[29] = row.isFolder ? 1 : 0
                recordChunk.append(contentsOf: record)
                stringChunk.append(contentsOf: bytes)
                offset += UInt64(bytes.count)
                written += 1
                if recordChunk.count >= Self.recordSize * Self.pageRows {
                    try recordOut.write(contentsOf: recordChunk)
                    recordChunk.removeAll(keepingCapacity: true)
                }
                if stringChunk.count >= 64 << 10 {
                    try stringOut.write(contentsOf: stringChunk)
                    stringChunk.removeAll(keepingCapacity: true)
                }
            }
            try recordOut.write(contentsOf: recordChunk)
            try stringOut.write(contentsOf: stringChunk)
            try recordOut.synchronize()
            try stringOut.synchronize()
            guard let recordIn = FileHandle(forReadingAtPath: recordsURL.path), let stringIn = FileHandle(forReadingAtPath: stringsURL.path)
            else { throw Failure.write }
            records = recordIn
            strings = stringIn
            count = written
        } catch {
            Self.removeOwned(folder, in: base)
            throw Failure.write
        }
        self.folder = folder
        self.base = base
        pageLimit = max(1, hotBytes / (Self.pageRows * 160))
    }

    /// A table nobody holds any more takes its files with it.
    deinit {
        try? records.close()
        try? strings.close()
        if !removed.load(ordering: .relaxed) { Self.removeOwned(folder, in: base) }
    }

    /// The bytes the table takes on disk.
    public var diskBytes: Int64 {
        let size = { (name: String) in
            Int64((try? FileManager.default.attributesOfItem(atPath: self.folder.appending(path: name).path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return size("records") + size("strings")
    }

    /// The row at `index`, through the page that holds it; nil past the end,
    /// once removed, or if the files no longer read back as written.
    public func row(at index: Int) -> Row? {
        guard index >= 0, index < count, !removed.load(ordering: .relaxed) else { return nil }
        let page = index / Self.pageRows
        if let rows = pages.withLock({ p -> [Row]? in
            guard let rows = p.rows[page] else { return nil }
            p.order.removeAll { $0 == page }
            p.order.append(page)
            return rows
        }) {
            return rows[index % Self.pageRows]
        }
        guard let rows = try? read(page: page) else { return nil }
        pages.withLock { p in
            p.rows[page] = rows
            p.order.removeAll { $0 == page }
            p.order.append(page)
            while p.order.count > pageLimit { p.rows[p.order.removeFirst()] = nil }
        }
        return rows[index % Self.pageRows]
    }

    /// Pages held in memory now, for tests and measurements.
    public var hotPages: Int { pages.withLock { $0.rows.count } }

    private func read(page: Int) throws -> [Row] {
        let first = page * Self.pageRows
        let n = min(Self.pageRows, count - first)
        let data = try pread(records, offset: UInt64(first * Self.recordSize), length: n * Self.recordSize)
        guard data.count == n * Self.recordSize else { throw Failure.damaged }
        var spans: [(offset: UInt64, length: Int, size: Int64, modified: Double, kind: UInt8, folder: Bool)] = []
        spans.reserveCapacity(n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let base = i * Self.recordSize
                spans.append((raw.loadUnaligned(fromByteOffset: base + 16, as: UInt64.self),
                              Int(raw.loadUnaligned(fromByteOffset: base + 24, as: UInt32.self)),
                              raw.loadUnaligned(fromByteOffset: base, as: Int64.self),
                              Double(bitPattern: raw.loadUnaligned(fromByteOffset: base + 8, as: UInt64.self)),
                              raw[base + 28], raw[base + 29] == 1))
            }
        }
        guard let start = spans.first?.offset, let last = spans.last else { return [] }
        let text = try pread(strings, offset: start, length: Int(last.offset - start) + last.length)
        guard text.count == Int(last.offset - start) + last.length else { throw Failure.damaged }
        return try spans.map { s in
            let from = Int(s.offset - start)
            guard from >= 0, from + s.length <= text.count, let kind = FileKind(rawValue: Int(s.kind)) else { throw Failure.damaged }
            let path = String(decoding: text[text.startIndex + from ..< text.startIndex + from + s.length], as: UTF8.self)
            return Row(path: path, size: s.size, modified: Date(timeIntervalSinceReferenceDate: s.modified), kind: kind, isFolder: s.folder)
        }
    }

    private func pread(_ handle: FileHandle, offset: UInt64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { Darwin.pread(handle.fileDescriptor, $0.baseAddress, length, off_t(offset)) }
        guard read == length else { throw Failure.damaged }
        return data
    }

    /// The rows' order for a column, filtered to those whose path holds
    /// every word of `query` (lower-cased, as the app's filters match) and
    /// that pass `keep`. Reads the table through once, a page at a time,
    /// without filling the hot pages; nil if stopped or damaged.
    public func ordered(by order: Order, ascending: Bool, query: String = "", keep: (Row) -> Bool = { _ in true },
                        stop: () -> Bool = { false }) -> [UInt32]? {
        let words = query.lowercased().split(separator: " ").map(String.init)
        var picked: [UInt32] = []
        var numbers: [Double] = []
        var texts: [String] = []
        for page in 0..<((count + Self.pageRows - 1) / Self.pageRows) {
            if stop() { return nil }
            guard let rows = try? read(page: page) else { return nil }
            for (i, row) in rows.enumerated() {
                if !words.isEmpty {
                    let path = row.path.lowercased()
                    guard words.allSatisfy({ path.contains($0) }) else { continue }
                }
                guard keep(row) else { continue }
                picked.append(UInt32(page * Self.pageRows + i))
                switch order {
                case .size: numbers.append(Double(row.size))
                case .modified: numbers.append(row.modified.timeIntervalSinceReferenceDate)
                case .kind: numbers.append(Double(row.kind.rawValue))
                case .name: texts.append(row.name)
                case .folder: texts.append(row.folder)
                }
            }
        }
        if stop() { return nil }
        var positions = Array(picked.indices)
        if texts.isEmpty {
            positions.sort { a, b in
                numbers[a] == numbers[b] ? picked[a] < picked[b] : (ascending ? numbers[a] < numbers[b] : numbers[a] > numbers[b])
            }
        } else {
            positions.sort { a, b in
                let r = texts[a].localizedStandardCompare(texts[b])
                return r == .orderedSame ? picked[a] < picked[b] : (ascending ? r == .orderedAscending : r == .orderedDescending)
            }
        }
        return positions.map { picked[$0] }
    }

    /// Deletes the table's files; reading afterwards returns nothing.
    public func remove() {
        guard !removed.exchange(true, ordering: .relaxed) else { return }
        pages.withLock { $0 = Pages() }
        Self.removeOwned(folder, in: base)
    }

    /// What every table under `base` takes on disk now.
    public static func bytes(in base: URL = SpillTable.defaultBase) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for child in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            for name in ["records", "strings"] {
                total += (try? fm.attributesOfItem(atPath: child.appending(path: name).path)[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }

    /// Every table left behind, at launch: a spill never outlives its result.
    public static func removeAll(in base: URL = SpillTable.defaultBase) {
        let children = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        for child in children { removeOwned(child, in: base) }
    }

    /// Removes a table's own folder and nothing else: a real folder (never
    /// a link) directly inside `base`, named by the UUID it was made with,
    /// holding only the table's two files.
    static func removeOwned(_ folder: URL, in base: URL) {
        let fm = FileManager.default
        let target = folder.standardizedFileURL, root = base.standardizedFileURL
        guard target.deletingLastPathComponent().path == root.path, UUID(uuidString: target.lastPathComponent) != nil else { return }
        var st = stat()
        guard lstat(target.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return }
        let names = Set((try? fm.contentsOfDirectory(atPath: target.path)) ?? [])
        guard names.isSubset(of: ["records", "strings"]) else { return }
        try? fm.removeItem(at: target)
    }

    private static func put<T: FixedWidthInteger>(_ value: T, at offset: Int, in record: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { bytes in
            for (i, b) in bytes.enumerated() { record[offset + i] = b }
        }
    }
}
