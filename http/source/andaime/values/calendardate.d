/// `CalendarDate`: a day of the Gregorian calendar (`2026-10-19`), as a value: no time, no time zone. It is a text type
/// (`andaime.http.texttype`), so it works as a path or query parameter, in a form, in JSON and as a `date` column with
/// `rowsAs`, and OpenAPI says `format: date`.
///
/// Today's date needs the clock and a time zone: those are effects, so a domain takes them through a port.
/// `toDate`/`fromDate` convert to and from `std.datetime.Date`; `std.datetime` is compiled only if you call them.
module andaime.values.calendardate 2025;

@safe:

/// A date from 0001-01-01 to 9999-12-31. `CalendarDate.init` is 1970-01-01.
struct CalendarDate
{
    private int days_; // since 1970-01-01

    enum openApiFormat = "date";
    enum invalidMessage = "expected a date like 2026-10-19 (YYYY-MM-DD)";

    /// The first and last days a `CalendarDate` holds, as days since 1970-01-01.
    enum int minDays = -719_162, maxDays = 2_932_896;

    /// The date of year `y`, month `m` (1-12), day `d`; false when that day does not exist or is out of range.
    static bool fromYmd(int y, int m, int d, out CalendarDate v) pure nothrow @nogc
    {
        if (!validYmd(y, m, d))
            return false;
        v.days_ = cast(int) daysFromCivil(y, m, d);
        return true;
    }

    /// The date `days` after 1970-01-01 (negative: before it); false outside 0001-01-01 .. 9999-12-31.
    static bool fromDays(long days, out CalendarDate v) pure nothrow @nogc
    {
        if (days < minDays || days > maxDays)
            return false;
        v.days_ = cast(int) days;
        return true;
    }

    /// Days since 1970-01-01.
    int daysSinceEpoch() const pure nothrow @nogc => days_;

    /// Year, month (1-12) and day (1-31).
    void ymd(out int y, out int m, out int d) const pure nothrow @nogc
    {
        civilFromDays(days_, y, m, d);
    }

    /// ditto
    int year() const pure nothrow @nogc
    {
        int y, m, d;
        ymd(y, m, d);
        return y;
    }

    /// ditto
    int month() const pure nothrow @nogc
    {
        int y, m, d;
        ymd(y, m, d);
        return m;
    }

    /// ditto
    int day() const pure nothrow @nogc
    {
        int y, m, d;
        ymd(y, m, d);
        return d;
    }

    /// Parses `YYYY-MM-DD` (four-digit year, a day that exists: 2024-02-29 is a date, 2023-02-29 is not).
    static bool fromString(scope const(char)[] s, out CalendarDate v) pure nothrow @nogc
    {
        int y, m, d;
        if (s.length != 10 || !parseYmd(s, y, m, d))
            return false;
        return fromYmd(y, m, d, v);
    }

    /// `YYYY-MM-DD`.
    void toString(scope void delegate(scope const(char)[]) @safe sink) const
    {
        char[10] t = text();
        sink(t[]);
    }

    /// ditto, as a new string.
    string toString() const pure nothrow
    {
        char[10] t = text();
        return t[].idup;
    }

    /// `YYYY-MM-DD` in a fixed buffer (no allocation).
    char[10] text() const pure nothrow @nogc
    {
        char[10] t;
        int y, m, d;
        ymd(y, m, d);
        writeYmd(t, y, m, d);
        return t;
    }

    /// Calendar order.
    int opCmp(const CalendarDate o) const pure nothrow @nogc => days_ < o.days_ ? -1 : days_ > o.days_;

    /// The `std.datetime.Date` of the same day (compiles `std.datetime` only when called).
    auto toDate()() const
    {
        import std.datetime.date : Date;

        int y, m, d;
        ymd(y, m, d);
        return Date(y, m, d);
    }

    /// The `CalendarDate` of a `std.datetime.Date` (or anything with `year`, `month` and `day`); false when its year is
    /// outside 1-9999.
    static bool fromDate(D)(const D date, out CalendarDate v)
    {
        return fromYmd(date.year, cast(int) date.month, date.day, v);
    }
}

// ---------------------------------------------------------------- calendar arithmetic (shared with `Timestamp`)

/// True if year `y` is a Gregorian leap year.
package bool isLeapYear(int y) pure nothrow @nogc => (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;

/// Days in month `m` (1-12) of year `y`.
package int daysInMonth(int y, int m) pure nothrow @nogc
{
    static immutable ubyte[12] len = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    return m == 2 && isLeapYear(y) ? 29 : len[m - 1];
}

/// True for a day that exists, from 0001-01-01 to 9999-12-31.
package bool validYmd(int y, int m, int d) pure nothrow @nogc
    => y >= 1 && y <= 9999 && m >= 1 && m <= 12 && d >= 1 && d <= daysInMonth(y, m);

/// Days since 1970-01-01 of a valid date (H. Hinnant's algorithm, as in `andaime.http.date`).
package long daysFromCivil(int year, int m, int d) pure nothrow @nogc
{
    long y = m <= 2 ? year - 1 : year;
    immutable era = (y >= 0 ? y : y - 399) / 400;
    immutable yoe = y - era * 400;
    immutable doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
    immutable doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146_097 + doe - 719_468;
}

/// The date `days` after 1970-01-01.
package void civilFromDays(long days, out int y, out int m, out int d) pure nothrow @nogc
{
    immutable z = days + 719_468;
    immutable era = (z >= 0 ? z : z - 146_096) / 146_097;
    immutable doe = z - era * 146_097;
    immutable yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    immutable doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    immutable mp = (5 * doy + 2) / 153;
    d = cast(int)(doy - (153 * mp + 2) / 5 + 1);
    m = cast(int)(mp < 10 ? mp + 3 : mp - 9);
    y = cast(int)(yoe + era * 400 + (m <= 2 ? 1 : 0));
}

/// Reads `YYYY-MM-DD` from the first 10 characters of `s` (digits and dashes only; the day is not checked).
package bool parseYmd(scope const(char)[] s, out int y, out int m, out int d) pure nothrow @nogc
{
    if (s.length < 10 || s[4] != '-' || s[7] != '-')
        return false;
    return digits(s[0 .. 4], y) && digits(s[5 .. 7], m) && digits(s[8 .. 10], d);
}

/// Writes `YYYY-MM-DD` into `t[0 .. 10]`.
package void writeYmd(ref char[10] t, int y, int m, int d) pure nothrow @nogc
{
    writeDigits(t[0 .. 4], y);
    t[4] = '-';
    writeDigits(t[5 .. 7], m);
    t[7] = '-';
    writeDigits(t[8 .. 10], d);
}

/// The value of an all-digit field.
package bool digits(scope const(char)[] s, out int v) pure nothrow @nogc
{
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            return false;
        v = v * 10 + (c - '0');
    }
    return true;
}

/// `v` as zero-padded digits filling `t`.
package void writeDigits(scope char[] t, long v) pure nothrow @nogc
{
    foreach_reverse (ref c; t)
    {
        c = cast(char)('0' + v % 10);
        v /= 10;
    }
}

@safe unittest
{
    CalendarDate d;
    assert(CalendarDate.fromString("2026-10-19", d) && d.toString == "2026-10-19");
    assert(d.year == 2026 && d.month == 10 && d.day == 19);
    assert(CalendarDate.init.toString == "1970-01-01" && CalendarDate.init.daysSinceEpoch == 0);

    // leap days
    assert(CalendarDate.fromString("2024-02-29", d) && d.toString == "2024-02-29");
    assert(CalendarDate.fromString("2000-02-29", d), "divisible by 400: leap");
    assert(!CalendarDate.fromString("2023-02-29", d) && !CalendarDate.fromString("1900-02-29", d), "1900: not leap");
    assert(!CalendarDate.fromString("2024-02-30", d) && !CalendarDate.fromString("2024-04-31", d));

    // the range
    assert(CalendarDate.fromString("0001-01-01", d) && d.daysSinceEpoch == CalendarDate.minDays);
    assert(CalendarDate.fromString("9999-12-31", d) && d.daysSinceEpoch == CalendarDate.maxDays);
    assert(!CalendarDate.fromString("0000-12-31", d));
    assert(!CalendarDate.fromDays(CalendarDate.maxDays + 1, d) && !CalendarDate.fromDays(CalendarDate.minDays - 1, d));

    foreach (bad; ["", "2026-1-19", "2026-10-1", "2026/10/19", "2026-10-19 ", " 2026-10-19", "2026-13-01",
            "2026-00-10", "2026-10-00", "20261019", "+2026-10-19", "2026-10-1x", "２026-10-19"])
        assert(!CalendarDate.fromString(bad, d), bad);

    // every day of four centuries round-trips through its text
    for (long n = -150_000; n < 150_000; n += 7)
    {
        CalendarDate a, b;
        assert(CalendarDate.fromDays(n, a));
        assert(CalendarDate.fromString(a.text()[], b) && a == b && b.daysSinceEpoch == n);
    }

    CalendarDate x, y;
    assert(CalendarDate.fromYmd(2026, 1, 31, x) && CalendarDate.fromYmd(2026, 2, 1, y));
    assert(x < y && y.daysSinceEpoch - x.daysSinceEpoch == 1);
}

@safe unittest
{
    import std.datetime.date : Date;
    import andaime.http.texttype : isTextType, textTypeFormat;

    static assert(isTextType!CalendarDate && textTypeFormat!CalendarDate == "date");
    CalendarDate d;
    assert(CalendarDate.fromString("2024-02-29", d));
    assert(d.toDate == Date(2024, 2, 29));
    CalendarDate e;
    assert(CalendarDate.fromDate(Date(1999, 12, 31), e) && e.toString == "1999-12-31");
}
