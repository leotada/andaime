/// `Optional!T`: a value that may be absent. One type for everything that can be missing: an optional query
/// parameter or header, a JSON field, a database column that may be NULL.
module andaime.http.optional;

@safe:

/// Optional value: `Optional!int page`, `Optional!(Header!"X-Trace")`, `Optional!string email` in a DTO or a row.
/// An absent value is JSON `null`, SQL NULL and an omitted query parameter.
struct Optional(T)
{
    private T _value;
    private bool _has;

    this(T v)
    {
        _value = v;
        _has = true;
    }

    /// The empty value (same as `Optional!T.init`).
    static Optional none() => Optional.init;

    bool has() const => _has;

    ref inout(T) get() inout return
    {
        assert(_has, "empty Optional: check .has before .get");
        return _value;
    }

    inout(T) getOr(inout(T) fallback) inout => _has ? _value : fallback;
}

unittest
{
    Optional!int a;
    assert(!a.has && a.getOr(7) == 7 && !Optional!int.none.has);
    auto b = Optional!int(3);
    assert(b.has && b.get == 3 && b.getOr(7) == 3);
}
