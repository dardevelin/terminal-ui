import Foundation

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

    public static let zero = FrameStats(
        fps: 0, lastFrameTime: .zero, buildTime: .zero, flushTime: .zero,
        frameCount: 0, cellsChanged: 0, totalCells: 0, bytesWritten: 0,
        uptime: .zero
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
        self.startTime = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }

    func beginFrame() {
        lastFrameStart = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }

    func endFrame(cellsChanged: Int, totalCells: Int, buildNs: UInt64, flushNs: UInt64, bytesWritten: Int) -> FrameStats {
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
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

        return FrameStats(
            fps: fps,
            lastFrameTime: .nanoseconds(Int64(lastFrameDuration)),
            buildTime: .nanoseconds(Int64(buildNs)),
            flushTime: .nanoseconds(Int64(flushNs)),
            frameCount: count,
            cellsChanged: cellsChanged,
            totalCells: totalCells,
            bytesWritten: bytesWritten,
            uptime: .nanoseconds(Int64(uptime))
        )
    }
}
