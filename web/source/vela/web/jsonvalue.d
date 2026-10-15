/// `JsonValue`: any JSON value, for inputs whose shape is only known at run time (an object validated against a schema
/// at run time, values of mixed types per key, an upstream API's response). Objects keep their key order.
///
///     bool update(JsonBody!JsonValue settings)
///     {
///         foreach (ref m; settings.members)
///             if (m.value.isBool) apply(m.key, m.value.asBool);
///             else if (m.value.isString) apply(m.key, m.value.asString);
///         ...
///     }
///
/// Parsing from outside a request: `auto v = parseJson(text);` (throws `JsonError`), or the non-throwing
/// `parseJson(text, v, error)`.
module vela.web.jsonvalue;

@safe:

import vela.http.buffer : ByteBuffer;
import vela.http.utf8 : validUtf8;
import vela.web.dto : FieldErrors, FieldPath, FieldError;
import vela.web.json : JsonReader, decodeJsonString, writeJsonString;
import vela.web.convert : parseInteger, parseFloat;
import vela.web.numtext : itoa;

/// The kind of a `JsonValue`.
enum JsonType : ubyte
{
    null_,
    boolean,
    integer,  /// a number without fraction or exponent that fits a `long`
    floating, /// any other number
    string,
    array,
    object,
}

/// Thrown by `parseJson(text)` and by the accessors of `JsonValue` used on the wrong kind of value.
class JsonError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// One member of a JSON object.
struct JsonMember
{
    string key;
    JsonValue value;
}

/// Bounds for parsing untrusted JSON into a `JsonValue`.
struct JsonLimits
{
    /// Arrays and objects nested deeper than this are an error (the parser recurses once per level).
    size_t maxDepth = 64;
    /// Longer input is an error (`parseJson` only: a request body is already bounded by `limits.maxBodyBytes`).
    size_t maxBytes = 16 << 20;
}

/// Any JSON value: null, a boolean, a number (integer or floating), a string, an array, or an object whose members keep
/// the order they came in. Build one with `JsonValue(x)` (`null`, `bool`, any integer, `double`, `string`, an array of
/// `JsonValue`), `JsonValue.emptyArray`, `JsonValue.emptyObject`, `obj["key"] = ...` and `arr.append(...)`.
struct JsonValue
{
    private JsonType _type;
    private bool _bool;
    private long _int;
    private double _float = 0;
    private string _str;
    private JsonValue[] _arr;
    private JsonMember[] _obj;

    /// A value of any supported D type: `JsonValue(null)`, `JsonValue(true)`, `JsonValue(42)`, `JsonValue(1.5)`,
    /// `JsonValue("text")`, `JsonValue([JsonValue(1), JsonValue("a")])`.
    this(T)(T v)
    {
        static if (is(T == typeof(null)))
            _type = JsonType.null_;
        else static if (is(T == bool))
        {
            _type = JsonType.boolean;
            _bool = v;
        }
        else static if (__traits(isIntegral, T) && !is(T == char) && !is(T == wchar) && !is(T == dchar))
        {
            static if (__traits(isUnsigned, T) && T.sizeof >= 8)
                assert(v <= long.max, "vela: integer too large for a JsonValue");
            _type = JsonType.integer;
            _int = cast(long) v;
        }
        else static if (__traits(isFloating, T))
        {
            _type = JsonType.floating;
            _float = v;
        }
        else static if (is(T : const(char)[]))
        {
            _type = JsonType.string;
            _str = v.idup;
        }
        else static if (is(T : const(JsonValue)[]))
        {
            _type = JsonType.array;
            _arr = v.dup;
        }
        else static if (is(T : const(JsonMember)[]))
        {
            _type = JsonType.object;
            _obj = v.dup;
        }
        else
            static assert(0, "vela: JsonValue cannot hold a '" ~ T.stringof ~ "'");
    }

    /// An empty array (`[]`).
    static JsonValue emptyArray()
    {
        JsonValue v;
        v._type = JsonType.array;
        return v;
    }

    /// An empty object (`{}`).
    static JsonValue emptyObject()
    {
        JsonValue v;
        v._type = JsonType.object;
        return v;
    }

    JsonType type() const pure nothrow @nogc => _type;
    bool isNull() const pure nothrow @nogc => _type == JsonType.null_;
    bool isBool() const pure nothrow @nogc => _type == JsonType.boolean;
    bool isInteger() const pure nothrow @nogc => _type == JsonType.integer;
    bool isFloat() const pure nothrow @nogc => _type == JsonType.floating;
    bool isNumber() const pure nothrow @nogc => _type == JsonType.integer || _type == JsonType.floating;
    bool isString() const pure nothrow @nogc => _type == JsonType.string;
    bool isArray() const pure nothrow @nogc => _type == JsonType.array;
    bool isObject() const pure nothrow @nogc => _type == JsonType.object;

    /// The value; throws `JsonError` when it is of another kind.
    bool asBool() const
    {
        expect(JsonType.boolean);
        return _bool;
    }

    /// ditto
    long asInteger() const
    {
        expect(JsonType.integer);
        return _int;
    }

    /// Any number as a `double` (an integer is converted).
    double asFloat() const
    {
        if (_type == JsonType.integer)
            return cast(double) _int;
        expect(JsonType.floating);
        return _float;
    }

    /// ditto
    string asString() const
    {
        expect(JsonType.string);
        return _str;
    }

    /// The elements of an array; throws `JsonError` otherwise.
    inout(JsonValue)[] array() inout return
    {
        expect(JsonType.array);
        return _arr;
    }

    /// The members of an object, in their order; throws `JsonError` otherwise.
    inout(JsonMember)[] members() inout return
    {
        expect(JsonType.object);
        return _obj;
    }

    /// Number of elements (array) or members (object); throws `JsonError` for other kinds.
    size_t length() const
    {
        if (_type == JsonType.array)
            return _arr.length;
        expect(JsonType.object);
        return _obj.length;
    }

    /// The member `key` of an object, or null when there is none (or this is not an object). A linear search: for many
    /// lookups in a big object, walk `members` once instead.
    inout(JsonValue)* get(scope const(char)[] key) inout return
    {
        if (_type != JsonType.object)
            return null;
        foreach (ref m; _obj)
            if (m.key == key)
                return &m.value;
        return null;
    }

    /// The member `key`; throws `JsonError` when it is missing or this is not an object.
    ref inout(JsonValue) opIndex(scope const(char)[] key) inout return
    {
        expect(JsonType.object);
        if (auto p = get(key))
            return *p;
        throw new JsonError("vela: JSON object has no member '" ~ key.idup ~ "'");
    }

    /// Element `i` of an array; throws `JsonError` when out of range or this is not an array.
    ref inout(JsonValue) opIndex(size_t i) inout return
    {
        expect(JsonType.array);
        if (i >= _arr.length)
            throw new JsonError("vela: JSON array index " ~ itoa(i) ~ " out of range (length " ~ itoa(_arr.length) ~ ")");
        return _arr[i];
    }

    /// Sets member `key` of an object (replacing it in place if present; appended otherwise). A null value becomes an
    /// empty object first.
    void opIndexAssign(T)(T value, string key)
    {
        static if (is(T == JsonValue))
            alias v = value;
        else
            auto v = JsonValue(value);
        if (_type == JsonType.null_)
            _type = JsonType.object;
        expect(JsonType.object);
        foreach (ref m; _obj)
            if (m.key == key)
            {
                m.value = v;
                return;
            }
        _obj ~= JsonMember(key, v);
    }

    /// Appends to an array. A null value becomes an empty array first.
    void append(T)(T value)
    {
        if (_type == JsonType.null_)
            _type = JsonType.array;
        expect(JsonType.array);
        static if (is(T == JsonValue))
            _arr ~= value;
        else
            _arr ~= JsonValue(value);
    }

    /// The same JSON value: same kind (an integer is not equal to a floating number) and contents; object members compare
    /// in order.
    bool opEquals(const JsonValue o) const
    {
        if (_type != o._type)
            return false;
        final switch (_type)
        {
            case JsonType.null_: return true;
            case JsonType.boolean: return _bool == o._bool;
            case JsonType.integer: return _int == o._int;
            case JsonType.floating: return _float == o._float;
            case JsonType.string: return _str == o._str;
            case JsonType.array: return _arr == o._arr;
            case JsonType.object:
                if (_obj.length != o._obj.length)
                    return false;
                foreach (i, ref m; _obj)
                    if (m.key != o._obj[i].key || m.value != o._obj[i].value)
                        return false;
                return true;
        }
    }

    /// The value as JSON text.
    string toString() const
    {
        ByteBuffer b;
        writeJsonValue(b, this);
        return b.data.idup;
    }

    private void expect(JsonType t) const
    {
        if (_type != t)
            throw new JsonError("vela: JSON value is " ~ typeName(_type) ~ ", not " ~ typeName(t));
    }
}

private string typeName(JsonType t) pure nothrow @nogc
{
    final switch (t)
    {
        case JsonType.null_: return "null";
        case JsonType.boolean: return "a boolean";
        case JsonType.integer: return "an integer";
        case JsonType.floating: return "a floating-point number";
        case JsonType.string: return "a string";
        case JsonType.array: return "an array";
        case JsonType.object: return "an object";
    }
}

// =====================================================================
// Writing
// =====================================================================

/// Writes `v` as JSON. A floating number with an integral value keeps a `.0`, so it reads back as floating.
void writeJsonValue(ref ByteBuffer o, ref const JsonValue v)
{
    final switch (v._type)
    {
        case JsonType.null_: o.put("null"); break;
        case JsonType.boolean: o.put(v._bool ? "true" : "false"); break;
        case JsonType.integer: o.putInt(v._int); break;
        case JsonType.floating:
            immutable start = o.length;
            o.putFloat(v._float);
            bool plain = true;
            foreach (c; o.data[start .. $])
                plain &= c != '.' && c != 'e' && c != 'E' && c != 'n'; // 'n': non-finite, written as null
            if (plain)
                o.put(".0");
            break;
        case JsonType.string: writeJsonString(o, v._str); break;
        case JsonType.array:
            o.put('[');
            foreach (i, ref e; v._arr)
            {
                if (i)
                    o.put(',');
                writeJsonValue(o, e);
            }
            o.put(']');
            break;
        case JsonType.object:
            o.put('{');
            foreach (i, ref m; v._obj)
            {
                if (i)
                    o.put(',');
                writeJsonString(o, m.key);
                o.put(':');
                writeJsonValue(o, m.value);
            }
            o.put('}');
            break;
    }
}

// =====================================================================
// Reading
// =====================================================================

/// Reads one JSON value into `v`. Like `readJson`: false only on a syntax error (or a broken limit, which is reported
/// like one); invalid UTF-8 in a string goes to `errs` with its path. `depth` is the nesting already entered.
bool readJsonValue(ref JsonReader r, ref JsonValue v, ref FieldErrors errs, ref FieldPath path, size_t depth,
    size_t maxDepth = JsonLimits.init.maxDepth)
{
    r.ws();
    if (r.pos >= r.s.length)
        return r.syntax();
    switch (r.s[r.pos])
    {
        case 'n':
            if (!r.literal("null"))
                return r.syntax();
            v = JsonValue.init;
            return true;
        case 't':
        case 'f':
            if (r.literal("true"))
                v = JsonValue(true);
            else if (r.literal("false"))
                v = JsonValue(false);
            else
                return r.syntax();
            return true;
        case '"':
            string s;
            if (!readString(r, s, errs, path))
                return false;
            v = JsonValue.init;
            v._type = JsonType.string;
            v._str = s;
            return true;
        case '[':
            if (depth >= maxDepth)
                return r.fail(nestingMessage(maxDepth));
            r.pos++;
            v = JsonValue.emptyArray;
            if (r.eat(']'))
                return true;
            do
            {
                JsonValue e;
                immutable mark = path.pushIndex(v._arr.length);
                if (!readJsonValue(r, e, errs, path, depth + 1, maxDepth))
                    return false;
                path.pop(mark);
                v._arr ~= e;
            }
            while (r.eat(','));
            return r.eat(']') || r.syntax();
        case '{':
            if (depth >= maxDepth)
                return r.fail(nestingMessage(maxDepth));
            r.pos++;
            v = JsonValue.emptyObject;
            if (r.eat('}'))
                return true;
            size_t[string] index; // built past a few members, so repeated keys stay linear in the input size
            do
            {
                r.ws();
                if (r.pos >= r.s.length || r.s[r.pos] != '"')
                    return r.syntax();
                string key;
                if (!readString(r, key, errs, path) || !r.eat(':'))
                    return r.syntax();
                JsonValue item;
                immutable mark = path.pushKey(key);
                if (!readJsonValue(r, item, errs, path, depth + 1, maxDepth))
                    return false;
                path.pop(mark);
                // a repeated key keeps its first position and its last value, like a map
                ptrdiff_t at = -1;
                if (index !is null)
                {
                    if (auto p = key in index)
                        at = *p;
                }
                else
                    foreach (i, ref m; v._obj)
                        if (m.key == key)
                        {
                            at = i;
                            break;
                        }
                if (at >= 0)
                    v._obj[at].value = item;
                else
                {
                    v._obj ~= JsonMember(key, item);
                    if (index !is null)
                        index[key] = v._obj.length - 1;
                    else if (v._obj.length == 8)
                        foreach (i, ref m; v._obj)
                            index[m.key] = i;
                }
            }
            while (r.eat(','));
            return r.eat('}') || r.syntax();
        default:
            return readNumber(r, v);
    }
}

private string nestingMessage(size_t maxDepth) pure nothrow @safe
    => "JSON nested deeper than " ~ itoa(maxDepth) ~ " levels";

/// A JSON string (the reader is at its opening quote). Invalid UTF-8 is an error at `path` and gives "".
private bool readString(ref JsonReader r, out string s, ref FieldErrors errs, ref FieldPath path)
{
    const(char)[] raw;
    bool esc;
    if (!r.rawString(raw, esc))
        return false;
    if (!validUtf8(raw))
    {
        errs.addPath(path, "string_unicode", "invalid UTF-8");
        return true;
    }
    if (!decodeJsonString(raw, esc, s))
        return r.syntax();
    return true;
}

/// A number, with JSON's exact grammar: `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`.
private bool readNumber(ref JsonReader r, ref JsonValue v)
{
    immutable start = r.pos;
    const(char)[] tok;
    if (!r.number(tok))
        return false;
    size_t i = 0;
    bool integral = true;
    if (i < tok.length && tok[i] == '-')
        i++;
    if (i < tok.length && tok[i] == '0')
        i++;
    else if (i < tok.length && tok[i] >= '1' && tok[i] <= '9')
        while (i < tok.length && tok[i] >= '0' && tok[i] <= '9')
            i++;
    else
        return failAt(r, start);
    if (i < tok.length && tok[i] == '.')
    {
        integral = false;
        immutable d = ++i;
        while (i < tok.length && tok[i] >= '0' && tok[i] <= '9')
            i++;
        if (i == d)
            return failAt(r, start);
    }
    if (i < tok.length && (tok[i] == 'e' || tok[i] == 'E'))
    {
        integral = false;
        i++;
        if (i < tok.length && (tok[i] == '+' || tok[i] == '-'))
            i++;
        immutable d = i;
        while (i < tok.length && tok[i] >= '0' && tok[i] <= '9')
            i++;
        if (i == d)
            return failAt(r, start);
    }
    if (i != tok.length)
        return failAt(r, start);

    v = JsonValue.init;
    long n;
    if (integral && parseInteger(tok, n))
    {
        v._type = JsonType.integer;
        v._int = n;
        return true;
    }
    double d;
    if (!parseFloat(tok, d) || d == double.infinity || d == -double.infinity)
    {
        r.pos = start;
        return r.fail("number out of range (or longer than 63 characters)");
    }
    v._type = JsonType.floating;
    v._float = d;
    return true;
}

private bool failAt(ref JsonReader r, size_t pos)
{
    r.pos = pos;
    return r.syntax();
}

/// Parses a whole JSON document into `v`. On failure returns false and sets `error` to one line
/// (`invalid JSON at byte 12`, `JSON nested deeper than 64 levels at byte 70`, `invalid UTF-8 at "a",1`).
bool parseJson(scope const(char)[] text, out JsonValue v, out string error, JsonLimits limits = JsonLimits.init)
{
    if (text.length > limits.maxBytes)
    {
        error = "JSON longer than " ~ itoa(limits.maxBytes) ~ " bytes";
        return false;
    }
    auto r = JsonReader(text);
    FieldErrors errs;
    FieldPath path;
    if (!readJsonValue(r, v, errs, path, 0, limits.maxDepth))
    {
        error = r.errorText();
        return false;
    }
    r.ws();
    if (r.pos != text.length)
    {
        error = "invalid JSON at byte " ~ itoa(r.pos);
        return false;
    }
    if (errs.any)
    {
        auto e = errs.list[0];
        error = e.message ~ (e.locJson.length ? " at " ~ e.locJson : "");
        return false;
    }
    return true;
}

/// Parses a whole JSON document; throws `JsonError` (`vela: invalid JSON at byte 12`) when it is not valid.
JsonValue parseJson(scope const(char)[] text, JsonLimits limits = JsonLimits.init)
{
    JsonValue v;
    string error;
    if (!parseJson(text, v, error, limits))
        throw new JsonError("vela: " ~ error);
    return v;
}

/// Decodes JSON text into a `T` with the rules of a request body (a DTO with its validation attributes, an array, a map,
/// a `JsonValue`...): for an upstream API's response. Throws `JsonError` with the first problem
/// (`vela: invalid JSON at byte 3`, `vela: body.items.1.qty: expected an integer ...`).
T fromJson(T)(scope const(char)[] text)
{
    import vela.web.json : decodeJson;

    T v;
    FieldErrors errs;
    if (!decodeJson(text, v, errs))
    {
        auto e = errs.list.length ? errs.list[0] : FieldError.init;
        auto where = e.dotted;
        throw new JsonError("vela: " ~ (where.length ? where ~ ": " : "") ~ e.message);
    }
    return v;
}

/// `value` as JSON text (what a handler returning it would send).
string toJson(T)(auto ref const T value)
{
    import vela.web.json : writeJson;

    ByteBuffer b;
    writeJson(b, value);
    return b.data.idup;
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
        threw = e.msg == "vela: rate: expected a number";
    assert(threw);
    threw = false;
    try
        fromJson!Quote(`{"currency":`);
    catch (JsonError e)
        threw = e.msg == "vela: invalid JSON at byte 12";
    assert(threw);
}

unittest
{
    auto v = parseJson(`{"b":true,"n":null,"i":-12,"f":1.5,"e":2e3,"s":"aç\"","a":[1,[2],{}],"o":{"x":{}}}`);
    assert(v.isObject && v.length == 8);
    string[] keys;
    foreach (ref m; v.members)
        keys ~= m.key;
    assert(keys == ["b", "n", "i", "f", "e", "s", "a", "o"], "order kept");
    assert(v["b"].asBool && v["n"].isNull && v["i"].asInteger == -12 && v["f"].asFloat == 1.5);
    assert(v["e"].isFloat && v["e"].asFloat == 2000 && v["s"].asString == "aç\"");
    assert(v["a"].length == 3 && v["a"][1][0].asInteger == 2 && v["a"][2].isObject);
    assert(v.get("missing") is null && v["o"].get("x") !is null);
    assert(v["i"].asFloat == -12.0, "an integer reads as a double too");

    // accessors on the wrong kind throw, with the kinds in the message
    bool threw;
    try
        v["s"].asBool;
    catch (JsonError e)
        threw = e.msg == "vela: JSON value is a string, not a boolean";
    assert(threw);
    threw = false;
    try
        v["nope"];
    catch (JsonError e)
        threw = e.msg == "vela: JSON object has no member 'nope'";
    assert(threw);
    threw = false;
    try
        v["a"][3];
    catch (JsonError e)
        threw = true;
    assert(threw);

    // writing: round trip, a floating number keeps its kind
    assert(v.toString == `{"b":true,"n":null,"i":-12,"f":1.5,"e":2000.0,"s":"aç\"","a":[1,[2],{}],"o":{"x":{}}}`,
        v.toString);
    assert(parseJson(v.toString) == v);

    // a repeated key keeps its first position and its last value, also past the index threshold
    assert(parseJson(`{"a":1,"b":2,"a":3}`).toString == `{"a":3,"b":2}`);
    string big = "{";
    foreach (i; 0 .. 20)
        big ~= `"k` ~ itoa(i) ~ `":` ~ itoa(i) ~ ",";
    big ~= `"k3":"x","k15":null}`;
    auto bv = parseJson(big);
    assert(bv.length == 20 && bv["k3"].asString == "x" && bv["k15"].isNull && bv.members[3].key == "k3");

    // building
    auto o = JsonValue.emptyObject;
    o["name"] = "Ana";
    o["age"] = 30;
    o["tags"] = JsonValue([JsonValue("a"), JsonValue(null)]);
    o["age"] = 31;
    JsonValue arr;
    arr.append(1);
    arr.append(JsonValue(2.5));
    o["list"] = arr;
    assert(o.toString == `{"name":"Ana","age":31,"tags":["a",null],"list":[1,2.5]}`, o.toString);
    assert(JsonValue(true) != JsonValue(1) && JsonValue(1) != JsonValue(1.0) && JsonValue(null) == JsonValue.init);
}

unittest
{
    // errors: syntax, numbers outside JSON's grammar, depth, size, UTF-8
    JsonValue v;
    string err;
    assert(!parseJson(`{"a":}`, v, err) && err == "invalid JSON at byte 5", err);
    assert(!parseJson(`[1] x`, v, err) && err == "invalid JSON at byte 4", err);
    foreach (bad; [`01`, `+1`, `1.`, `.5`, `1e`, `-`, `1.5.2`, `0x10`, `--1`, `1e+`, `Infinity`, `NaN`, `tru`, `"a`, `[1,]`,
        `{"a":1,}`, `{1:2}`, ``, `   `])
        assert(!parseJson(bad, v, err), bad);
    foreach (good; [`0`, `-0`, `0.5`, `-1.25e-3`, `1E5`, `9223372036854775807`, `-9223372036854775808`, ` [ ] `, `""`])
        assert(parseJson(good, v, err), good ~ ": " ~ err);
    assert(parseJson(`9223372036854775808`, v, err) && v.isFloat, "too big for a long: floating");
    assert(!parseJson(`1e999`, v, err) && err == "number out of range (or longer than 63 characters) at byte 0", err);

    string deep;
    foreach (i; 0 .. 64)
        deep ~= "[";
    foreach (i; 0 .. 64)
        deep ~= "]";
    assert(parseJson(deep, v, err), "64 levels are fine");
    assert(!parseJson("[" ~ deep ~ "]", v, err) && err == "JSON nested deeper than 64 levels at byte 64", err);
    assert(!parseJson(`{"a":[1]}`, v, err, JsonLimits(1)) && err == "JSON nested deeper than 1 levels at byte 5", err);
    assert(!parseJson(`[1,2]`, v, err, JsonLimits(64, 4)) && err == "JSON longer than 4 bytes", err);

    ubyte[] raw = cast(ubyte[]) `{"a":["x","`.dup ~ [cast(ubyte) 0xff] ~ cast(ubyte[]) `"]}`.dup;
    assert(!parseJson(cast(const(char)[]) raw, v, err) && err == `invalid UTF-8 at "a",1`, err);

    bool threw;
    try
        parseJson(`nul`);
    catch (JsonError e)
        threw = e.msg == "vela: invalid JSON at byte 0";
    assert(threw);
}
