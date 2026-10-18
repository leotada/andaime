/// `PatchField!T`: a field with three states -- absent, `null`, or a value -- for PATCH-style updates, where an absent
/// field means "leave it alone" and `null` means "clear it". `Optional!T` cannot tell the first two apart.
module andaime.http.patchfield 2025;

@safe:

/// A JSON field that may be absent, `null`, or a value: `PatchField!string nickname;` in a PATCH body.
///
///     if (p.nickname.isNull) user.nickname = null;          // "nickname": null    -> clear it
///     else if (p.nickname.hasValue) user.nickname = p.nickname.value; // "nickname": "x" -> set it
///     // absent: leave it alone
///
/// In a DTO it is never required. Validation attributes (`@minLength`, `@inRange`...) apply to the value only.
/// `writeJson` omits an absent field from its object and writes `null` for a null one.
struct PatchField(T)
{
    private enum State : ubyte { absent, null_, value }

    private T _value;
    private State _state;

    /// A field that holds a value.
    this(T v)
    {
        _value = v;
        _state = State.value;
    }

    /// The absent field (same as `PatchField!T.init`).
    static PatchField absent() => PatchField.init;

    /// A field that was sent as `null`.
    static PatchField null_()
    {
        PatchField p;
        p._state = State.null_;
        return p;
    }

    /// The field was not in the input at all.
    bool isAbsent() const => _state == State.absent;
    /// The field was sent as `null`.
    bool isNull() const => _state == State.null_;
    /// The field was sent with a value.
    bool hasValue() const => _state == State.value;
    /// The field was sent, as `null` or with a value.
    bool isPresent() const => _state != State.absent;

    /// The value; only when `hasValue`.
    ref inout(T) value() inout return
    {
        assert(_state == State.value, "PatchField has no value: check .hasValue before .value");
        return _value;
    }

    /// The value, or `fallback` when absent or null.
    inout(T) valueOr(inout(T) fallback) inout => _state == State.value ? _value : fallback;
}

enum isPatchField(T) = is(T == PatchField!U, U);

unittest
{
    PatchField!int a;
    assert(a.isAbsent && !a.isNull && !a.hasValue && !a.isPresent && a.valueOr(7) == 7);
    auto n = PatchField!int.null_;
    assert(!n.isAbsent && n.isNull && !n.hasValue && n.isPresent && n.valueOr(7) == 7);
    auto v = PatchField!int(3);
    assert(v.hasValue && v.isPresent && v.value == 3 && v.valueOr(7) == 3);
    assert(PatchField!int.absent == a);
}
