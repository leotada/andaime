/// `Timestamp`: an instant with the UTC offset it was written in (`2026-10-19T12:00:00Z`,
/// `2026-10-19T09:00:00.25-03:00`), to the microsecond, as a value. It is a text type (`andaime.http.texttype`), so it
/// works as a path or query parameter, in a form, in JSON and as a `timestamptz` column with `rowsAs`, and OpenAPI says
/// `format: date-time`.
///
/// Reading the clock is an effect, so a domain takes "now" through a port. `toSysTime`/`fromSysTime` convert to and from
/// `std.datetime.SysTime`; `std.datetime` is compiled only if you call them.
///
/// Text, both ways:
/// - read: `YYYY-MM-DD`, then `T`, `t` or a space, `hh:mm:ss`, an optional fraction of any length (rounded half up to
///   the microsecond), and a required offset: `Z`, `z`, `±hh`, `±hhmm`, `±hh:mm` or `±hh:mm:00`, at most 18 hours.
///   That is RFC 3339 and also what Postgres prints for a `timestamptz` (`2026-10-19 12:00:00.123456+00`,
///   `+05:30`). A time without an offset is not an instant and is refused, like a leap second (`:60`) and `24:00`.
/// - written: `YYYY-MM-DDThh:mm:ss`, then the fraction only when it is not zero, with up to 6 digits and no trailing
///   zeros (`.25`, `.000001`), then `Z` for offset zero or `±hh:mm`. The time is shown in the value's own offset.
module andaime.values.timestamp 2025;

@safe:

import core.time : Duration, usecs;
import andaime.values.calendardate : CalendarDate, civilFromDays, daysFromCivil, digits, parseYmd, validYmd, writeDigits,
    writeYmd;

/// An instant in 0001-01-01 .. 9999-12-31, both in UTC and in its local time (the instant plus its offset), so that
/// `utc` always works. `Timestamp.init` is 1970-01-01T00:00:00Z.
///
/// `==`, `<` and `toHash` look at the instant only, as `SysTime`'s do: `12:00Z == 09:00-03:00`, so a value read back
/// from a database whose session prints another offset is still equal to the one stored. The offset is kept for
/// writing (`offsetMinutes`, `toString`); compare it yourself when it matters.
struct Timestamp
{
    private long micros_;  // since 1970-01-01T00:00:00Z
    private short offset_; // minutes east of UTC

    enum openApiFormat = "date-time";
    enum invalidMessage = "expected a date-time with an offset, like 2026-10-19T12:00:00Z";

    /// The largest offset, in minutes (18 hours, as in `java.time` and Postgres' input).
    enum int maxOffsetMinutes = 18 * 60;

    private enum long usPerSec = 1_000_000, usPerDay = 86_400 * usPerSec;
    private enum long minUs = CalendarDate.minDays * usPerDay, maxUs = (CalendarDate.maxDays + 1) * usPerDay - 1;

    /// True when `fromUnixMicros(us, offsetMinutes)` holds a value: the offset within 18 hours, and the instant in
    /// years 1-9999 both in UTC and in that offset.
    static bool inRange(long us, int offsetMinutes) pure nothrow @nogc
    {
        if (offsetMinutes < -maxOffsetMinutes || offsetMinutes > maxOffsetMinutes || us < minUs || us > maxUs)
            return false;
        immutable local = us + offsetMinutes * 60L * usPerSec;
        return local >= minUs && local <= maxUs;
    }

    /// The instant `us` microseconds after 1970-01-01T00:00:00Z, written with `offsetMinutes` (east of UTC: São Paulo
    /// is `-180`). Needs `inRange(us, offsetMinutes)`, which a clock's reading always is.
    static Timestamp fromUnixMicros(long us, int offsetMinutes = 0) pure nothrow @nogc
    in (inRange(us, offsetMinutes), "andaime: Timestamp outside years 1-9999 or offset beyond 18 hours")
    {
        Timestamp t;
        t.micros_ = us;
        t.offset_ = cast(short) offsetMinutes;
        return t;
    }

    /// Microseconds since 1970-01-01T00:00:00Z.
    long unixMicros() const pure nothrow @nogc => micros_;

    /// The offset it is written in, in minutes east of UTC.
    int offsetMinutes() const pure nothrow @nogc => offset_;

    /// The same instant, written in UTC (`Z`).
    Timestamp utc() const pure nothrow @nogc => fromUnixMicros(micros_, 0);

    /// The same instant, written with another offset.
    Timestamp withOffset(int minutes) const pure nothrow @nogc => fromUnixMicros(micros_, minutes);

    /// The calendar date of its local time (the date in its own offset).
    CalendarDate date() const pure nothrow @nogc
    {
        CalendarDate d;
        CalendarDate.fromDays(floorDiv(local, usPerDay), d);
        return d;
    }

    /// The same instant, whatever the offsets.
    bool opEquals(const Timestamp o) const pure nothrow @nogc => micros_ == o.micros_;

    /// Instant order.
    int opCmp(const Timestamp o) const pure nothrow @nogc => micros_ < o.micros_ ? -1 : micros_ > o.micros_;

    /// Hashes the instant (agrees with `==`).
    size_t toHash() const pure nothrow @nogc => cast(size_t)(micros_ ^ (micros_ >>> 32));

    /// Moves the instant (to the microsecond; the offset stays). The result must stay in years 1-9999.
    Timestamp opBinary(string op : "+")(Duration d) const pure nothrow @nogc
        => fromUnixMicros(micros_ + d.total!"usecs", offset_);

    /// ditto
    Timestamp opBinary(string op : "-")(Duration d) const pure nothrow @nogc
        => fromUnixMicros(micros_ - d.total!"usecs", offset_);

    /// The time between two instants.
    Duration opBinary(string op : "-")(const Timestamp o) const pure nothrow @nogc => usecs(micros_ - o.micros_);

    /// Parses the forms listed in the module comment.
    static bool fromString(scope const(char)[] s, out Timestamp v) pure nothrow @nogc
    {
        int y, mo, d, h, mi, sec;
        if (s.length < 20 || !parseYmd(s, y, mo, d) || !validYmd(y, mo, d))
            return false;
        if (s[10] != 'T' && s[10] != 't' && s[10] != ' ')
            return false;
        if (s[13] != ':' || s[16] != ':' || !digits(s[11 .. 13], h) || !digits(s[14 .. 16], mi)
            || !digits(s[17 .. 19], sec) || h > 23 || mi > 59 || sec > 59)
            return false;
        size_t i = 19;

        long frac; // microseconds, rounded half up from the digits after the sixth
        if (s[i] == '.')
        {
            immutable start = ++i;
            long scale = 100_000;
            for (; i < s.length && s[i] >= '0' && s[i] <= '9'; i++)
            {
                if (scale)
                    frac += (s[i] - '0') * scale;
                else if (i - start == 6 && s[i] >= '5')
                    frac++;
                scale /= 10;
            }
            if (i == start)
                return false;
        }

        int offset;
        if (i >= s.length)
            return false; // no offset: a local time, not an instant
        if ((s[i] == 'Z' || s[i] == 'z') && i + 1 == s.length)
            offset = 0;
        else if (s[i] == '+' || s[i] == '-')
        {
            immutable neg = s[i] == '-';
            auto o = s[i + 1 .. $];
            int oh, om, os;
            bool good;
            switch (o.length)
            {
                case 2: // ±hh
                    good = digits(o, oh);
                    break;
                case 4: // ±hhmm
                    good = digits(o[0 .. 2], oh) && digits(o[2 .. 4], om);
                    break;
                case 5: // ±hh:mm
                    good = o[2] == ':' && digits(o[0 .. 2], oh) && digits(o[3 .. 5], om);
                    break;
                case 8: // ±hh:mm:00 (Postgres prints seconds only for historical zones; other seconds do not fit)
                    good = o[2] == ':' && o[5] == ':' && digits(o[0 .. 2], oh) && digits(o[3 .. 5], om)
                        && digits(o[6 .. 8], os) && os == 0;
                    break;
                default:
                    break;
            }
            if (!good || om > 59)
                return false;
            offset = oh * 60 + om;
            if (offset > maxOffsetMinutes)
                return false;
            if (neg)
                offset = -offset;
        }
        else
            return false;

        immutable local = daysFromCivil(y, mo, d) * usPerDay + ((h * 60L + mi) * 60 + sec) * usPerSec + frac;
        immutable us = local - offset * 60L * usPerSec;
        // out of range: 9999-12-31T23:59:59.9999995 rounds into year 10000; 0001-01-01T00:00:00+01:00 is in year 0 in UTC
        if (!inRange(us, offset))
            return false;
        v.micros_ = us;
        v.offset_ = cast(short) offset;
        return true;
    }

    /// The written form described in the module comment.
    void toString(scope void delegate(scope const(char)[]) @safe sink) const
    {
        char[32] t;
        sink(t[0 .. format(t)]);
    }

    /// ditto, as a new string.
    string toString() const pure nothrow
    {
        char[32] t;
        return t[0 .. format(t)].idup;
    }

    /// Writes the text into `t` and returns its length (no allocation).
    size_t format(ref char[32] t) const pure nothrow @nogc
    {
        immutable l = local;
        immutable days = floorDiv(l, usPerDay);
        immutable inDay = l - days * usPerDay;
        int y, mo, d;
        civilFromDays(days, y, mo, d);
        char[10] ymd;
        writeYmd(ymd, y, mo, d);
        t[0 .. 10] = ymd[];
        t[10] = 'T';
        immutable secs = inDay / usPerSec;
        writeDigits(t[11 .. 13], secs / 3600);
        t[13] = ':';
        writeDigits(t[14 .. 16], secs / 60 % 60);
        t[16] = ':';
        writeDigits(t[17 .. 19], secs % 60);
        size_t n = 19;
        if (immutable us = inDay % usPerSec)
        {
            t[n] = '.';
            writeDigits(t[n + 1 .. n + 7], us);
            n += 7;
            while (t[n - 1] == '0')
                n--;
        }
        if (offset_ == 0)
            t[n++] = 'Z';
        else
        {
            immutable o = offset_ < 0 ? -offset_ : offset_;
            t[n] = offset_ < 0 ? '-' : '+';
            writeDigits(t[n + 1 .. n + 3], o / 60);
            t[n + 3] = ':';
            writeDigits(t[n + 4 .. n + 6], o % 60);
            n += 6;
        }
        return n;
    }

    /// The `std.datetime.SysTime` of the same instant, in a time zone of the same offset (`UTC()` for zero). Compiles
    /// `std.datetime` only when called.
    auto toSysTime()() const
    {
        import core.time : minutes;
        import std.datetime.systime : SysTime;
        import std.datetime.timezone : SimpleTimeZone, UTC;

        immutable std = micros_ * 10 + unixEpochHnsecs;
        if (offset_ == 0)
            return SysTime(std, UTC());
        return SysTime(std, new immutable SimpleTimeZone(minutes(offset_)));
    }

    /// The `Timestamp` of a `std.datetime.SysTime`: its instant, floored to the microsecond, written with its UTC
    /// offset in whole minutes. The time must be in years 1-9999.
    static Timestamp fromSysTime(S)(const S t)
    {
        return fromUnixMicros(floorDiv(t.stdTime - unixEpochHnsecs, 10), cast(int) t.utcOffset.total!"minutes");
    }

    private long local() const pure nothrow @nogc => micros_ + offset_ * 60L * usPerSec;
}

/// `SysTime.stdTime` (hecto-nanoseconds since 0001-01-01T00:00:00Z) of 1970-01-01T00:00:00Z.
private enum long unixEpochHnsecs = 621_355_968_000_000_000;

private long floorDiv(long a, long b) pure nothrow @nogc
{
    immutable q = a / b;
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q;
}

@safe unittest
{
    Timestamp t;
    assert(Timestamp.fromString("2026-10-19T12:00:00Z", t) && t.toString == "2026-10-19T12:00:00Z");
    assert(t.unixMicros == 1_792_411_200_000_000 && t.offsetMinutes == 0);
    assert(Timestamp.init.toString == "1970-01-01T00:00:00Z");

    // Postgres' timestamptz text and the other offset forms; the offset is kept
    assert(Timestamp.fromString("2026-10-19 12:00:00.123456+00", t) && t.toString == "2026-10-19T12:00:00.123456Z");
    assert(Timestamp.fromString("2026-10-19 17:30:00+05:30", t) && t.offsetMinutes == 330);
    assert(t.toString == "2026-10-19T17:30:00+05:30" && t.utc.toString == "2026-10-19T12:00:00Z");
    assert(Timestamp.fromString("2026-10-19t09:00:00-03", t) && t.toString == "2026-10-19T09:00:00-03:00");
    assert(Timestamp.fromString("2026-10-19T17:30:00+0530", t) && t.offsetMinutes == 330);
    assert(Timestamp.fromString("2026-10-19T12:00:00+00:00", t) && t.toString == "2026-10-19T12:00:00Z");
    assert(Timestamp.fromString("2026-10-19T12:00:00-00:00", t) && t.toString == "2026-10-19T12:00:00Z");
    assert(Timestamp.fromString("2026-10-19T12:00:00z", t) && t.offsetMinutes == 0);
    assert(Timestamp.fromString("1900-01-01 00:00:00-03:06:00", t) && t.offsetMinutes == -186);
    assert(Timestamp.fromString("2026-10-19T12:00:00+18:00", t) && Timestamp.fromString("2026-10-19T12:00:00-18", t));

    // instants and offsets
    Timestamp a, b;
    assert(Timestamp.fromString("2026-10-19T12:00:00Z", a) && Timestamp.fromString("2026-10-19T09:00:00-03:00", b));
    assert(a == b && a.offsetMinutes != b.offsetMinutes && a.toString != b.toString, "one instant, two texts");
    assert(a.withOffset(-180).toString == b.toString && b.utc.toString == a.toString);
    assert(a.toHash == b.toHash && !(a < b) && !(b < a));
    assert(b.date.toString == "2026-10-19" && Timestamp.fromString("2026-10-19T23:00:00-03:00", b));
    assert(b.date.toString == "2026-10-19" && b.utc.date.toString == "2026-10-20", "the date of the local time");

    // the fraction: omitted when zero, trailing zeros trimmed, rounded half up after six digits
    assert(Timestamp.fromString("2026-10-19T12:00:00.000Z", t) && t.toString == "2026-10-19T12:00:00Z");
    assert(Timestamp.fromString("2026-10-19T12:00:00.25Z", t) && t.toString == "2026-10-19T12:00:00.25Z");
    assert(Timestamp.fromString("2026-10-19T12:00:00.000001Z", t) && t.toString == "2026-10-19T12:00:00.000001Z");
    assert(Timestamp.fromString("2026-10-19T12:00:00.1234564Z", t) && t.toString == "2026-10-19T12:00:00.123456Z");
    assert(Timestamp.fromString("2026-10-19T12:00:00.1234565Z", t) && t.toString == "2026-10-19T12:00:00.123457Z");
    assert(Timestamp.fromString("2026-10-19T12:00:00.123456999999999Z", t) && t.toString == "2026-10-19T12:00:00.123457Z");
    assert(Timestamp.fromString("2026-12-31T23:59:59.9999995Z", t) && t.toString == "2027-01-01T00:00:00Z", "carries");
    assert(Timestamp.fromString("2026-12-31T23:59:59.9999994Z", t) && t.toString == "2026-12-31T23:59:59.999999Z");

    // leap days and the range
    assert(Timestamp.fromString("2024-02-29T00:00:00Z", t) && !Timestamp.fromString("2023-02-29T00:00:00Z", t));
    assert(Timestamp.fromString("0001-01-01T00:00:00Z", t) && Timestamp.fromString("9999-12-31T23:59:59.999999Z", t));
    assert(Timestamp.fromString("0001-01-01T00:00:00-01:00", t) && t.toString == "0001-01-01T00:00:00-01:00");
    assert(!Timestamp.fromString("0001-01-01T00:00:00+01:00", t), "year 0 in UTC");
    assert(!Timestamp.fromString("9999-12-31T23:30:00-01:00", t), "year 10000 in UTC");
    assert(!Timestamp.fromString("9999-12-31T23:59:59.9999995Z", t), "rounds into year 10000");
    assert(Timestamp.inRange(0, 0) && !Timestamp.inRange(0, 18 * 60 + 1) && !Timestamp.inRange(-62_135_596_800_000_000, -1));
    assert(Timestamp.inRange(-62_135_596_800_000_000, 1) && !Timestamp.inRange(-62_135_596_800_000_001, 0));

    foreach (bad; ["", "2026-10-19", "2026-10-19T12:00:00", "2026-10-19 12:00:00.5", "2026-10-19T12:00Z",
            "2026-10-19T24:00:00Z", "2026-10-19T12:60:00Z", "2026-10-19T12:00:60Z", "2026-10-19T12:00:00.Z",
            "2026-10-19T12:00:00+5", "2026-10-19T12:00:00+05:3", "2026-10-19T12:00:00+05:60", "2026-10-19T12:00:00+18:01",
            "2026-10-19T12:00:00+19", "2026-10-19T12:00:00+05:30:15", "2026-10-19T12:00:00Zx", "2026-10-19T12:00:00 Z",
            "2026-10-19X12:00:00Z", "infinity", "-infinity", "2026-10-19 12:00:00+00 BC", "0000-12-31T12:00:00Z",
            "2026-02-30T00:00:00Z", "2026-10-19T12:00:00,5Z", "2026-10-19T1a:00:00Z", "2026-10-19T12:00:00+0a"])
        assert(!Timestamp.fromString(bad, t), bad);

    // round trips through the text, with every offset form
    foreach (long us; [0L, 1, -1, 999_999, 1_792_411_200_123_456, -62_135_596_800_000_000, 253_402_300_799_999_999])
        foreach (off; [0, 1, -1, 330, -180, 840, -720])
        {
            if (!Timestamp.inRange(us, off))
                continue;
            auto x = Timestamp.fromUnixMicros(us, off);
            Timestamp y;
            assert(Timestamp.fromString(x.toString, y) && x == y && x.offsetMinutes == y.offsetMinutes, x.toString);
        }

    // arithmetic and order
    import core.time : hours, minutes;

    assert(Timestamp.fromString("2026-10-19T12:00:00Z", a));
    assert((a + 90.minutes).toString == "2026-10-19T13:30:00Z" && (a - 12.hours).toString == "2026-10-19T00:00:00Z");
    assert((a + 1.hours) - a == 1.hours && a < a + 1.minutes);
    assert(a.withOffset(60) == a && a.withOffset(60) < a + 1.minutes, "the offset does not change the order");
}

@safe unittest
{
    import std.datetime.date : DateTime;
    import std.datetime.systime : SysTime;
    import std.datetime.timezone : SimpleTimeZone, UTC;
    import core.time : hnsecs, minutes;
    import andaime.http.texttype : isTextType, textTypeFormat;

    static assert(isTextType!Timestamp && textTypeFormat!Timestamp == "date-time");

    Timestamp t;
    assert(Timestamp.fromString("2026-10-19T09:00:00.5-03:00", t));
    auto s = t.toSysTime;
    assert(s == SysTime(DateTime(2026, 10, 19, 12, 0, 0), 5_000_000.hnsecs, UTC()));
    assert(s.utcOffset == -180.minutes);
    assert(Timestamp.fromSysTime(s) == t);

    auto z = Timestamp.fromSysTime(SysTime(DateTime(2026, 1, 1, 12, 0, 0), 15.hnsecs, UTC()));
    assert(z.toString == "2026-01-01T12:00:00.000001Z", "hnsecs are floored to the microsecond");
    auto ist = SysTime(DateTime(2026, 1, 1, 17, 30, 0), new immutable SimpleTimeZone(330.minutes));
    assert(Timestamp.fromSysTime(ist).toString == "2026-01-01T17:30:00+05:30");
    auto old = Timestamp.fromSysTime(SysTime(DateTime(1, 1, 1, 0, 0, 0), UTC()));
    assert(old.toString == "0001-01-01T00:00:00Z" && old.toSysTime.year == 1);
}
