/// `Date` header (IMF-fixdate, RFC 9110 §5.6.7) with a one-second cache.
/// Formatting once per second per thread is cheaper than once per response.
module vela.http.date;

@safe:

import core.stdc.time : time_t, time;

/// Writes "Mon, 12 Oct 2026 21:10:00 GMT" (29 bytes) for instant `t` (Unix seconds).
void formatHttpDate(long t, ref char[29] buf) pure nothrow @nogc @safe
{
    static immutable string[7] days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    static immutable string[12] months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

    long secs = t;
    long daysSinceEpoch = secs / 86_400;
    long rem = secs % 86_400;
    if (rem < 0)
    {
        rem += 86_400;
        daysSinceEpoch--;
    }

    // Weekday: 1970-01-01 was Thursday (index 4)
    long wday = (daysSinceEpoch + 4) % 7;
    if (wday < 0)
        wday += 7;

    // Civil date from days since 1970-01-01 (H. Hinnant's algorithm)
    immutable z = daysSinceEpoch + 719_468;
    immutable era = (z >= 0 ? z : z - 146_096) / 146_097;
    immutable doe = z - era * 146_097;
    immutable yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    immutable doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    immutable mp = (5 * doy + 2) / 153;
    immutable d = doy - (153 * mp + 2) / 5 + 1;
    immutable m = mp < 10 ? mp + 3 : mp - 9;
    immutable y = yoe + era * 400 + (m <= 2 ? 1 : 0);

    void two(size_t at, long v)
    {
        buf[at] = cast(char)('0' + v / 10 % 10);
        buf[at + 1] = cast(char)('0' + v % 10);
    }

    buf[0 .. 3] = days[wday][];
    buf[3 .. 5] = ", ";
    two(5, d);
    buf[7] = ' ';
    buf[8 .. 11] = months[m - 1][];
    buf[11] = ' ';
    two(12, y / 100);
    two(14, y % 100);
    buf[16] = ' ';
    two(17, rem / 3600);
    buf[19] = ':';
    two(20, rem / 60 % 60);
    buf[22] = ':';
    two(23, rem % 60);
    buf[25 .. 29] = " GMT";
}

private char[29] cached;       // module variables are thread-local: one cache per worker
private time_t cachedAt = -1;

/// The `Date` for now. The slice is valid until the next call on this thread: use it
/// right away (`setHeader` and `writeResponseHead` happen without suspending the fiber).
const(char)[] httpDate() nothrow @nogc @trusted
{
    immutable now = time(null);
    if (now != cachedAt)
    {
        formatHttpDate(now, cached);
        cachedAt = now;
    }
    return cached[];
}

unittest
{
    char[29] b;
    formatHttpDate(0, b);
    assert(b[] == "Thu, 01 Jan 1970 00:00:00 GMT", b[].idup);
    formatHttpDate(951_782_400, b);
    assert(b[] == "Tue, 29 Feb 2000 00:00:00 GMT", b[].idup);
    formatHttpDate(1_760_303_400, b);
    assert(b[] == "Sun, 12 Oct 2025 21:10:00 GMT", b[].idup);
    formatHttpDate(1_709_164_800, b);
    assert(b[] == "Thu, 29 Feb 2024 00:00:00 GMT", b[].idup);
    assert(httpDate().length == 29 && httpDate()[$ - 4 .. $] == " GMT");
}
