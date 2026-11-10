# Drawing on a schedule

A view that draws again at the dates of a schedule — every frame, every
second, at the top of each minute — SwiftUI's `TimelineView`.

## Overview

A ``TimelineView`` builds its content from a context whose
``TimelineViewDefaultContext/date`` is the schedule's latest date. Build what
that moment shows from it, and the view keeps it current:

```swift
TimelineView(.animation) { context in
    let phase = context.date.timeIntervalSinceReferenceDate
    Canvas { graphics, size in
        var wave = Path()
        wave.addLines(stride(from: 0, through: size.width, by: 0.5).map { x in
            CanvasPoint(x: x, y: size.height / 2 * (1 + sin(x / 4 + phase * 3)))
        })
        graphics.stroke(wave, with: .color(.cyan))
    }
}

TimelineView(.periodic(from: .now, by: 1)) { context in
    Text(context.date.formatted(date: .omitted, time: .standard))
}
```

### Schedules

- ``AnimationTimelineSchedule`` (`.animation`) builds the content again for
  every frame the app draws, at its render mode's cap; an `.onDemand` app,
  which has none, at sixty a second. `minimumInterval` holds frames further
  apart, and `paused` holds the animation still at the date it reached.
- ``PeriodicTimelineSchedule`` (`.periodic(from:by:)`) has a date every so
  many seconds from a start, ``EveryMinuteTimelineSchedule``
  (`.everyMinute`) one at the start of each minute, and
  ``ExplicitTimelineSchedule`` (`.explicit(_:)`) the dates it is given. The
  view shows the latest date that has passed, and the app sleeps until the
  next.

``TimelineViewDefaultContext/cadence`` says how often the timeline updates,
so a view can leave out what changes faster: a clock on `.everyMinute` drops
its seconds hand.

### What a timeline costs

Only the timeline's own body runs again at each date, as for a change to the
state it read; the views around it are not built again. A timeline asks for
its next date as its body runs, and nothing else keeps a record of it: one
that leaves the tree, or whose animation is paused, asks for nothing, and an
app with no timeline running stays idle — no timer runs while no view wants
one.

Dates are the wall clock's. A clock set back while a timeline waits — by
hand, or a machine waking from sleep — draws it at once rather than leaving
it waiting for the clock to catch up.

## Topics

### The view

- ``TimelineView``
- ``TimelineViewDefaultContext``

### Schedules

- ``TimelineSchedule``
- ``TimelineScheduleMode``
- ``AnimationTimelineSchedule``
- ``PeriodicTimelineSchedule``
- ``EveryMinuteTimelineSchedule``
- ``ExplicitTimelineSchedule``
