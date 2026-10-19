/// What must hold for any text given to `Timestamp.fromString` and `CalendarDate.fromString` (shared by the mutation
/// fuzzer and the libFuzzer target): they never crash; whatever they accept writes text that parses back to an equal
/// value and writes the same text again; an accepted timestamp's written form is canonical (`T`, a trimmed fraction, `Z`
/// or `±hh:mm`).
module time_invariants 2025;

import andaime.values.calendardate : CalendarDate;
import andaime.values.timestamp : Timestamp;

void checkTime(scope const(ubyte)[] data) @safe
{
    auto text = cast(const(char)[]) data;

    Timestamp t;
    if (Timestamp.fromString(text, t))
    {
        char[32] buf;
        auto once = buf[0 .. t.format(buf)].idup;
        Timestamp again;
        assert(Timestamp.fromString(once, again), "a written Timestamp does not parse: " ~ once);
        assert(again == t && again.offsetMinutes == t.offsetMinutes, "a Timestamp changed through its text: " ~ once);
        assert(again.toString == once, "a Timestamp's text is not stable: " ~ once);
        assert(once[10] == 'T' && (once[$ - 1] == 'Z' || once[$ - 6] == '+' || once[$ - 6] == '-'), once);
        assert(once.length < 26 || once[19] != '.' || once[once.length - (once[$ - 1] == 'Z' ? 2 : 7)] != '0',
            "trailing zeros in the fraction: " ~ once);
        assert(t.utc == t && t.utc.offsetMinutes == 0 && t.utc.unixMicros == t.unixMicros);
    }

    CalendarDate d;
    if (CalendarDate.fromString(text, d))
    {
        auto once = d.toString;
        CalendarDate again;
        assert(CalendarDate.fromString(once, again) && again == d && once == text, "a CalendarDate changed: " ~ once);
    }
}
