/// `JsonValue` (in `andaime.values.jsonvalue`, re-exported here) and the typed conversions that need andaime's JSON codec:
/// `fromJson!T(text)`, `toJson(value)` and `Json!T`, a value that travels as JSON text.
module andaime.web.jsonvalue 2025;

@safe:

public import andaime.values.jsonvalue;
import andaime.http.buffer : ByteBuffer;
import andaime.web.dto : FieldErrors, FieldError;

/// `text` without its `scope`, for the JSON reader: it copies every string it produces and keeps no slice of the input
/// once the call returns, but its generic helpers take the text as a plain slice.
private const(char)[] unscoped(scope const(char)[] text) pure nothrow @nogc @trusted
{
    // @trusted: the slice is only handed to a reader that lives no longer than the call
    return *cast(const(char)[]*) &text;
}

/// Decodes JSON text into a `T` with the rules of a request body (a DTO with its validation attributes, an array, a map,
/// a `JsonValue`...): for an upstream API's response. Throws `JsonError` with the first problem
/// (`andaime: invalid JSON at byte 3`, `andaime: body.items.1.qty: expected an integer ...`).
T fromJson(T)(scope const(char)[] text)
{
    import andaime.web.json : decodeJson;

    T v;
    FieldErrors errs;
    if (!decodeJson(unscoped(text), v, errs))
    {
        auto e = errs.list.length ? errs.list[0] : FieldError.init;
        auto where = e.dotted;
        throw new JsonError("andaime: " ~ (where.length ? where ~ ": " : "") ~ e.message);
    }
    return v;
}

/// `value` as JSON text (what a handler returning it would send).
string toJson(T)(auto ref const T value)
{
    import andaime.web.json : writeJson;

    ByteBuffer b;
    writeJson(b, value);
    return b.data.idup;
}

/// A `T` that travels as JSON text where a value is text: a `json`/`jsonb` column (`andaime:pg`'s `rowsAs` and parameters),
/// a query or path parameter. In a JSON body or response it is plain `T` (no extra quoting), and OpenAPI describes `T`.
///
///     struct TaskRow { long id; Json!(TagRef[]) tags; Optional!(Json!JsonValue) meta; }
///     db.query("select t.id, coalesce(json_agg(g) filter (where g.id is not null), '[]') as tags, t.meta ...").rowsAs!TaskRow;
///
/// `alias this` reaches the value: `row.tags.length`, `row.tags[0].name`. A column that is not valid JSON for `T` throws
/// like any other bad cell.
struct Json(T)
{
    T value;
    alias value this;

    /// The text-type protocol (`andaime.http.texttype`): JSON text in, JSON text out.
    static bool fromString(scope const(char)[] text, out Json v)
    {
        try
            v.value = fromJson!T(text);
        catch (JsonError)
            return false;
        return true;
    }

    /// ditto
    void toString(scope void delegate(scope const(char)[]) @safe sink) const
    {
        sink(toJson(value));
    }

    enum invalidMessage = "expected JSON for " ~ T.stringof;
}

/// True for `Json!T`.
enum isJsonText(T) = is(T == Json!U, U);

unittest
{
    import andaime.http.texttype : isTextType, textFromString, textToString;

    struct Tag { long id; string name; }
    static assert(isTextType!(Json!(Tag[])) && isJsonText!(Json!(Tag[])));
    Json!(Tag[]) tags;
    assert(textFromString(`[{"id":1,"name":"a"},{"id":2,"name":"b"}]`, tags));
    assert(tags.length == 2 && tags[1].name == "b");
    string back;
    textToString(tags, (scope const(char)[] s) { back ~= s; });
    assert(back == `[{"id":1,"name":"a"},{"id":2,"name":"b"}]`);
    assert(!textFromString(`[{"id":"x"}]`, tags));

    // inside a DTO it is plain JSON both ways
    struct Row { long id; Json!(Tag[]) tags; Json!JsonValue meta; }
    auto r = fromJson!Row(`{"id":7,"tags":[{"id":1,"name":"a"}],"meta":{"k":[1,2]}}`);
    assert(r.tags[0].name == "a" && r.meta["k"][1].asInteger == 2);
    assert(toJson(r) == `{"id":7,"tags":[{"id":1,"name":"a"}],"meta":{"k":[1,2]}}`);
}

unittest
{
    struct Quote { string currency; double rate; }
    auto q = fromJson!Quote(`{"currency":"BRL","rate":5.25,"extra":[1]}`);
    assert(q.currency == "BRL" && q.rate == 5.25 && toJson(q) == `{"currency":"BRL","rate":5.25}`);
    assert(fromJson!(JsonValue[])(`[1,"a"]`)[1].asString == "a");
    bool threw;
    try
        fromJson!Quote(`{"currency":"BRL","rate":"x"}`);
    catch (JsonError e)
        threw = e.msg == "andaime: rate: expected a number";
    assert(threw);
    threw = false;
    try
        fromJson!Quote(`{"currency":`);
    catch (JsonError e)
        threw = e.msg == "andaime: invalid JSON at byte 12";
    assert(threw);
}
