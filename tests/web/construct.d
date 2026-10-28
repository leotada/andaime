/// `construct!T(adapters)`: constructor parameters resolved by type from a struct of adapters, from extra arguments, or
/// by building a concrete class parameter the same way. The compile errors are in tests/compile_fail/construct_*.d.
module construct_test 2025;

@safe:

import andaime;

interface Clock { long now(); }
interface Users { string name(long id); }

final class FixedClock : Clock { long now() => 42; }
final class MemUsers : Users { string name(long id) => id == 1 ? "ana" : "?"; }

final class Greet
{
    Users users;
    Clock clock;
    this(Users users, Clock clock) { this.users = users; this.clock = clock; }
    string hello() => users.name(1) ~ "@" ~ (clock.now() == 42 ? "42" : "?");
}

/// A controller: its use case is a concrete class, built from the same adapters.
final class Controller
{
    Greet greet;
    string secret;
    this(Greet greet, string secret) { this.greet = greet; this.secret = secret; }
}

final class NoCtor { }

final class Wrapper
{
    NoCtor inner;
    this(NoCtor inner) { this.inner = inner; }
}

final class OnlyClock { Clock c; this(Clock c) { this.c = c; } }

struct Adapters
{
    Clock clock;
    Users users;
}

unittest
{
    auto a = Adapters(new FixedClock, new MemUsers);
    auto g = construct!Greet(a);
    assert(g.users is a.users && g.clock is a.clock);
    assert(g.hello == "ana@42");
}

unittest
{
    auto a = Adapters(new FixedClock, new MemUsers);
    // a concrete class parameter is built from the adapters; a value that is not a port is an extra argument
    auto c = construct!Controller(a, "s3cret");
    assert(c.secret == "s3cret" && c.greet.hello == "ana@42");
    // a class without a constructor, and one that needs it
    assert(construct!NoCtor(a) !is null);
    assert(construct!Wrapper(a).inner !is null);
}

unittest
{
    // an extra argument wins over a field of the same type
    auto a = Adapters(new FixedClock, new MemUsers);
    auto other = new FixedClock;
    assert(construct!OnlyClock(a, cast(Clock) other).c is other);
}
