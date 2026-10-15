/// What must hold for any bytes given to the JSON reader (shared by the mutation fuzzer and the libFuzzer target):
/// `parseJson` never crashes and never recurses past its depth limit; whatever it accepts writes back as JSON that parses
/// to an equal value and writes the same text again; a typed decode of the same bytes never crashes either.
module json_invariants;

import vela.web.jsonvalue;
import vela.web.json : decodeJson;
import vela.web.dto : FieldErrors;
import vela.web.params : Optional, PatchField;

struct Inner { int n; Optional!string s; }
struct Typed { string name; PatchField!long id; Inner[] items; double[string] scores; JsonValue extra; }

void checkJson(scope const(ubyte)[] data) @safe
{
    auto text = cast(const(char)[]) data;
    JsonValue v;
    string error;
    // a small depth limit also exercises the limit path; the default one is covered by the unittests
    immutable ok = parseJson(text, v, error, JsonLimits(16));
    if (ok)
    {
        assert(depthOf(v) <= 16, "depth limit broken");
        auto once = v.toString;
        JsonValue again;
        string error2;
        assert(parseJson(once, again, error2, JsonLimits(16)), "own output does not parse: " ~ error2 ~ ": " ~ once);
        assert(again == v, "round trip changed the value: " ~ once);
        assert(again.toString == once, "writing is not stable: " ~ once);
    }
    else
        assert(error.length, "a failure without a message");

    FieldErrors errs;
    Typed t;
    decodeJson(text, t, errs);
    assert(errs.count <= FieldErrors.capacity);
}

private size_t depthOf(ref const JsonValue v) @safe
{
    size_t d;
    if (v.isArray)
        foreach (ref e; v.array)
        {
            immutable x = depthOf(e);
            d = x > d ? x : d;
        }
    else if (v.isObject)
        foreach (ref m; v.members)
        {
            immutable x = depthOf(m.value);
            d = x > d ? x : d;
        }
    else
        return 0;
    return d + 1;
}
