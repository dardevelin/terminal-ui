import Foundation
import Observation
import TerminalUI

// Showcase: full-screen chapters that play on their own, made to be watched
// and recorded. `assets/3d.tape` and `assets/canvas.tape` record them for
// the README.
//
//   swift run Showcase            every chapter in turn, round and round
//   swift run Showcase 3d         one chapter, again and again
//   TERMINALUI_SHOWCASE=canvas swift run Showcase
//
// A recording presses no key: the PTY runner and vhs start an app without
// arguments, so the chapter can come from the environment instead, and the
// theme from TERMINALUI_SHOWCASE_THEME (dark or light). By hand, → and ←
// step between chapters, space pauses, r starts the chapter again, t
// switches the theme and q quits.
//
// TERMINALUI_SHOWCASE_PACE plays the chapters slower than life: 0.125 is an
// eighth of their speed. vhs's browser terminal takes longer to capture a
// frame of a thousand colours than the app takes to draw one, and a
// recorder that falls behind drops frames and plays the rest too fast;
// slowed down, it keeps every frame, and the recording plays them back as
// much faster.

/// The chapters, in the order they play.
enum Chapter: String, CaseIterable {
    case scene = "3d"
    case canvas

    /// Seconds from the chapter's first frame to its last.
    var duration: Double {
        switch self {
        case .scene: SceneChapter.duration
        case .canvas: CanvasChapter.duration
        }
    }
}

/// Where the programme stands: the chapters it plays and when it started,
/// paused or not, and in which look.
@Observable
final class ShowcaseState {
    /// The chapters played, in order and round again; one chapter when the
    /// launch chose it.
    private(set) var programme: [Chapter]
    /// When the programme's first chapter began.
    private(set) var start: Date
    /// The seconds into the programme it holds at while paused.
    private(set) var heldAt: Double?
    var look: ShowcaseLook
    /// Seconds of the programme a second of the wall clock plays.
    let pace: Double

    init(programme: [Chapter], look: ShowcaseLook, pace: Double = 1, start: Date = Date()) {
        self.programme = programme.isEmpty ? Chapter.allCases : programme
        self.look = look
        self.pace = pace > 0 && pace.isFinite ? pace : 1
        self.start = start
    }

    var isPaused: Bool { heldAt != nil }

    /// Seconds one time round the programme takes.
    var length: Double { programme.reduce(0) { $0 + $1.duration } }

    /// Seconds into the programme at `date`.
    func elapsed(at date: Date) -> Double {
        heldAt ?? date.timeIntervalSince(start) * pace
    }

    /// The time a clock in the programme shows at `date`: the wall clock's,
    /// held while paused and slowed with the pace.
    func clock(at date: Date) -> Date {
        start.addingTimeInterval(elapsed(at: date))
    }

    /// The chapter showing at `date`, and the seconds into it.
    func position(at date: Date) -> (chapter: Chapter, time: Double) {
        let elapsed = elapsed(at: date)
        var time = length > 0 ? elapsed.truncatingRemainder(dividingBy: length) : 0
        if time < 0 { time += length }
        for chapter in programme {
            if time < chapter.duration { return (chapter, time) }
            time -= chapter.duration
        }
        return (programme[0], 0)
    }

    func togglePause(now: Date = Date()) {
        if let held = heldAt {
            start = now.addingTimeInterval(-held / pace)
            heldAt = nil
        } else {
            heldAt = elapsed(at: now)
        }
    }

    /// Start the chapter showing now, or the one `offset` chapters along,
    /// from its beginning. A programme of one chapter becomes one of the
    /// chapter stepped to.
    func step(by offset: Int, now: Date = Date()) {
        let current = position(at: now).chapter
        let all = Chapter.allCases
        let index = all.firstIndex(of: current) ?? 0
        let target = all[((index + offset) % all.count + all.count) % all.count]
        if programme.count == 1 { programme = [target] }
        let before = programme.prefix { $0 != target }.reduce(0) { $0 + $1.duration }
        if heldAt != nil {
            heldAt = before
        } else {
            start = now.addingTimeInterval(-before / pace)
        }
    }
}

/// What the launch asked for: the chapter from the first argument or from
/// TERMINALUI_SHOWCASE, every chapter when neither names one; the look from
/// TERMINALUI_SHOWCASE_THEME, and the pace from TERMINALUI_SHOWCASE_PACE.
enum Launch {
    static let chapterVariable = "TERMINALUI_SHOWCASE"
    static let themeVariable = "TERMINALUI_SHOWCASE_THEME"
    static let paceVariable = "TERMINALUI_SHOWCASE_PACE"

    static func programme(arguments: [String] = CommandLine.arguments,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> [Chapter] {
        let named = arguments.dropFirst().first ?? environment[chapterVariable]
        return named.flatMap { Chapter(rawValue: $0.lowercased()) }.map { [$0] } ?? Chapter.allCases
    }

    static func look(environment: [String: String] = ProcessInfo.processInfo.environment) -> ShowcaseLook {
        environment[themeVariable].flatMap { ShowcaseLook(rawValue: $0.lowercased()) } ?? .dark
    }

    static func pace(environment: [String: String] = ProcessInfo.processInfo.environment) -> Double {
        environment[paceVariable].flatMap(Double.init) ?? 1
    }
}

/// The app's one model. `nonisolated(unsafe)`, as Storybook's and Coder's
/// are: the runtime builds the views that read it, and hands `onEvent` the
/// keys that change it, on the main actor, and nothing else touches it.
nonisolated(unsafe) let showcase = ShowcaseState(programme: Launch.programme(), look: Launch.look(),
                                                 pace: Launch.pace())

/// The chapter showing, built from the timeline's date.
struct ShowcaseView: TerminalView {
    let state: ShowcaseState

    /// Twenty frames to a second of the programme: smooth to the eye, and
    /// a third of the bytes of sixty — what keeps a recording of it small.
    static let frameInterval = 1.0 / 20.0

    var body: some TerminalView {
        let theme = state.look.theme
        let state = state
        let interval = Self.frameInterval / state.pace
        return TimelineView(.animation(minimumInterval: interval, paused: state.isPaused)) { context in
            let position = state.position(at: context.date)
            switch position.chapter {
            case .scene: SceneChapter(time: position.time)
            case .canvas: CanvasChapter(time: position.time, date: state.clock(at: context.date))
            }
        }
        .environment(\.theme, theme)
        .background(theme.background)
    }
}

@main
struct ShowcaseMain: TerminalAppProtocol {
    /// The look's ground behind the whole terminal, padding included, so a
    /// recording has no frame of the terminal's own colour round it.
    static var windowBackground: Color? { showcase.look.theme.background }

    static func onEvent(_ event: TerminalEvent) -> Bool {
        guard case .key(let press) = event else { return true }
        switch press.key {
        case .character("q"), .escape:
            return false
        case .right, .character("n"):
            showcase.step(by: 1)
        case .left, .character("p"):
            showcase.step(by: -1)
        case .character("r"):
            showcase.step(by: 0)
        case .character(" "):
            showcase.togglePause()
        case .character("t"):
            showcase.look = showcase.look == .dark ? .light : .dark
        default:
            break
        }
        return true
    }

    static func content() -> some TerminalView {
        ShowcaseView(state: showcase)
    }
}
