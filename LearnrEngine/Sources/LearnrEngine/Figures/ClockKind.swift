import Foundation

/// The `clock` kind, ported from `src/lib/figures/clock-kind.ts`: an analogue
/// face, its two hands, and optionally its numerals and minute track.
///
/// The hands *are* the answer, so the face is the only thing free to move —
/// which is why `numerals` and `minuteTicks` jitter when a template leaves them
/// out, and why the hand lengths jitter always.

private let clockRadius: Double = 0.5
private let rimPoints = 72
private let hours = 12
private let minutesPerHour = 60
private let minutesPerHourMark = minutesPerHour / hours

private let hourTick = 0.14
private let minuteTick = 0.07
private let tickInnerRadius = clockRadius * (1 - hourTick)

/// As many numerals as a report row can tell apart — the quarters.
private let numerals = [12, 3, 6, 9]

/// Half the ink of the widest numeral that will be drawn, whichever way round
/// the ring it is turned: the width where it sits east or west, the height
/// where it sits north or south. Folded over the *text*, never over the hour it
/// came from.
private let numeralInkReach = numerals
    .map { Swift.max((Double(String($0).count) * charShare) / 2, inkShare / 2) }
    .max()!

/// The ring the numerals stand on: as far out as their own ink still clears the
/// hour mark above it.
///
/// **Measured against the mark, not against the dial.** Sitting the ring at
/// `radius - inkReach` keeps a numeral's ink inside the rim, but the hour marks
/// reach `hourTick` of the way in from that rim, so a numeral's ink and the tick
/// above it would overlap — 1.69 real pixels in a report row at the 12 and the
/// 6, more than a whole stroke laid across a glyph.
private let numeralRadius = tickInnerRadius - numeralInkReach

/// How far the two hands reach, as shares of the dial's radius.
///
/// Bands rather than numbers: this is the jitter that survives a template
/// pinning both face fields, so it is the whole of this kind's answer to the
/// anchoring rule when everything else is pinned.
private let hourHandBand = (0.4, 0.52)
private let minuteHandBand = (0.76, 0.92)

private let fallbackHour: Double = 3
private let fallbackMinute: Double = 0

struct ClockBuilder: FigureKindBuilder {
    let kind = "clock"

    func build(_ spec: FigureSpec, _ scope: Scope, _ rng: inout Rng) -> [Mark] {
        let hour = hourOf(numberValue(readField(spec["hour"], scope)))
        let minute = minuteOf(numberValue(readField(spec["minute"], scope)))

        // **Four draws, always, whichever of the face fields is pinned.** One
        // `Rng` runs from the binding through the figure into the question's
        // own choice building, so a figure whose appetite depended on what a
        // template pinned would reshuffle the distractors of the very question
        // it illustrates.
        let numeralsJittered = rng.next() < 0.5
        let trackJittered = rng.next() < 0.5
        let hourHand = jitter(&rng, hourHandBand.0, hourHandBand.1) * clockRadius
        let minuteHand = jitter(&rng, minuteHandBand.0, minuteHandBand.1) * clockRadius

        let askedNumerals = readField(spec["numerals"], scope)
        let askedTrack = readField(spec["minuteTicks"], scope)
        let showNumerals = askedNumerals == nil ? numeralsJittered : truthy(askedNumerals)
        let showTrack = askedTrack == nil ? trackJittered : truthy(askedTrack)

        let angles = handAngles(hour, minute)
        var marks: [Mark] = [rimPath()]

        if showTrack {
            for index in 0..<minutesPerHour {
                // The positions an hour mark already stands on are skipped: a
                // short stroke under a long one is a heavier line, not a
                // countable mark.
                if index % minutesPerHourMark == 0 { continue }
                marks.append(tickAt(
                    Double(index) * 360 / Double(minutesPerHour),
                    minuteTick * clockRadius
                ))
            }
        }

        for index in 0..<hours {
            marks.append(tickAt(
                Double(index) * 360 / Double(hours),
                hourTick * clockRadius
            ))
        }

        marks.append(handAt(angles.hour, hourHand))
        marks.append(handAt(angles.minute, minuteHand))
        // The pin the two hands turn about, and the one mark that says they are
        // hands rather than two lines that happen to cross.
        marks.append(.dot(at: Point(0, 0)))

        // Last, so a hand pointing at a numeral passes under it rather than
        // crossing it out — the minute hand stands on one at every quarter.
        if showNumerals {
            for numeral in numerals {
                marks.append(.label(
                    at: onDial(Double(numeral) * 360 / Double(hours), numeralRadius),
                    text: String(numeral)
                ))
            }
        }

        return marks
    }
}

let clockBuilder = ClockBuilder()

/// Where the two hands point, in clock degrees from twelve.
///
/// The hour hand **carries on past the hour as the minutes pass** — it is the
/// whole hour in minutes plus the minutes, halved, so 3:30 is 105 degrees and
/// not 90. A face that left it on the three at half past would be drawing a
/// time that does not exist, and would look perfectly correct doing it.
func handAngles(_ hour: Double, _ minute: Double) -> (hour: Double, minute: Double) {
    (
        hour: (hour.truncatingRemainder(dividingBy: Double(hours))
               * Double(minutesPerHour) + minute) / 2,
        minute: minute * (360 / Double(minutesPerHour))
    )
}

/// A clock angle in the frame the builder draws in.
///
/// **The one place the two frames meet.** A clock runs clockwise from twelve;
/// `build` returns marks in the maths frame, which `fit` turns over on the way
/// out. It is one named function rather than a `90 - x` scattered through the
/// file because getting it backwards draws every time mirrored, and a mirrored
/// clock still looks like a clock.
func dialDirection(_ clockwiseFromTwelve: Double) -> Double {
    90 - clockwiseFromTwelve
}

/// A point on the dial at a clock angle, at this fraction of the way out.
private func onDial(_ clockwiseFromTwelve: Double, _ radius: Double) -> Point {
    let radians = dialDirection(clockwiseFromTwelve) * .pi / 180
    return Point(Foundation.cos(radians) * radius, Foundation.sin(radians) * radius)
}

private func rule(_ from: Point, _ to: Point) -> Mark {
    .path(points: [from, to], closed: false, fill: false, dashed: false)
}

/// The dial itself, and the reason the fit never moves: fixed sample angles,
/// four of them exactly on the axes, so the bounding box is the circle's
/// whatever is drawn inside it.
private func rimPath() -> Mark {
    .path(
        points: (0..<rimPoints).map {
            onDial(Double($0) * 360 / Double(rimPoints), clockRadius)
        },
        closed: true, fill: false, dashed: false
    )
}

/// One mark round the rim, reaching inward.
private func tickAt(_ clockwiseFromTwelve: Double, _ length: Double) -> Mark {
    rule(
        onDial(clockwiseFromTwelve, clockRadius),
        onDial(clockwiseFromTwelve, clockRadius - length)
    )
}

/// One hand: the centre out to where the time points.
private func handAt(_ clockwiseFromTwelve: Double, _ length: Double) -> Mark {
    rule(Point(0, 0), onDial(clockwiseFromTwelve, length))
}

/// The hour a face will show.
///
/// **Wrapped round the dial rather than clamped**, because 0 and 13 are real
/// twenty-four hour readings of twelve and one, and clamping would draw two
/// different hours as the same one.
private func hourOf(_ value: Double?) -> Double {
    guard let value else { return fallbackHour }
    let whole = JSNumber.round(value)
    let h = Double(hours)
    return ((whole - 1).truncatingRemainder(dividingBy: h) + h)
        .truncatingRemainder(dividingBy: h) + 1
}

/// The minute a face will show.
///
/// Wrapped for `hourOf`'s reason — and **never snapped to a readable step**: a
/// minute the face cannot express is reported by validation, and quietly moving
/// it onto the mark next door would draw a time the template did not ask for
/// and mark a right answer wrong.
private func minuteOf(_ value: Double?) -> Double {
    guard let value else { return fallbackMinute }
    let whole = JSNumber.round(value)
    let m = Double(minutesPerHour)
    return (whole.truncatingRemainder(dividingBy: m) + m).truncatingRemainder(dividingBy: m)
}
