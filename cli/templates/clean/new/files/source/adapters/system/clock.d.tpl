/// The system's clock, in UTC.
module adapters.system.clock 2025;

@safe:

import std.datetime.systime : Clock, SysTime;
import std.datetime.timezone : UTC;
import usecases.system : SystemClockPort = Clock;

final class SystemClock : SystemClockPort
{
    SysTime now() => Clock.currTime(UTC());
}
