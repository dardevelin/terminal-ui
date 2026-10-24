#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Testing
@testable import TerminalUI

// The terminal installs its handlers with `sigaction` rather than `signal()`:
// sanitizers intercept only `sigaction`, and under Thread Sanitizer a handler
// installed with `signal()` ran from the kernel in the middle of `free` and
// aborted on TSan's own lock. `SA_RESTART` carries over what `signal()` gave
// on BSD and glibc: the input task's blocked `read` of stdin resumes after a
// SIGWINCH instead of failing with EINTR.

@Suite("Signal handlers install through sigaction with SA_RESTART")
struct SignalDispositionTests {

    @Test func anInstalledHandlerRestartsInterruptedCalls() {
        var saved = sigaction()
        _ = sigaction(SIGUSR2, nil, &saved)
        defer { _ = sigaction(SIGUSR2, &saved, nil) }

        installSignalDisposition(SIGUSR2) { _ in }
        var installed = sigaction()
        _ = sigaction(SIGUSR2, nil, &installed)

        #expect(installed.sa_flags & SA_RESTART != 0)
        #if canImport(Darwin)
        #expect(installed.__sigaction_u.__sa_handler != nil)
        #elseif canImport(Glibc)
        #expect(installed.__sigaction_handler.sa_handler != nil)
        #endif
    }
}

// A signal sent to the process reaches any one thread not blocking it. The
// runtime blocks the ones it handles on the thread that starts its input
// thread, which inherits the mask and lifts it for itself: the input thread,
// waiting in `poll()` for the bytes their handlers write, takes them all.
// Under Thread Sanitizer, a SIGTERM that reached the idle main thread instead
// waited there until the app was killed.

@Suite("The input thread alone takes the signals the app handles")
struct WakingSignalMaskTests {

    /// The waking signals the calling thread blocks.
    private static func blocked() -> [Int32] {
        var mask = sigset_t()
        pthread_sigmask(SIG_BLOCK, nil, &mask)
        return Terminal.wakingSignals.filter { sigismember(&mask, $0) == 1 }
    }

    @Test func aThreadStartedAfterTheBlockInheritsItAndCanLiftIt() async {
        let before = Self.blocked()
        let previous = Terminal.blockWakingSignals()
        let blockedOnStarter = Self.blocked()
        let thread = BlockingThread(name: "waking-signal-test") { () -> ([Int32], [Int32]) in
            let inherited = Self.blocked()
            Terminal.unblockWakingSignals()
            return (inherited, Self.blocked())
        }
        Terminal.restoreSignalMask(previous)
        let restored = Self.blocked()
        let (inherited, lifted) = await thread.value

        #expect(blockedOnStarter == Terminal.wakingSignals)
        #expect(inherited == Terminal.wakingSignals)
        #expect(lifted.isEmpty)
        #expect(restored == before)
    }
}
