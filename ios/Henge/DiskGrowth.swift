import Foundation

/// Growing a stopped Mac's disk: which sizes are offered, when it is refused, and the partition table move that lets
/// macOS use the new space. A disk only ever grows, and only as far as the largest size listed here.
enum DiskGrowth {
    static let sizesGB = [96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048]

    /// What macOS has to do afterwards: it keeps using the old size until its APFS container is grown inside it.
    /// Henge has already moved the recovery partition to the end of the disk, so the free space sits right after the
    /// container and this one command is enough (APFS grows a mounted container in place).
    static let guestCommand = "sudo diskutil apfs resizeContainer disk0s2 0"

    static func choices(currentBytes: Int64) -> [Int] { sizesGB.filter { Int64($0) << 30 > currentBytes } }

    /// Why a disk cannot be grown now, or nil. `vmState` is henge_vm_state(): 1 running, 3 starting or stopping, 4 paused.
    static func refusal(vmState: Int32, currentBytes: Int64, newGB: Int) -> String? {
        if [1, 3, 4].contains(vmState) { return "Stop the Mac first." }
        if !choices(currentBytes: currentBytes).contains(newGB) { return "The disk can only grow to a larger size." }
        return nil
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Makes the disk image at `path` `newBytes` long and moves its GPT to match. A macOS installer lays the disk out as
    /// iBoot system container, macOS's APFS container, then a 5 GB recovery container at the very end. Growing the file
    /// alone leaves the free space after the recovery container, where APFS cannot reach it, and the backup GPT in the
    /// middle of the disk. So every partition after the macOS container moves to the new end (same offset from the end,
    /// so alignment is kept), the backup GPT is written at the new last sector, and the space the moved partitions left
    /// is given back to the file system. Partition contents are position-independent (APFS addresses blocks from the
    /// partition start), and the GUIDs don't change. Returns what moved, for the log.
    @discardableResult
    static func grow(path: String, to newBytes: Int64) throws -> String {
        let fd = open(path, O_RDWR)
        guard fd >= 0 else { throw Failure(description: "The disk could not be opened (\(String(cString: strerror(errno)))).") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Failure(description: "The disk could not be read.") }
        let oldBytes = Int64(st.st_size)
        guard newBytes > oldBytes else { throw Failure(description: "The disk can only grow to a larger size.") }
        // Read the table before changing anything: a disk that isn't a macOS GPT disk is only made longer.
        let table = try? GPT.read(fd: fd, diskBytes: oldBytes)
        guard ftruncate(fd, off_t(newBytes)) == 0 else {
            throw Failure(description: "The disk could not be made larger (\(String(cString: strerror(errno)))).")
        }
        guard var gpt = table else { return "no GPT: file grown only" }
        // The old backup table isn't partition data: clear it first, so no stale header is left mid-disk.
        let oldArray = (Int64(gpt.entryArray.count) + gpt.sector - 1) / gpt.sector
        try GPT.zero(fd, at: oldBytes - (oldArray + 1) * gpt.sector, count: (oldArray + 1) * gpt.sector)
        let note = try gpt.moveTrailingPartitions(fd: fd, newBytes: newBytes)
        try gpt.write(fd: fd, diskBytes: newBytes)
        fsync(fd)
        return note
    }
}

/// The parts of a GUID partition table (UEFI 2.10, section 5.3) a grow touches.
struct GPT {
    static let appleAPFS = "7C3457EF-0000-11AA-AA11-00306543ECAC"

    struct Entry { var index: Int; var type: String; var first: Int64; var last: Int64 }

    var sector: Int64
    var header: [UInt8]          // the primary header sector, as read
    var entryArray: [UInt8]      // every entry slot, as read
    var entrySize: Int
    var entries: [Entry]

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[o + $1]) << (8 * $1) } }
    private static func u64(_ b: [UInt8], _ o: Int) -> Int64 { Int64(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * $1) }) }
    private static func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) { for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
    private static func put64(_ b: inout [UInt8], _ o: Int, _ v: Int64) { for i in 0..<8 { b[o + i] = UInt8(truncatingIfNeeded: UInt64(bitPattern: v) >> (8 * i)) } }

    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            c ^= UInt32(byte)
            for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        }
        return ~c
    }

    private static func guid(_ b: ArraySlice<UInt8>) -> String {
        let x = Array(b)
        let order = [3, 2, 1, 0, -1, 5, 4, -1, 7, 6, -1, 8, 9, -1, 10, 11, 12, 13, 14, 15]
        return order.map { $0 < 0 ? "-" : String(format: "%02X", x[$0]) }.joined()
    }

    static func pread(_ fd: Int32, _ count: Int, at offset: Int64) throws -> [UInt8] {
        var b = [UInt8](repeating: 0, count: count)
        guard Darwin.pread(fd, &b, count, off_t(offset)) == count else { throw DiskGrowth.Failure(description: "The disk could not be read.") }
        return b
    }

    static func pwrite(_ fd: Int32, _ b: [UInt8], at offset: Int64) throws {
        guard Darwin.pwrite(fd, b, b.count, off_t(offset)) == b.count else {
            throw DiskGrowth.Failure(description: "The disk could not be written (\(String(cString: strerror(errno)))).")
        }
    }

    static func read(fd: Int32, diskBytes: Int64) throws -> GPT {
        for sector: Int64 in [512, 4096] {
            let h = try pread(fd, Int(sector), at: sector)
            guard h[0..<8] == ArraySlice(Array("EFI PART".utf8)) else { continue }
            let size = Int(u32(h, 12))
            var check = Array(h[0..<size]); put32(&check, 16, 0)
            guard size >= 92, size <= Int(sector), crc32(check[...]) == u32(h, 16) else { break }
            guard u64(h, 32) == diskBytes / sector - 1 else {
                throw DiskGrowth.Failure(description: "The disk's partition table doesn't end at the end of the disk.")
            }
            let n = Int(u32(h, 80)), size1 = Int(u32(h, 84))
            guard n > 0, n <= 1024, size1 >= 128 else { break }
            let array = try pread(fd, n * size1, at: u64(h, 72) * sector)
            guard crc32(array[...]) == u32(h, 88) else { break }
            var entries: [Entry] = []
            for i in 0..<n {
                let o = i * size1
                if array[o..<o + 16].allSatisfy({ $0 == 0 }) { continue }
                entries.append(Entry(index: i, type: guid(array[o..<o + 16]), first: u64(array, o + 32), last: u64(array, o + 40)))
            }
            return GPT(sector: sector, header: h, entryArray: array, entrySize: size1, entries: entries)
        }
        throw DiskGrowth.Failure(description: "The disk has no GUID partition table.")
    }

    /// Moves the partitions after macOS's container to the new end of the disk, copying from the end backwards so a
    /// move shorter than the partition never reads what it already wrote. Zero runs (holes in the sparse file) become
    /// holes again instead of being written out.
    mutating func moveTrailingPartitions(fd: Int32, newBytes: Int64) throws -> String {
        guard let container = entries.filter({ $0.type == Self.appleAPFS }).max(by: { $0.last - $0.first < $1.last - $1.first }) else {
            return "no APFS container: table moved only"
        }
        let delta = newBytes / sector - (Self.u64(header, 32) + 1)
        let trailing = entries.indices.filter { entries[$0].first > container.last }.sorted { entries[$0].first > entries[$1].first }
        var moved: [String] = []
        let chunk: Int64 = 1 << 20
        for i in trailing {
            let e = entries[i]
            let start = e.first * sector, end = (e.last + 1) * sector
            var at = end
            while at > start {
                let from = max(start, at - chunk), count = Int(at - from)
                let data = try Self.pread(fd, count, at: from)
                if Self.isZero(data) {
                    try Self.zero(fd, at: from + delta * sector, count: Int64(count))
                } else {
                    try Self.pwrite(fd, data, at: from + delta * sector)
                }
                at = from
            }
            // What the partition no longer covers goes back to the file system (and reads as zeros).
            try Self.zero(fd, at: start, count: min(end, start + delta * sector) - start)
            entries[i].first += delta
            entries[i].last += delta
            moved.append("partition \(e.index + 1) moved \(e.first)->\(e.first + delta)")
        }
        return moved.isEmpty ? "nothing after the macOS container" : moved.joined(separator: ", ")
    }

    private static let zeroChunk = [UInt8](repeating: 0, count: 1 << 20)

    static func isZero(_ b: [UInt8]) -> Bool {
        b.withUnsafeBytes { p in zeroChunk.withUnsafeBytes { z in memcmp(p.baseAddress!, z.baseAddress!, min(p.count, z.count)) == 0 } }
    }

    /// Zeros a range, as a hole where the file system allows it (it needs block-aligned ranges).
    static func zero(_ fd: Int32, at offset: Int64, count: Int64) throws {
        guard count > 0 else { return }
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(offset), fp_length: off_t(count))
        if fcntl(fd, F_PUNCHHOLE, &hole) == 0 { return }
        let zeros = [UInt8](repeating: 0, count: Int(min(count, 1 << 20)))
        var at = offset
        while at < offset + count {
            let n = Int(min(Int64(zeros.count), offset + count - at))
            try pwrite(fd, Array(zeros[0..<n]), at: at)
            at += Int64(n)
        }
    }

    /// Writes the backup table at the new end first, then the primary, then the protective MBR's size.
    func write(fd: Int32, diskBytes: Int64) throws {
        let last = diskBytes / sector - 1
        let arraySectors = (Int64(entryArray.count) + sector - 1) / sector
        var array = entryArray
        for e in entries {
            Self.put64(&array, e.index * entrySize + 32, e.first)
            Self.put64(&array, e.index * entrySize + 40, e.last)
        }
        let arrayCRC = Self.crc32(array[...])
        let size = Int(Self.u32(header, 12))
        func headerSector(current: Int64, backup: Int64, entriesAt: Int64) -> [UInt8] {
            var h = header
            Self.put64(&h, 24, current)
            Self.put64(&h, 32, backup)
            Self.put64(&h, 48, last - arraySectors - 1)   // last usable sector
            Self.put64(&h, 72, entriesAt)
            Self.put32(&h, 88, arrayCRC)
            Self.put32(&h, 16, 0)
            Self.put32(&h, 16, Self.crc32(h[0..<size]))
            return h
        }
        let backupArrayAt = last - arraySectors
        try Self.pwrite(fd, array, at: backupArrayAt * sector)
        try Self.pwrite(fd, headerSector(current: last, backup: 1, entriesAt: backupArrayAt), at: last * sector)
        try Self.pwrite(fd, array, at: Self.u64(header, 72) * sector)
        try Self.pwrite(fd, headerSector(current: 1, backup: last, entriesAt: Self.u64(header, 72)), at: sector)
        var mbr = try Self.pread(fd, 512, at: 0)
        if mbr[510] == 0x55 && mbr[511] == 0xAA && mbr[446 + 4] == 0xEE {
            Self.put32(&mbr, 446 + 12, UInt32(min(last, 0xFFFF_FFFF)))
            try Self.pwrite(fd, mbr, at: 0)
        }
    }
}
