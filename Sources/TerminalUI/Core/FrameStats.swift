#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import Foundation

// MARK: - Cross-platform monotonic clock

/// Returns the current monotonic time in nanoseconds.
/// Uses `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)` on Darwin
/// and `clock_gettime(CLOCK_MONOTONIC)` on Linux.
func monotonicNanoseconds() -> UInt64 {
    #if canImport(Darwin)
    return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    #elseif canImport(Glibc)
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    #endif
}

/// Real-time frame statistics, updated by the runtime each frame.
public struct FrameStats: Sendable {
    /// Current frames per second (smoothed)
    public var fps: Double
    /// Total frame time (build + render + flush)
    public var lastFrameTime: Duration
    /// Time spent building views + layout + diffing (our code)
    public var buildTime: Duration
    /// Time spent writing to stdout (I/O)
    public var flushTime: Duration
    /// Total frames rendered this session
    public var frameCount: Int
    /// Number of cells changed in last diff
    public var cellsChanged: Int
    /// Total cells in the buffer
    public var totalCells: Int
    /// Bytes written last frame
    public var bytesWritten: Int
    /// Time since app started
    public var uptime: Duration
    /// Whether this frame did actual rendering work
    public var wasActive: Bool

    // Last active frame stats — preserved across idle frames
    public var lastActiveBuildTime: Duration
    public var lastActiveFlushTime: Duration
    public var lastActiveCellsChanged: Int
    public var lastActiveBytesWritten: Int
    public var activeRenderFps: Double

    public static let zero = FrameStats(
        fps: 0, lastFrameTime: .zero, buildTime: .zero, flushTime: .zero,
        frameCount: 0, cellsChanged: 0, totalCells: 0, bytesWritten: 0,
        uptime: .zero, wasActive: false,
        lastActiveBuildTime: .zero, lastActiveFlushTime: .zero,
        lastActiveCellsChanged: 0, lastActiveBytesWritten: 0, activeRenderFps: 0
    )
}

/// Tracks frame timing and computes smoothed FPS.
final class FrameCounter {
    private var frameTimes: [UInt64] = []  // nanosecond timestamps of recent frames
    private var lastFrameStart: UInt64 = 0
    private var lastFrameDuration: UInt64 = 0
    private var count: Int = 0
    private let startTime: UInt64

    init() {
        self.startTime = monotonicNanoseconds()
    }

    func beginFrame() {
        lastFrameStart = monotonicNanoseconds()
    }

    // Tracks last active frame stats
    private var lastActiveBuild: UInt64 = 0
    private var lastActiveFlush: UInt64 = 0
    private var lastActiveCells: Int = 0
    private var lastActiveBytes: Int = 0
    private var activeFrameTimes: [UInt64] = []

    func endFrame(cellsChanged: Int, totalCells: Int, buildNs: UInt64, flushNs: UInt64, bytesWritten: Int) -> FrameStats {
        let now = monotonicNanoseconds()
        lastFrameDuration = now - lastFrameStart
        count += 1

        frameTimes.append(now)
        if frameTimes.count > 60 {
            frameTimes.removeFirst(frameTimes.count - 60)
        }

        let fps: Double
        if frameTimes.count >= 2 {
            let window = Double(frameTimes.last! - frameTimes.first!) / 1_000_000_000.0
            fps = window > 0 ? Double(frameTimes.count - 1) / window : 0
        } else {
            fps = 0
        }

        let uptime = now - startTime

        let isActive = cellsChanged > 0 || bytesWritten > 0

        if isActive {
            lastActiveBuild = buildNs
            lastActiveFlush = flushNs
            lastActiveCells = cellsChanged
            lastActiveBytes = bytesWritten

            activeFrameTimes.append(now)
            if activeFrameTimes.count > 60 {
                activeFrameTimes.removeFirst(activeFrameTimes.count - 60)
            }
        }

        let activeFps: Double
        if activeFrameTimes.count >= 2 {
            let window = Double(activeFrameTimes.last! - activeFrameTimes.first!) / 1_000_000_000.0
            activeFps = window > 0 ? Double(activeFrameTimes.count - 1) / window : 0
        } else {
            activeFps = 0
        }

        return FrameStats(
            fps: fps,
            lastFrameTime: .nanoseconds(Int64(lastFrameDuration)),
            buildTime: .nanoseconds(Int64(buildNs)),
            flushTime: .nanoseconds(Int64(flushNs)),
            frameCount: count,
            cellsChanged: cellsChanged,
            totalCells: totalCells,
            bytesWritten: bytesWritten,
            uptime: .nanoseconds(Int64(uptime)),
            wasActive: isActive,
            lastActiveBuildTime: .nanoseconds(Int64(lastActiveBuild)),
            lastActiveFlushTime: .nanoseconds(Int64(lastActiveFlush)),
            lastActiveCellsChanged: lastActiveCells,
            lastActiveBytesWritten: lastActiveBytes,
            activeRenderFps: activeFps
        )
    }
}
