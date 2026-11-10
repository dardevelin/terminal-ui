import TerminalUI

/// The two looks the showcase plays in. Each states its own background, so
/// the renderer knows the ground it mixes fog, faded colours and the edges
/// of shapes toward — a terminal's own background no program can know.
enum ShowcaseLook: String {
    case dark, light

    var theme: any Theme {
        switch self {
        case .dark: ShowcaseDarkTheme()
        case .light: ShowcaseLightTheme()
        }
    }
}

// The colours are Catppuccin's (catppuccin.com/palette): Mocha for the dark
// look, Latte for the light, so a recording made in vhs's Catppuccin Mocha
// theme has no seam between the app's ground and the terminal's padding.

/// Catppuccin Mocha.
struct ShowcaseDarkTheme: Theme {
    var background: Color = .rgb(30, 30, 46)
    var foreground: Color = .rgb(205, 214, 244)
    var foregroundEmphasis: Color = .rgb(245, 247, 255)
    var foregroundMuted: Color = .rgb(127, 132, 156)
    var accent: Color = .rgb(137, 180, 250)
    var primary: Color = .rgb(250, 179, 135)
    var secondary: Color = .rgb(203, 166, 247)
    var success: Color = .rgb(166, 227, 161)
    var warning: Color = .rgb(249, 226, 175)
    var error: Color = .rgb(243, 139, 168)
    var info: Color = .rgb(116, 199, 236)
}

/// Catppuccin Latte.
struct ShowcaseLightTheme: Theme {
    var background: Color = .rgb(239, 241, 245)
    var foreground: Color = .rgb(76, 79, 105)
    var foregroundEmphasis: Color = .rgb(17, 17, 27)
    var foregroundMuted: Color = .rgb(140, 143, 161)
    var accent: Color = .rgb(30, 102, 245)
    var primary: Color = .rgb(254, 100, 11)
    var secondary: Color = .rgb(136, 57, 239)
    var success: Color = .rgb(64, 160, 43)
    var warning: Color = .rgb(223, 142, 29)
    var error: Color = .rgb(210, 15, 57)
    var info: Color = .rgb(4, 165, 229)
}

/// A span of a chapter's time, and how far through it a moment is.
///
/// A chapter is a score of cues, each placed by its start and length in
/// seconds; what a cue moves follows its progress, eased by TerminalUI's
/// `AnimationCurve`.
struct Cue {
    let start: Double
    let length: Double

    var end: Double { start + length }

    /// The cue from `start` to `end`.
    init(from start: Double, to end: Double) {
        self.start = start
        self.length = max(0, end - start)
    }

    /// 0 before the cue, 1 after it, and the share of it passed in between.
    func progress(at time: Double) -> Double {
        guard length > 0 else { return time < start ? 0 : 1 }
        return min(1, max(0, (time - start) / length))
    }

    /// The progress, eased by `curve`.
    func eased(at time: Double, _ curve: AnimationCurve = .easeInOut) -> Double {
        curve.apply(progress(at: time))
    }

    /// Whether `time` falls within the cue.
    func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }

    /// How present a scene playing over this cue is at `time`: rising from
    /// 0 to 1 over its first `fade` seconds, falling back over its last.
    func presence(at time: Double, fade: Double) -> Double {
        let rise = Cue(from: start, to: start + fade).eased(at: time)
        let fall = Cue(from: end - fade, to: end).eased(at: time)
        return min(rise, 1 - fall)
    }
}

/// A value `amount` of the way from `from` to `to`.
func mix(_ from: Double, _ to: Double, _ amount: Double) -> Double {
    from + (to - from) * amount
}
