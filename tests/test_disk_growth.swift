import Foundation

@main
struct DiskGrowthTests {
    static func main() {
        // `test_disk_growth <image> <GB>` grows a real image (a copy!) for checking with hdiutil and diskutil.
        if CommandLine.arguments.count == 3, let gb = Int64(CommandLine.arguments[2]) {
            do { print(try DiskGrowth.grow(path: CommandLine.arguments[1], to: gb << 30)) } catch { print("failed: \(error)"); exit(1) }
            return
        }
        let gb: Int64 = 1 << 30

        // A new 64 GB Mac is offered every size; a 128 GB one only the larger ones; a 2 TB one nothing.
        precondition(DiskGrowth.choices(currentBytes: 64 * gb) == [96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048])
        precondition(DiskGrowth.choices(currentBytes: 128 * gb) == [192, 256, 384, 512, 768, 1024, 1536, 2048])
        precondition(DiskGrowth.choices(currentBytes: 2048 * gb).isEmpty)

        // A disk between two sizes (an imported one) is offered only what is bigger than it.
        precondition(DiskGrowth.choices(currentBytes: 100 * gb) == [128, 192, 256, 384, 512, 768, 1024, 1536, 2048])

        // Allowed when stopped and larger.
        precondition(DiskGrowth.refusal(vmState: 0, currentBytes: 64 * gb, newGB: 128) == nil)
        precondition(DiskGrowth.refusal(vmState: 2, currentBytes: 64 * gb, newGB: 128) == nil)

        // Refused while the Mac is running, starting or stopping, or paused.
        for state: Int32 in [1, 3, 4] {
            precondition(DiskGrowth.refusal(vmState: state, currentBytes: 64 * gb, newGB: 128) != nil)
        }

        // Refused for the same size, a smaller one, or one that is not on the list.
        precondition(DiskGrowth.refusal(vmState: 2, currentBytes: 128 * gb, newGB: 128) != nil)
        precondition(DiskGrowth.refusal(vmState: 2, currentBytes: 128 * gb, newGB: 96) != nil)
        precondition(DiskGrowth.refusal(vmState: 2, currentBytes: 64 * gb, newGB: 1000) != nil)
        gptMove()
        print("disk growth ok")
    }

    /// A small disk laid out the way the macOS installer does it (iBoot system container, APFS container, recovery
    /// container last), grown, then read back.
    static func gptMove() {
        let mib: Int64 = 1 << 20, sector: Int64 = 512
        let path = NSTemporaryDirectory() + "disk-growth-\(getpid()).img"
        defer { unlink(path) }
        let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        precondition(fd >= 0)
        let total = 64 * mib, last = total / sector - 1
        precondition(ftruncate(fd, off_t(total)) == 0)
        func guidBytes(_ s: String) -> [UInt8] {
            let hex = s.replacingOccurrences(of: "-", with: "")
            let b = stride(from: 0, to: 32, by: 2).map { UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)! }
            return [b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + b[8...]
        }
        func le(_ v: Int64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: UInt64(bitPattern: v) >> (8 * $0)) } }
        let parts: [(String, Int64, Int64)] = [
            ("69646961-6700-11AA-AA11-00306543ECAC", 40, 2087),
            ("7C3457EF-0000-11AA-AA11-00306543ECAC", 2088, last - 41 - 10240),
            ("52637672-7900-11AA-AA11-00306543ECAC", last - 41 - 10240 + 1, last - 41),
        ]
        var array = [UInt8](repeating: 0, count: 128 * 128)
        for (i, p) in parts.enumerated() {
            array.replaceSubrange(i * 128..<i * 128 + 16, with: guidBytes(p.0))
            array.replaceSubrange(i * 128 + 16..<i * 128 + 32, with: [UInt8](repeating: UInt8(i + 1), count: 16))
            array.replaceSubrange(i * 128 + 32..<i * 128 + 48, with: le(p.1, 8) + le(p.2, 8))
        }
        func header(current: Int64, backup: Int64, entries: Int64) -> [UInt8] {
            var h = [UInt8](repeating: 0, count: 512)
            h.replaceSubrange(0..<8, with: Array("EFI PART".utf8))
            h.replaceSubrange(8..<16, with: [0, 0, 1, 0, 92, 0, 0, 0])
            h.replaceSubrange(24..<56, with: le(current, 8) + le(backup, 8) + le(34, 8) + le(last - 33, 8))
            h.replaceSubrange(72..<92, with: le(entries, 8) + le(128, 4) + le(128, 4) + le(Int64(GPT.crc32(array[...])), 4))
            h.replaceSubrange(16..<20, with: le(Int64(GPT.crc32(h[0..<92])), 4))
            return h
        }
        var mbr = [UInt8](repeating: 0, count: 512)
        mbr[446 + 4] = 0xEE; mbr[510] = 0x55; mbr[511] = 0xAA
        try! GPT.pwrite(fd, mbr, at: 0)
        try! GPT.pwrite(fd, header(current: 1, backup: last, entries: 2), at: sector)
        try! GPT.pwrite(fd, array, at: 2 * sector)
        try! GPT.pwrite(fd, array, at: (last - 32) * sector)
        try! GPT.pwrite(fd, header(current: last, backup: 1, entries: last - 32), at: last * sector)
        // Recognisable bytes at both ends of the recovery container, and in the macOS container (which must not move).
        let recoveryStart = parts[2].1 * sector, recoveryEnd = (parts[2].2 + 1) * sector
        try! GPT.pwrite(fd, Array("recovery-first".utf8), at: recoveryStart)
        try! GPT.pwrite(fd, Array("recovery-last".utf8), at: recoveryEnd - 13)
        try! GPT.pwrite(fd, Array("macos".utf8), at: parts[1].1 * sector)
        close(fd)

        let grown = 96 * mib
        _ = try! DiskGrowth.grow(path: path, to: grown)
        let rfd = open(path, O_RDONLY)
        defer { close(rfd) }
        let gpt = try! GPT.read(fd: rfd, diskBytes: grown)   // checks both CRCs and that the backup is at the new end
        let delta = (grown - total) / sector
        precondition(gpt.entries.map(\.first) == [40, 2088, parts[2].1 + delta])
        precondition(gpt.entries.map(\.last) == [2087, parts[1].2, parts[2].2 + delta])
        func text(_ at: Int64, _ n: Int) -> String { String(decoding: try! GPT.pread(rfd, n, at: at), as: UTF8.self) }
        precondition(text(recoveryStart + delta * sector, 14) == "recovery-first")
        precondition(text(recoveryEnd + delta * sector - 13, 13) == "recovery-last")
        precondition(text(parts[1].1 * sector, 5) == "macos")
        precondition(try! GPT.pread(rfd, 14, at: recoveryStart).allSatisfy { $0 == 0 })      // the old place is free
        precondition(try! GPT.pread(rfd, 8, at: last * sector).allSatisfy { $0 == 0 })       // no stale backup header
        let backup = try! GPT.pread(rfd, 512, at: (grown / sector - 1) * sector)
        precondition(backup[0..<8] == ArraySlice(Array("EFI PART".utf8)))
        let pmbr = try! GPT.pread(rfd, 512, at: 0)
        precondition((0..<4).reduce(Int64(0)) { $0 | Int64(pmbr[458 + $1]) << (8 * $1) } == grown / sector - 1)
    }
}
