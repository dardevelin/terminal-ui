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
