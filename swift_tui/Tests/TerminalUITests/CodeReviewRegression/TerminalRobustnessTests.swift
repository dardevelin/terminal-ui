import Testing
@testable import TerminalUI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Syscall-injection layer for Terminal tests.
//
// Terminal.enableRawMode and Terminal.size talk to libc directly via
// `tcgetattr`, `tcsetattr`, and `ioctl`. The hardened return-value
// handling (raw-mode + 0×0 release fallback, commit 2069949) had no
// unit coverage — the failure paths can't be hit under the real test
// runner because the runner happens to be a TTY. This suite injects a
// failing PosixSyscalls implementation and pins the failure-mode
// contracts at the unit boundary.

@Suite("Terminal — syscall failure handling")
@MainActor
struct TerminalSyscallInjectionTests {

    @Test("enableRawMode returns false when tcgetattr fails")
    func enableRawModeReturnsFalseOnTcgetattrFailure() {
        let mock = FailingPosixSyscalls()
        mock.tcgetattrShouldFail = true
        Terminal.posix = mock
        defer { Terminal.posix = RealPosixSyscalls() }
        #expect(Terminal.enableRawMode() == false,
                "tcgetattr failure must propagate as enableRawMode == false")
        #expect(mock.tcgetattrCallCount == 1, "tcgetattr probed exactly once")
        #expect(mock.tcsetattrCallCount == 0,
                "tcsetattr must not run after tcgetattr already failed")
    }

    @Test("enableRawMode returns false when tcsetattr fails")
    func enableRawModeReturnsFalseOnTcsetattrFailure() {
        let mock = FailingPosixSyscalls()
        mock.tcsetattrShouldFail = true
        Terminal.posix = mock
        defer { Terminal.posix = RealPosixSyscalls() }
        #expect(Terminal.enableRawMode() == false,
                "tcsetattr failure must propagate as enableRawMode == false")
        #expect(mock.tcgetattrCallCount == 1)
        #expect(mock.tcsetattrCallCount == 1)
    }

    @Test("size falls back to VT100 default when ioctl returns nonzero")
    func sizeFallsBackOnIoctlError() {
        let mock = FailingPosixSyscalls()
        mock.ioctlShouldFail = true
        Terminal.posix = mock
        defer { Terminal.posix = RealPosixSyscalls() }
        #if DEBUG
        let prevDebug = Terminal.debugMinSize
        Terminal.debugMinSize = nil
        defer { Terminal.debugMinSize = prevDebug }
        #endif
        let size = Terminal.size()
        #expect(size.cols == 80 && size.rows == 24,
                "ioctl failure must fall back to VT100 default 80×24, got \(size)")
    }

    @Test("size falls back to VT100 default when ioctl returns 0×0")
    func sizeFallsBackOnZeroByZero() {
        let mock = FailingPosixSyscalls()
        mock.ioctlReturnsZeroSize = true
        Terminal.posix = mock
        defer { Terminal.posix = RealPosixSyscalls() }
        #if DEBUG
        let prevDebug = Terminal.debugMinSize
        Terminal.debugMinSize = nil
        defer { Terminal.debugMinSize = prevDebug }
        #endif
        let size = Terminal.size()
        #expect(size.cols == 80 && size.rows == 24,
                "ioctl reporting 0×0 must fall back to VT100 default 80×24, got \(size)")
    }
}
