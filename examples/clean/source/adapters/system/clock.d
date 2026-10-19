/// The system's clock, in UTC, to the microsecond.
module adapters.system.clock 2025;

@safe:

import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;
import andaime.values.timestamp : Timestamp;
import usecases.system : SystemClockPort = Clock;

final class SystemClock : SystemClockPort
{
    Timestamp now() => Timestamp.fromSysTime(Clock.currTime(UTC()));
}
