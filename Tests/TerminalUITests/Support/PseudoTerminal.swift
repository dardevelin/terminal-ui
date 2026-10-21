#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A pseudo-terminal pair: a test holds the primary side, as a terminal
/// emulator does, and the code under test reads the replica, as an app reads
/// its terminal.
struct PseudoTerminal {
    let primary: Int32
    let replica: Int32

    init?() {
        let primary = open("/dev/ptmx", O_RDWR | O_NOCTTY)
        guard primary >= 0 else { return nil }
        guard let name = Self.replicaName(of: primary) else {
            _ = close(primary)
            return nil
        }
        let replica = open(name, O_RDWR | O_NOCTTY)
        guard replica >= 0 else {
            _ = close(primary)
            return nil
        }
        self.primary = primary
        self.replica = replica
    }

    #if canImport(Glibc)
    /// glibc declares `grantpt`, `unlockpt` and `ptsname` only under
    /// `_XOPEN_SOURCE`, which Swift's Glibc module does not define, so this
    /// is Linux's own interface (pts(4)): unlock the replica, ask its number.
    private static func replicaName(of primary: Int32) -> String? {
        var unlocked: Int32 = 0
        var number: UInt32 = 0
        guard ioctl(primary, LinuxPTY.setLock, &unlocked) == 0,
              ioctl(primary, LinuxPTY.getNumber, &number) == 0 else { return nil }
        return "/dev/pts/\(number)"
    }
    #else
    private static func replicaName(of primary: Int32) -> String? {
        guard grantpt(primary) == 0, unlockpt(primary) == 0, let name = ptsname(primary) else {
            return nil
        }
        return String(cString: name)
    }
    #endif

    /// Types `text` and Return. A new terminal is canonical: it delivers
    /// input a line at a time.
    func typeLine(_ text: String) {
        let bytes = Array((text + "\n").utf8)
        _ = write(primary, bytes, bytes.count)
    }

    /// Closes the primary side, as a terminal emulator does when its window
    /// closes.
    func hangUp() {
        _ = close(primary)
    }

    func closeReplica() {
        _ = close(replica)
    }
}

#if canImport(Glibc)
/// The PTY multiplexer's requests, from include/uapi/asm-generic/ioctls.h —
/// the generic encoding that x86-64 and arm64 use.
private enum LinuxPTY {
    /// `TIOCGPTN`, `_IOR('T', 0x30, unsigned int)`: the replica's number.
    static let getNumber: UInt = 0x8004_5430
    /// `TIOCSPTLCK`, `_IOW('T', 0x31, int)`: lock or unlock the replica.
    static let setLock: UInt = 0x4004_5431
}
#endif
