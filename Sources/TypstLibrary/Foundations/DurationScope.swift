import Foundation
import TypstSyntax
import TypstUtils

// The `duration` type's associated scope — port of the `#[scope] impl
// Duration` block in upstream `foundations/duration.rs`.

/// Build the scope containing all `duration` methods.
func durationScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(durationSeconds)
    scope.defineFunc(durationMinutes)
    scope.defineFunc(durationHours)
    scope.defineFunc(durationDays)
    scope.defineFunc(durationWeeks)
    return scope
}

/// `duration` constructor — port of `Duration::construct`.
let durationConstruct = nativeFunc(
    "duration",
    title: "Duration",
    since: .version([0, 8, 0]),
    docs: """
        Creates a new duration.

        You can specify the duration using weeks, days, hours, \
        minutes and seconds. You can also get a duration by subtracting \
        two datetimes.
        """,
    params: [
        NativeParamInfo(
            name: "seconds", input: Int64.input,
            defaultValue: { .int(0) }, positional: false, named: true),
        NativeParamInfo(
            name: "minutes", input: Int64.input,
            defaultValue: { .int(0) }, positional: false, named: true),
        NativeParamInfo(
            name: "hours", input: Int64.input,
            defaultValue: { .int(0) }, positional: false, named: true),
        NativeParamInfo(
            name: "days", input: Int64.input,
            defaultValue: { .int(0) }, positional: false, named: true),
        NativeParamInfo(
            name: "weeks", input: Int64.input,
            defaultValue: { .int(0) }, positional: false, named: true),
    ],
    returns: Duration.output
) { _, _, args in
    let seconds: Int64 = try args.namedT("seconds") ?? 0
    let minutes: Int64 = try args.namedT("minutes") ?? 0
    let hours: Int64 = try args.namedT("hours") ?? 0
    let days: Int64 = try args.namedT("days") ?? 0
    let weeks: Int64 = try args.namedT("weeks") ?? 0
    try args.finishT()

    return Duration(
        seconds: Double(seconds)
            + Double(minutes) * 60
            + Double(hours) * 3600
            + Double(days) * 86400
            + Double(weeks) * 604800)
}

/// Shared builder for the `f64`-returning duration accessors.
private func durationAccessor(
    _ name: String,
    docs: String,
    value: @escaping @Sendable (Duration) -> Double
) -> NativeFuncData {
    nativeFunc(
        name,
        since: .version([0, 8, 0]),
        docs: docs,
        params: [NativeParamInfo(name: "self", input: Duration.input, required: true)],
        returns: Double.output
    ) { _, _, args in
        let duration: Duration = try args.expectT("self")
        try args.finishT()
        return value(duration)
    }
}

let durationSeconds = durationAccessor(
    "seconds",
    docs: """
        The duration expressed in seconds.

        This function returns the total duration represented in seconds \
        as a floating-point number, rather than the seconds component of \
        the duration.
        """
) { $0.secondsValue }

let durationMinutes = durationAccessor(
    "minutes",
    docs: """
        The duration expressed in minutes.

        This function returns the total duration represented in minutes \
        as a floating-point number, rather than the minutes component of \
        the duration.
        """
) { $0.minutesValue }

let durationHours = durationAccessor(
    "hours",
    docs: """
        The duration expressed in hours.

        This function returns the total duration represented in hours as \
        a floating-point number, rather than the hours component of the \
        duration.
        """
) { $0.hoursValue }

let durationDays = durationAccessor(
    "days",
    docs: """
        The duration expressed in days.

        This function returns the total duration represented in days as a \
        floating-point number, rather than the days component of the \
        duration.
        """
) { $0.daysValue }

let durationWeeks = durationAccessor(
    "weeks",
    docs: """
        The duration expressed in weeks.

        This function returns the total duration represented in weeks as \
        a floating-point number, rather than the weeks component of the \
        duration.
        """
) { $0.weeksValue }
