/// Five-field cron expressions and `@Every` period windows.
///
/// A field is `*`, a number, a comma list, a range (`n-m`), or a step (`*/n`, `n/n`, `n-m/n`).
/// Values have to fall in the field: minute 0-59, hour 0-23, day-of-month 1-31, month 1-12,
/// day-of-week 0-7 (0 and 7 are Sunday). Names and `?` are rejected. `cronError` is the
/// compile-time check; `parseCron` is the same check plus the bitset.
///
/// When both day-of-month and day-of-week are restricted (neither field is a bare `*`), a date
/// matches if either field matches. A bare `*` on either field means "every" and the other field
/// decides. The slot is the start of that civil minute in the `SysTime`'s time zone.
module andaime.jobs.cron;

@safe:

import core.time : Duration;
import std.datetime.systime : SysTime;

private enum string cronBadToken =
    "andaime.jobs: invalid @Cron: a field must be *, a number, a list, a range or a step";
private enum string cronBadCount =
    "andaime.jobs: invalid @Cron: expected 5 fields (minute hour day-of-month month day-of-week)";
private enum string cronBadRange = "andaime.jobs: invalid @Cron: a range must run from low to high";
private enum string cronBadStep = "andaime.jobs: invalid @Cron: a step must be at least 1";

private enum long hnsecPerMin = 60L * 10_000_000L;
private enum long hnsecPerDay = 24L * 60L * hnsecPerMin;
private enum int horizonYears = 8;

// =====================================================================
// Bitset
// =====================================================================

/// Parsed cron. Each bit is one accepted value. Bit 0 of `dayOfMonth` and `month` is unused.
/// Day-of-week bit 0 is Sunday; a written 7 sets that bit too. `dayOfMonthStar` / `dayOfWeekStar`
/// are true only for a bare `*` (not `*/n` and not a list).
struct CronExpr
{
    ulong minute; /// bits 0-59
    uint hour; /// bits 0-23
    uint dayOfMonth; /// bits 1-31
    ushort month; /// bits 1-12
    ubyte dayOfWeek; /// bits 0-6, Sunday = 0
    bool dayOfMonthStar;
    bool dayOfWeekStar;
}

// =====================================================================
// Parser
// =====================================================================

private bool isCronSpace(char c) @safe pure nothrow @nogc
{
    return c == ' ' || c == '\t';
}

private bool isCronDigit(char c) @safe pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

private string rangeMsg(int field) @safe pure nothrow @nogc
{
    switch (field)
    {
    case 0:
        return "andaime.jobs: invalid @Cron: minute must be 0-59";
    case 1:
        return "andaime.jobs: invalid @Cron: hour must be 0-23";
    case 2:
        return "andaime.jobs: invalid @Cron: day-of-month must be 1-31";
    case 3:
        return "andaime.jobs: invalid @Cron: month must be 1-12";
    default:
        return "andaime.jobs: invalid @Cron: day-of-week must be 0-7";
    }
}

private void fieldBounds(int field, out int lo, out int hi) @safe pure nothrow @nogc
{
    switch (field)
    {
    case 0:
        lo = 0;
        hi = 59;
        break;
    case 1:
        lo = 0;
        hi = 23;
        break;
    case 2:
        lo = 1;
        hi = 31;
        break;
    case 3:
        lo = 1;
        hi = 12;
        break;
    default:
        lo = 0;
        hi = 7;
        break;
    }
}

private enum NumKind : ubyte
{
    none,
    ok,
    big,
}

/// Digits into `value`, which is never above `limit`. `big` means the digits did not fit.
private NumKind readDigits(scope const(char)[] s, ref size_t i, out int value, int limit) @safe pure nothrow @nogc
{
    if (i >= s.length || !isCronDigit(s[i]))
        return NumKind.none;
    long acc = 0;
    bool big = false;
    while (i < s.length && isCronDigit(s[i]))
    {
        int d = s[i] - '0';
        i++;
        if (big)
            continue;
        if (acc > limit / 10 || (acc == limit / 10 && d > limit % 10))
            big = true;
        else
            acc = acc * 10 + d;
    }
    if (big)
    {
        value = limit;
        return NumKind.big;
    }
    value = cast(int) acc;
    return NumKind.ok;
}

private string readBound(scope const(char)[] s, ref size_t i, int field, int lo, int hi, out int value)
    @safe pure nothrow @nogc
{
    auto kind = readDigits(s, i, value, hi);
    if (kind == NumKind.none)
        return cronBadToken;
    if (kind == NumKind.big || value < lo)
        return rangeMsg(field);
    return "";
}

private string readStep(scope const(char)[] s, ref size_t i, out int step) @safe pure nothrow @nogc
{
    auto kind = readDigits(s, i, step, int.max);
    if (kind == NumKind.none)
        return cronBadToken;
    if (kind == NumKind.big)
        step = int.max;
    if (step < 1)
        return cronBadStep;
    return "";
}

private void setValue(ref ulong bits, int field, int v) @safe pure nothrow @nogc
{
    if (field == 4 && v == 7)
        v = 0;
    bits |= 1UL << v;
}

private void fillStep(ref ulong bits, int field, int start, int end, int step) @safe pure nothrow @nogc
{
    int v = start;
    while (v <= end)
    {
        setValue(bits, field, v);
        if (step > end - v)
            break;
        v += step;
    }
}

private string parseItem(scope const(char)[] s, ref size_t i, int field, int lo, int hi,
    ref ulong bits, out bool bareStar) @safe pure nothrow @nogc
{
    bareStar = false;
    if (i >= s.length)
        return cronBadToken;
    if (s[i] == '*')
    {
        i++;
        if (i < s.length && s[i] == '/')
        {
            i++;
            int step;
            string err = readStep(s, i, step);
            if (err.length)
                return err;
            fillStep(bits, field, lo, hi, step);
            return "";
        }
        fillStep(bits, field, lo, hi, 1);
        bareStar = true;
        return "";
    }
    int n;
    string err = readBound(s, i, field, lo, hi, n);
    if (err.length)
        return err;
    if (i < s.length && s[i] == '-')
    {
        i++;
        int m;
        err = readBound(s, i, field, lo, hi, m);
        if (err.length)
            return err;
        int step = 1;
        if (i < s.length && s[i] == '/')
        {
            i++;
            err = readStep(s, i, step);
            if (err.length)
                return err;
        }
        if (n > m)
            return cronBadRange;
        fillStep(bits, field, n, m, step);
        return "";
    }
    if (i < s.length && s[i] == '/')
    {
        i++;
        int step;
        err = readStep(s, i, step);
        if (err.length)
            return err;
        fillStep(bits, field, n, hi, step);
        return "";
    }
    setValue(bits, field, n);
    return "";
}

private string parseField(scope const(char)[] s, ref size_t i, int field, out ulong bits, out bool star)
    @safe pure nothrow @nogc
{
    bits = 0;
    star = false;
    int lo, hi;
    fieldBounds(field, lo, hi);
    bool bareStar;
    string err = parseItem(s, i, field, lo, hi, bits, bareStar);
    if (err.length)
        return err;
    if (i < s.length && s[i] == ',')
        bareStar = false;
    while (i < s.length && s[i] == ',')
    {
        i++;
        bool ignored;
        err = parseItem(s, i, field, lo, hi, bits, ignored);
        if (err.length)
            return err;
    }
    star = bareStar;
    return "";
}

/// `""` when `expr` is five in-range fields. Otherwise one `andaime.jobs:` line.
/// `job.d` strips the `andaime.jobs: invalid @Cron: ` prefix.
string cronError(scope const(char)[] expr) @safe pure nothrow @nogc
{
    CronExpr parsed;
    return parseCron(expr, parsed);
}

/// Parses `expr` into bitsets. Returns `""` on success. On failure `parsed` stays `CronExpr.init`
/// and the result is the same line `cronError` returns.
string parseCron(scope const(char)[] expr, out CronExpr parsed) @safe pure nothrow @nogc
{
    size_t i = 0;
    ulong[5] bits;
    bool[5] star;
    int fields = 0;
    while (i < expr.length)
    {
        while (i < expr.length && isCronSpace(expr[i]))
            i++;
        if (i == expr.length)
            break;
        if (fields == 5)
        {
            // One field too many. A name or `?` is still a bad token; anything else is the count.
            ulong extra;
            bool extraStar;
            string extraErr = parseField(expr, i, 0, extra, extraStar);
            if (extraErr == cronBadToken)
                return cronBadToken;
            if (extraErr.length == 0 && i < expr.length && !isCronSpace(expr[i]))
                return cronBadToken;
            return cronBadCount;
        }
        string err = parseField(expr, i, fields, bits[fields], star[fields]);
        if (err.length)
            return err;
        fields++;
        if (i < expr.length && !isCronSpace(expr[i]))
            return cronBadToken;
    }
    if (fields != 5)
        return cronBadCount;
    parsed.minute = bits[0];
    parsed.hour = cast(uint) bits[1];
    parsed.dayOfMonth = cast(uint) bits[2];
    parsed.month = cast(ushort) bits[3];
    parsed.dayOfWeek = cast(ubyte) bits[4];
    parsed.dayOfMonthStar = star[2];
    parsed.dayOfWeekStar = star[4];
    return "";
}

// =====================================================================
// Civil time (proleptic Gregorian, hnsecs since 0001-01-01)
// =====================================================================

private struct Civil
{
    short year;
    ubyte month = 1;
    ubyte day = 1;
    ubyte hour;
    ubyte minute;
}

private bool isLeap(int year) @safe pure nothrow @nogc
{
    return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}

private int daysInMonth(int year, int month) @safe pure nothrow @nogc
{
    static immutable ubyte[12] dim = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if (month == 2 && isLeap(year))
        return 29;
    return dim[month - 1];
}

/// Days since 1970-01-01 (Howard Hinnant).
private int daysFromCivil(int y, int m, int d) @safe pure nothrow @nogc
{
    y -= m <= 2;
    int era = (y >= 0 ? y : y - 399) / 400;
    uint yoe = cast(uint)(y - era * 400);
    uint doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    uint doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + cast(int) doe - 719468;
}

/// `dayIndex` 0 is 0001-01-01.
private void civilFromDays(long dayIndex, out int y, out int m, out int d) @safe pure nothrow @nogc
{
    int z = cast(int) dayIndex - 719162;
    z += 719468;
    int era = (z >= 0 ? z : z - 146096) / 146097;
    uint doe = cast(uint)(z - era * 146097);
    uint yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    int year = cast(int) yoe + era * 400;
    uint doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    uint mp = (5 * doy + 2) / 153;
    d = cast(int)(doy - (153 * mp + 2) / 5 + 1);
    m = cast(int)(mp < 10 ? mp + 3 : mp - 9);
    y = year + (m <= 2 ? 1 : 0);
}

private long floorToMinute(long hnsecs) @safe pure nothrow @nogc
{
    long r = hnsecs % hnsecPerMin;
    if (r < 0)
        r += hnsecPerMin;
    return hnsecs - r;
}

private long civilToHnsecs(Civil c) @safe pure nothrow @nogc
{
    long dayIndex = daysFromCivil(c.year, c.month, c.day) + 719162L;
    return dayIndex * hnsecPerDay + (c.hour * 60L + c.minute) * hnsecPerMin;
}

private Civil civilFromHnsecs(long hnsecs) @safe pure nothrow @nogc
{
    long day = hnsecs / hnsecPerDay;
    long rem = hnsecs % hnsecPerDay;
    if (rem < 0)
    {
        rem += hnsecPerDay;
        day--;
    }
    int y, m, d;
    civilFromDays(day, y, m, d);
    int mins = cast(int)(rem / hnsecPerMin);
    Civil c;
    c.year = cast(short) y;
    c.month = cast(ubyte) m;
    c.day = cast(ubyte) d;
    c.hour = cast(ubyte)(mins / 60);
    c.minute = cast(ubyte)(mins % 60);
    return c;
}

/// Sunday is 0. 0001-01-01 is Monday.
private int weekDay(Civil c) @safe pure nothrow @nogc
{
    long dayIndex = daysFromCivil(c.year, c.month, c.day) + 719162L;
    int m = cast(int)((dayIndex + 1) % 7);
    if (m < 0)
        m += 7;
    return m;
}

private bool dayMatches(const CronExpr expr, Civil c) @safe pure nothrow @nogc
{
    bool dom = (expr.dayOfMonth & (1U << c.day)) != 0;
    bool dow = (expr.dayOfWeek & (1U << weekDay(c))) != 0;
    if (expr.dayOfMonthStar && expr.dayOfWeekStar)
        return true;
    if (expr.dayOfMonthStar)
        return dow;
    if (expr.dayOfWeekStar)
        return dom;
    return dom || dow;
}

private bool fieldsMatch(const CronExpr expr, Civil c) @safe pure nothrow @nogc
{
    if (expr.minute == 0 || expr.hour == 0 || expr.month == 0)
        return false;
    if ((expr.minute & (1UL << c.minute)) == 0)
        return false;
    if ((expr.hour & (1U << c.hour)) == 0)
        return false;
    if ((expr.month & (1U << c.month)) == 0)
        return false;
    return dayMatches(expr, c);
}

private int nextBit(ulong bits, int from, int hi) @safe pure nothrow @nogc
{
    for (int v = from; v <= hi; v++)
        if ((bits & (1UL << v)) != 0)
            return v;
    return -1;
}

private bool incMonth(ref Civil c) @safe pure nothrow @nogc
{
    c.day = 1;
    c.hour = 0;
    c.minute = 0;
    if (c.month < 12)
    {
        c.month++;
        return c.year <= 9999;
    }
    if (c.year >= 9999)
        return false;
    c.month = 1;
    c.year++;
    return true;
}

private bool incDay(ref Civil c) @safe pure nothrow @nogc
{
    c.hour = 0;
    c.minute = 0;
    if (c.day < daysInMonth(c.year, c.month))
    {
        c.day++;
        return true;
    }
    return incMonth(c);
}

private bool incHour(ref Civil c) @safe pure nothrow @nogc
{
    c.minute = 0;
    if (c.hour < 23)
    {
        c.hour++;
        return true;
    }
    c.hour = 0;
    return incDay(c);
}

private bool incMinute(ref Civil c) @safe pure nothrow @nogc
{
    if (c.minute < 59)
    {
        c.minute++;
        return true;
    }
    return incHour(c);
}

private bool advanceMonth(ref Civil c, ushort monthBits) @safe pure nothrow @nogc
{
    foreach (_; 0 .. horizonYears * 12 + 2)
    {
        if (!incMonth(c))
            return false;
        if ((monthBits & (1U << c.month)) != 0)
            return true;
    }
    return false;
}

private long localHnsecs(SysTime t) @safe nothrow
{
    auto tz = t.timezone;
    if (tz is null)
        return t.stdTime;
    return tz.utcToTZ(t.stdTime);
}

/// Earliest UTC instant of this civil minute that is strictly after `after`.
/// A minute skipped by a DST gap does not match. A repeated local minute checks the
/// time zone's conversion and that instant plus one hour.
private bool instantAfter(Civil c, SysTime after, out long utc) @safe nothrow
{
    long local = civilToHnsecs(c);
    long minute = floorToMinute(local);
    auto tz = after.timezone;
    long guess = tz is null ? local : tz.tzToUTC(local);
    if (matchesMinute(guess, minute, after))
    {
        utc = guess;
        return true;
    }
    long later = guess + 60L * hnsecPerMin;
    if (matchesMinute(later, minute, after))
    {
        utc = later;
        return true;
    }
    return false;
}

private bool matchesMinute(long utc, long localMinute, SysTime after) @safe nothrow
{
    if (utc <= after.stdTime)
        return false;
    auto tz = after.timezone;
    long seen = tz is null ? utc : tz.utcToTZ(utc);
    return floorToMinute(seen) == localMinute;
}

// =====================================================================
// Slots
// =====================================================================

/// Next civil minute matched by `expr`, strictly after `after`, in `after`'s time zone.
/// Returns false when nothing matches in the next eight years (February 31, for example).
/// Eight years covers the longest Gregorian gap between February 29s.
///
/// Not `@nogc`: `SysTime.stdTime` and `TimeZone.utcToTZ` are not `@nogc` on DMD 2.109.
/// The function only writes `slot`.
bool nextSlot(const CronExpr expr, SysTime after, out SysTime slot) @safe nothrow
{
    if (expr.minute == 0 || expr.hour == 0 || expr.month == 0)
        return false;
    Civil c = civilFromHnsecs(localHnsecs(after));
    if (!incMinute(c))
        return false;
    int startYear = c.year;
    foreach (_; 0 .. 20_000)
    {
        if (c.year > startYear + horizonYears || c.year > 9999)
            return false;
        if ((expr.month & (1U << c.month)) == 0)
        {
            if (!advanceMonth(c, expr.month))
                return false;
            continue;
        }
        if (!dayMatches(expr, c))
        {
            if (!incDay(c))
                return false;
            continue;
        }
        if ((expr.hour & (1U << c.hour)) == 0)
        {
            int h = nextBit(expr.hour, c.hour, 23);
            if (h < 0)
            {
                c.hour = 0;
                c.minute = 0;
                if (!incDay(c))
                    return false;
            }
            else
            {
                c.hour = cast(ubyte) h;
                c.minute = 0;
            }
            continue;
        }
        if ((expr.minute & (1UL << c.minute)) == 0)
        {
            int m = nextBit(expr.minute, c.minute, 59);
            if (m < 0)
            {
                if (!incHour(c))
                    return false;
            }
            else
                c.minute = cast(ubyte) m;
            continue;
        }
        long utc;
        if (instantAfter(c, after, utc))
        {
            slot.timezone = after.timezone;
            slot.stdTime = utc;
            return true;
        }
        if (!incMinute(c))
            return false;
    }
    return false;
}

/// The minute that contains `now`, when that minute matches `expr`. `slot` is the start of it.
bool cronSlot(const CronExpr expr, SysTime now, out SysTime slot) @safe nothrow
{
    long local = localHnsecs(now);
    Civil c = civilFromHnsecs(local);
    if (!fieldsMatch(expr, c))
        return false;
    long start = floorToMinute(local);
    slot.timezone = now.timezone;
    slot.stdTime = now.stdTime - (local - start);
    return true;
}

/// Start of the period window that contains `now` (floor). Windows are `period` long, aligned to
/// 0001-01-01T00:00:00Z. A period that divides one day therefore falls on UTC clock boundaries.
/// `period` must be positive; `job.d` already rejects the rest.
SysTime slotStart(SysTime now, Duration period) @safe pure nothrow
{
    long p = period.total!"hnsecs";
    long t = now.stdTime;
    long r = t % p;
    if (r < 0)
        r += p;
    now.stdTime = t - r;
    return now;
}

/// The next period boundary strictly after `now` (`slotStart` plus one `period`).
SysTime nextSlotStart(SysTime now, Duration period) @safe pure nothrow
{
    SysTime start = slotStart(now, period);
    start.stdTime = start.stdTime + period.total!"hnsecs";
    return start;
}

// =====================================================================
// Which schedules fire
// =====================================================================

/// One cron expression, one `@Every` period, or both. An empty `cronExpr` is not cron.
/// `Duration.zero` is not `@Every`.
struct ScheduledJob
{
    string jobName;
    string cronExpr;
    Duration every;
}

/// Which half of a `ScheduledJob` produced `slot`.
enum ScheduleKind : ubyte
{
    cron,
    every,
}

/// A firing the runner can enqueue. Identity is `(jobName, kind, slot.stdTime)`.
struct ScheduledFire
{
    string jobName;
    SysTime slot;
    ScheduleKind kind;
}

/// Writes each slot of `job` that is due at `now` (up to two: the cron minute and the `@Every`
/// window). The same absolute instant is written once. Returns how many were due, including
/// any that did not fit in `fired`.
size_t dueFires(ScheduledJob job, SysTime now, scope ScheduledFire[] fired) @safe nothrow
{
    size_t n = 0;
    bool haveCron = false;
    long cronStd = 0;
    if (job.cronExpr.length)
    {
        CronExpr expr;
        SysTime at;
        if (parseCron(job.cronExpr, expr).length == 0 && cronSlot(expr, now, at))
        {
            haveCron = true;
            cronStd = at.stdTime;
            if (n < fired.length)
                fired[n] = ScheduledFire(job.jobName, at, ScheduleKind.cron);
            n++;
        }
    }
    if (job.every > Duration.zero)
    {
        SysTime at = slotStart(now, job.every);
        if (!(haveCron && at.stdTime == cronStd))
        {
            if (n < fired.length)
                fired[n] = ScheduledFire(job.jobName, at, ScheduleKind.every);
            n++;
        }
    }
    return n;
}

/// True when `job` has at least one slot due at `now`. `slot` is the cron minute when that
/// minute matches, otherwise the `@Every` window. A job with both can also have a second slot;
/// `dueFires` reports it.
bool due(ScheduledJob job, SysTime now, out SysTime slot) @safe nothrow
{
    ScheduledFire[2] buf;
    if (dueFires(job, now, buf[]) == 0)
        return false;
    slot = buf[0].slot;
    return true;
}

/// True when this process has not yet enqueued `slot`. Compare one seen instant per
/// `(jobName, kind)`; a repeated `stdTime` is the same firing.
bool slotUnseen(bool haveSeen, SysTime seen, SysTime slot) @safe pure nothrow @nogc
{
    return !haveSeen || seen.stdTime != slot.stdTime;
}

/// In-memory cron. `tick` does not enqueue; the store records each `slotUnseen` result.
struct CronClock
{
    /// Fires due at `now`. Pass two entries per job. The return value counts fires that did not
    /// fit as well as fires written to `fired`.
    static size_t tick(scope const(ScheduledJob)[] jobs, SysTime now, scope ScheduledFire[] fired) @safe nothrow
    {
        size_t n = 0;
        foreach (job; jobs)
        {
            ScheduledFire[2] buf;
            size_t c = dueFires(job, now, buf[]);
            foreach (k; 0 .. c)
            {
                if (n < fired.length)
                    fired[n] = buf[k];
                n++;
            }
        }
        return n;
    }
}

// =====================================================================
// Tests
// =====================================================================

version (unittest)
{
    import core.time : minutes, seconds;
    import std.datetime.date : DateTime, DayOfWeek;
    import std.datetime.timezone : UTC;

    private SysTime atTime(int y, int mo, int d, int h = 0, int mi = 0, int s = 0)
    {
        return SysTime(DateTime(y, mo, d, h, mi, s), UTC());
    }

    private void expectNext(string expr, SysTime after, SysTime want)
    {
        CronExpr parsed;
        assert(parseCron(expr, parsed) == "");
        SysTime slot;
        assert(nextSlot(parsed, after, slot));
        assert(slot == want);
        assert(slot.timezone is after.timezone);
    }
}

unittest
{
    enum badCount = "andaime.jobs: invalid @Cron: expected 5 fields (minute hour day-of-month month day-of-week)";
    enum badToken = "andaime.jobs: invalid @Cron: a field must be *, a number, a list, a range or a step";
    enum badMinute = "andaime.jobs: invalid @Cron: minute must be 0-59";
    enum badHour = "andaime.jobs: invalid @Cron: hour must be 0-23";
    enum badDom = "andaime.jobs: invalid @Cron: day-of-month must be 1-31";
    enum badMonth = "andaime.jobs: invalid @Cron: month must be 1-12";
    enum badDow = "andaime.jobs: invalid @Cron: day-of-week must be 0-7";

    assert(cronError("* * * * *") == "");
    assert(cronError("  * \t *   * * * ") == "");
    assert(cronError("*/15 0 1,15 1-12 0-6") == "");
    assert(cronError("1-10/2 * * * *") == "");
    assert(cronError("5/10 * * * *") == "");
    assert(cronError("1,2,5-10,*/2 * * * *") == "");
    assert(cronError("0-59 0-23 1-31 1-12 0-7") == "");
    assert(cronError("59 23 31 12 7") == "");

    assert(cronError("99 99 99 99 99") == badMinute);
    assert(cronError("0 99 1 1 0") == badHour);
    assert(cronError("0 0 0 1 0") == badDom);
    assert(cronError("0 0 99 1 0") == badDom);
    assert(cronError("0 0 1 0 0") == badMonth);
    assert(cronError("0 0 1 13 0") == badMonth);
    assert(cronError("0 0 1 1 8") == badDow);
    assert(cronError("60 * * * *") == badMinute);
    assert(cronError("0-60 * * * *") == badMinute);
    assert(cronError("10-5 * * * *") == cronBadRange);
    assert(cronError("*/0 * * * *") == cronBadStep);
    assert(cronError("1-5/0 * * * *") == cronBadStep);

    assert(cronError("") == badCount);
    assert(cronError("   ") == badCount);
    assert(cronError("* * * *") == badCount);
    assert(cronError("1 2 3") == badCount);
    assert(cronError("* * * * * *") == badCount);
    assert(cronError("* * * * * MON") == badToken);
    assert(cronError("* * * * * *foo") == badToken);
    assert(cronError("* * * * * 99") == badCount);

    assert(cronError("a * * * *") == badToken);
    assert(cronError("* * * * MON") == badToken);
    assert(cronError("* * * JAN *") == badToken);
    assert(cronError("1, * * * *") == badToken);
    assert(cronError("*/ * * * *") == badToken);
    assert(cronError("1- * * * *") == badToken);
    assert(cronError("? * * * *") == badToken);
    assert(cronError("* * * * 1,") == badToken);

    CronExpr junk;
    assert(parseCron("99 99 99 99 99", junk) == badMinute);
    assert(junk == CronExpr.init);
}

unittest
{
    CronExpr e;
    assert(parseCron("1,15,45 0 1,15 * 1-5", e) == "");
    assert(e.minute == ((1UL << 1) | (1UL << 15) | (1UL << 45)));
    assert(e.hour == 1U);
    assert(e.dayOfMonth == ((1U << 1) | (1U << 15)));
    assert(!e.dayOfMonthStar);
    assert(e.month == 0x1FFE);
    assert(!e.dayOfWeekStar);
    assert(e.dayOfWeek == ((1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5)));

    assert(parseCron("1-10/2 * * * *", e) == "");
    assert(e.minute == ((1UL << 1) | (1UL << 3) | (1UL << 5) | (1UL << 7) | (1UL << 9)));

    assert(parseCron("5/10 * * * *", e) == "");
    assert(e.minute == ((1UL << 5) | (1UL << 15) | (1UL << 25) | (1UL << 35) | (1UL << 45) | (1UL << 55)));

    assert(parseCron("*/15 * * * *", e) == "");
    assert(e.minute == ((1UL << 0) | (1UL << 15) | (1UL << 30) | (1UL << 45)));
    assert(e.dayOfMonthStar);

    assert(parseCron("* * * * *", e) == "");
    assert(e.minute == (1UL << 60) - 1);
    assert(e.hour == (1U << 24) - 1);
    assert(e.dayOfMonth == 0xFFFF_FFFE);
    assert(e.month == 0x1FFE);
    assert(e.dayOfWeek == 0b0111_1111);
    assert(e.dayOfMonthStar && e.dayOfWeekStar);

    assert(parseCron("0 0 * * 7", e) == "");
    assert(e.dayOfWeek == 0b0000_0001);
    assert(!e.dayOfWeekStar);
    assert(parseCron("0 0 * * 0,7", e) == "");
    assert(e.dayOfWeek == 0b0000_0001);
    assert(parseCron("0 0 * * 5-7", e) == "");
    assert(e.dayOfWeek == 0b0110_0001);
}

unittest
{
    auto noon = atTime(1, 1, 1);
    assert(noon.stdTime == 0);
    assert(weekDay(civilFromHnsecs(0)) == 1);

    foreach (y; [1, 1970, 1900, 2000, 2023, 2024, 2028, 9999])
    {
        foreach (mo; [1, 2, 4, 12])
        {
            int last = mo == 2 ? (isLeap(y) ? 29 : 28) : (mo == 4 ? 30 : 31);
            if (y == 1900 && mo == 2)
                assert(last == 28);
            if (y == 2000 && mo == 2)
                assert(last == 29);
            foreach (d; [1, last])
            {
                auto st = atTime(y, mo, d, 23, 59, 58);
                Civil c = civilFromHnsecs(st.stdTime);
                assert(c.year == y && c.month == mo && c.day == d && c.hour == 23 && c.minute == 59);
                assert(civilToHnsecs(c) + 58L * 10_000_000L == st.stdTime);
                assert(weekDay(c) == cast(int) DateTime(y, mo, d).dayOfWeek);
            }
        }
    }
    assert(DateTime(2024, 6, 16).dayOfWeek == DayOfWeek.sun);
    assert(DateTime(1970, 1, 1).dayOfWeek == DayOfWeek.thu);
}

unittest
{
    // List.
    expectNext("1,15,45 * * * *", atTime(2024, 6, 15, 10, 0), atTime(2024, 6, 15, 10, 1));
    expectNext("1,15,45 * * * *", atTime(2024, 6, 15, 10, 1), atTime(2024, 6, 15, 10, 15));
    expectNext("1,15,45 * * * *", atTime(2024, 6, 15, 10, 15), atTime(2024, 6, 15, 10, 45));
    expectNext("1,15,45 * * * *", atTime(2024, 6, 15, 10, 46), atTime(2024, 6, 15, 11, 1));

    // Range.
    expectNext("0 9-17 * * *", atTime(2024, 6, 15, 8, 30), atTime(2024, 6, 15, 9, 0));
    expectNext("0 9-17 * * *", atTime(2024, 6, 15, 12, 15), atTime(2024, 6, 15, 13, 0));
    expectNext("0 9-17 * * *", atTime(2024, 6, 15, 17, 0), atTime(2024, 6, 16, 9, 0));

    // Step.
    expectNext("*/15 * * * *", atTime(2024, 6, 15, 10, 0), atTime(2024, 6, 15, 10, 15));
    expectNext("*/15 * * * *", atTime(2024, 6, 15, 10, 14, 59), atTime(2024, 6, 15, 10, 15));
    expectNext("*/15 * * * *", atTime(2024, 6, 15, 10, 46), atTime(2024, 6, 15, 11, 0));
    expectNext("1-10/2 * * * *", atTime(2024, 6, 15, 10, 4), atTime(2024, 6, 15, 10, 5));
    expectNext("5/10 * * * *", atTime(2024, 6, 15, 10, 55), atTime(2024, 6, 15, 11, 5));

    // Star, including the year boundary.
    expectNext("* * * * *", atTime(2024, 6, 15, 10, 15), atTime(2024, 6, 15, 10, 16));
    expectNext("* * * * *", atTime(2024, 6, 15, 10, 15, 1), atTime(2024, 6, 15, 10, 16));
    expectNext("* * * * *", atTime(2024, 12, 31, 23, 59, 30), atTime(2025, 1, 1, 0, 0));

    // Day 31 skips short months.
    expectNext("0 0 31 * *", atTime(2023, 1, 30, 10, 0), atTime(2023, 1, 31, 0, 0));
    expectNext("0 0 31 * *", atTime(2023, 1, 31), atTime(2023, 3, 31));
    expectNext("0 0 31 * *", atTime(2023, 4, 30, 12, 0), atTime(2023, 5, 31));
    expectNext("0 0 31 * *", atTime(2023, 12, 31, 0, 0, 1), atTime(2024, 1, 31));

    // February 29: leap, common year, and a skipped century (1900).
    expectNext("0 0 29 2 *", atTime(2024, 2, 28, 12, 0), atTime(2024, 2, 29));
    expectNext("0 0 29 2 *", atTime(2024, 2, 29), atTime(2028, 2, 29));
    expectNext("0 0 29 2 *", atTime(2023, 2, 28, 12, 0), atTime(2024, 2, 29));
    expectNext("0 0 29 2 *", atTime(1900, 2, 28, 12, 0), atTime(1904, 2, 29));
    expectNext("0 0 29 2 *", atTime(1896, 3, 1), atTime(1904, 2, 29));
    expectNext("0 0 29 2 *", atTime(2000, 2, 28, 12, 0), atTime(2000, 2, 29));

    // Year rollover.
    expectNext("0 0 1 1 *", atTime(2025, 12, 31, 23, 59), atTime(2026, 1, 1));
    expectNext("0 0 1 1 *", atTime(2025, 1, 1), atTime(2026, 1, 1));

    // Sunday is 0 and 7. 2024-06-16 is Sunday.
    expectNext("0 0 * * 0", atTime(2024, 6, 15, 12, 0), atTime(2024, 6, 16));
    expectNext("0 0 * * 7", atTime(2024, 6, 15, 12, 0), atTime(2024, 6, 16));

    // Day-of-month or day-of-week. 2024-03-01 and 2024-03-08 are Fridays; the 13th is Wednesday.
    expectNext("0 0 13 * 5", atTime(2024, 2, 29, 12, 0), atTime(2024, 3, 1));
    expectNext("0 0 13 * 5", atTime(2024, 3, 1), atTime(2024, 3, 8));
    expectNext("0 0 13 * 5", atTime(2024, 3, 8), atTime(2024, 3, 13));

    CronExpr never;
    assert(parseCron("0 0 31 2 *", never) == "");
    SysTime slot;
    assert(!nextSlot(never, atTime(2023, 1, 1), slot));
    assert(parseCron("0 0 31 4 *", never) == "");
    assert(!nextSlot(never, atTime(2024, 1, 1), slot));
}

unittest
{
    auto t = atTime(2024, 6, 15, 10, 7, 30);
    assert(slotStart(t, 15.minutes) == atTime(2024, 6, 15, 10, 0));
    assert(slotStart(atTime(2024, 6, 15, 10, 15), 15.minutes) == atTime(2024, 6, 15, 10, 15));
    assert(slotStart(atTime(2024, 6, 15, 10, 15, 1), 15.minutes) == atTime(2024, 6, 15, 10, 15));
    assert(nextSlotStart(atTime(2024, 6, 15, 10, 15), 15.minutes) == atTime(2024, 6, 15, 10, 30));
    assert(nextSlotStart(t, 15.minutes) == atTime(2024, 6, 15, 10, 15));
    assert(slotStart(atTime(2024, 6, 15, 1, 0), 90.minutes) == atTime(2024, 6, 15, 0, 0));
    assert(slotStart(atTime(2024, 6, 15, 1, 30), 90.minutes) == atTime(2024, 6, 15, 1, 30));

    CronExpr step;
    assert(parseCron("*/15 * * * *", step) == "");
    SysTime slot;
    assert(cronSlot(step, atTime(2024, 6, 15, 10, 15, 30), slot));
    assert(slot == atTime(2024, 6, 15, 10, 15));
    assert(!cronSlot(step, atTime(2024, 6, 15, 10, 7), slot));
    assert(cronSlot(step, atTime(2024, 6, 15, 10, 15), slot));
    assert(slotUnseen(false, SysTime.init, slot));
    assert(!slotUnseen(true, slot, slot));
    assert(slotUnseen(true, atTime(2024, 6, 15, 10, 0), slot));

    ScheduledJob[2] jobs;
    jobs[0] = ScheduledJob("quarter", "*/15 * * * *", Duration.zero);
    jobs[1] = ScheduledJob("often", "", 15.minutes);
    ScheduledFire[4] fired;
    auto now = atTime(2024, 6, 15, 10, 15, 1);
    assert(CronClock.tick(jobs[], now, fired[]) == 2);
    assert(fired[0].jobName == "quarter" && fired[0].kind == ScheduleKind.cron);
    assert(fired[0].slot == atTime(2024, 6, 15, 10, 15));
    assert(fired[1].jobName == "often" && fired[1].kind == ScheduleKind.every);
    assert(fired[1].slot == atTime(2024, 6, 15, 10, 15));

    now = atTime(2024, 6, 15, 10, 7, 1);
    assert(CronClock.tick(jobs[], now, fired[]) == 1);
    assert(fired[0].jobName == "often" && fired[0].slot == atTime(2024, 6, 15, 10, 0));

    ScheduledJob both = ScheduledJob("both", "0 * * * *", 30.seconds);
    ScheduledFire[2] two;
    assert(dueFires(both, atTime(2024, 6, 15, 12, 0, 30), two[]) == 2);
    assert(two[0].kind == ScheduleKind.cron && two[0].slot == atTime(2024, 6, 15, 12, 0));
    assert(two[1].kind == ScheduleKind.every && two[1].slot == atTime(2024, 6, 15, 12, 0, 30));
    SysTime one;
    assert(due(both, atTime(2024, 6, 15, 12, 0, 30), one) && one == two[0].slot);
    assert(dueFires(both, atTime(2024, 6, 15, 12, 0), two[]) == 1);

    ScheduledJob bad = ScheduledJob("nope", "99 99 99 99 99", Duration.zero);
    assert(!due(bad, now, one));
    ScheduledJob named = ScheduledJob("nope", "MON * * * *", 5.minutes);
    assert(due(named, now, one) && one == slotStart(now, 5.minutes));
}

unittest
{
    import core.memory : GC;

    auto warm = atTime(2024, 6, 15, 10, 0);
    CronExpr warmed;
    SysTime ignore;
    cast(void) parseCron("* * * * *", warmed);
    cast(void) nextSlot(warmed, warm, ignore);
    cast(void) slotStart(warm, 15.minutes);

    auto before = GC.stats().allocatedInCurrentThread;
    CronExpr expr;
    assert(parseCron("*/15 0 1,15 1-12 0-6", expr) == "");
    SysTime slot;
    assert(nextSlot(expr, warm, slot));
    assert(cronSlot(expr, atTime(2024, 6, 1, 0, 0), slot));
    auto window = slotStart(atTime(2024, 6, 15, 10, 7), 15.minutes);
    cast(void) window;
    ScheduledJob[1] jobs = [ScheduledJob("quarter", "*/15 * * * *", 15.minutes)];
    ScheduledFire[2] fired;
    cast(void) CronClock.tick(jobs[], atTime(2024, 6, 15, 10, 15, 1), fired[]);
    assert(GC.stats().allocatedInCurrentThread == before);
}
