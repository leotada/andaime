/// Fixed stand-ins for the system's effects (`usecases/system.d`): a test sets the time, and gets identifiers and tokens
/// it can predict.
module tests.fakes 2025;

@safe:

import andaime.values.timestamp : Timestamp;
import andaime.values.uuid : Uuid;
import usecases.system : Clock, IdGenerator, TokenGenerator;

/// A clock that only moves when the test says so.
final class FixedClock : Clock
{
    Timestamp current;

    this(Timestamp at = Timestamp.fromUnixMicros(1_767_268_800_000_000)) // 2026-01-01T12:00:00Z
    {
        current = at;
    }

    Timestamp now() => current;
}

/// Identifiers 00000000-0000-7000-8000-000000000001, ...0002, ...: in order, like real version 7 ones.
final class SequenceIds : IdGenerator
{
    private ubyte last;

    Uuid newId()
    {
        ubyte[10] r;
        r[9] = ++last;
        return Uuid.v7(0, r);
    }
}

/// Tokens "token-1", "token-2", ...
final class SequenceTokens : TokenGenerator
{
    private int last;

    string newToken()
    {
        ++last;
        return "token-" ~ cast(char)('0' + last % 10);
    }
}
