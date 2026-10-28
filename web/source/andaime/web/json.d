/// Minimal reflection-driven JSON: writes straight into the response buffer
/// and reads without an intermediate DOM. Light Phobos only; no std.json.
module andaime.web.json 2025;

@safe:

import andaime.http.buffer;
import andaime.web.dto;
import andaime.web.params : Optional, isOptional, isCharType, PatchField, isPatchField;
import andaime.web.convert : parseInteger, parseFloat, parseErrorType, parseErrorMsg, parseErrorParams;
import andaime.web.numtext : itoa;
import andaime.http.utf8 : validUtf8;
import andaime.http.texttype : isTextType, textFromString, textToString;
import andaime.http.naming : enumWireNames, parseEnumWire;
import andaime.web.jsonvalue : Json, JsonValue, readJsonValue, writeJsonValue;
// The text layer (string escaping, the pull reader) lives in andaime:http; this module keeps its old names.
public import andaime.http.jsontext : writeJsonString, writeJsonEscaped, JsonReader, decodeJsonString;

// =====================================================================
// Writing
// =====================================================================

void writeJson(T)(ref ByteBuffer o, ref const T v)
{
    static if (is(T == JsonValue))
        writeJsonValue(o, v);
    else static if (is(T == Json!U, U))
        writeJson(o, v.value); // before the text-type branch: the value, not a string holding it
    else static if (is(T == bool))
        o.put(v ? "true" : "false");
    else static if (is(T == enum))
        writeEnum(o, v);
    else static if (__traits(isIntegral, T) && !isCharType!T)
    {
        static if (__traits(isUnsigned, T))
            o.putUint(v);
        else
            o.putInt(v);
    }
    else static if (__traits(isFloating, T))
        o.putFloat(v);
    else static if (is(T : const(char)[]))
        writeJsonString(o, v);
    else static if (is(T == Optional!U, U))
    {
        if (v.has)
            writeJson(o, v.get);
        else
            o.put("null");
    }
    else static if (is(T == PatchField!U, U))
    {
        // a struct member that is absent is left out of its object (below); anywhere else absent is written as null
        if (v.hasValue)
            writeJson(o, v.value);
        else
            o.put("null");
    }
    else static if (is(T == V[K], V, K) && is(K == string))
    {
        // an object; the order is the associative array's own (unspecified)
        o.put('{');
        bool first = true;
        foreach (k, ref val; v)
        {
            if (!first)
                o.put(',');
            first = false;
            writeJsonString(o, k);
            o.put(':');
            writeJson(o, val);
        }
        o.put('}');
    }
    else static if (is(T == U[], U) || is(T == U[n], U, size_t n))
    {
        o.put('[');
        foreach (i, ref e; v)
        {
            if (i)
                o.put(',');
            writeJson(o, e);
        }
        o.put(']');
    }
    else static if (isTextType!T)
    {
        // a text type is a JSON string: its toString writes the text, escaped on the way
        o.put('"');
        textToString(v, (scope const(char)[] piece) { writeJsonEscaped(o, piece); });
        o.put('"');
    }
    else static if (is(T == struct))
    {
        o.put('{');
        bool first = true;
        static foreach (i; 0 .. T.tupleof.length)
        {
            static if (!hasUda!(T, i, jsonIgnore))
            {
                // an absent PatchField, and an empty Optional marked @omitIfAbsent, are not written at all
                if (isPresentField!(omitsAbsent!(T, i))(v.tupleof[i]))
                {
                    if (!first)
                        o.put(',');
                    first = false;
                    o.put(quotedKey!(T, i)); // "\"name\":" ready at compile time
                    writeJson(o, v.tupleof[i]);
                }
            }
        }
        o.put('}');
    }
    else
        static assert(0, "andaime: type '" ~ T.stringof ~ "' is not serializable to JSON. "
            ~ "Use bool, numbers, string, enum, arrays, string-keyed maps, structs, Optional!T or PatchField!T.");
}

private enum string quotedKey(T, size_t i) = "\"" ~ jsonKeyOf!(T, i) ~ "\":";

/// Whether a struct member is written: always, except an absent `PatchField` and, with `omit`, an empty `Optional`.
private bool isPresentField(bool omit, F)(ref const F f)
{
    static if (isPatchField!F)
        return f.isPresent;
    else static if (omit && isOptional!F)
        return f.has;
    else
        return true;
}

private void writeEnum(E)(ref ByteBuffer o, E v)
{
    // (a wire name never needs escaping: `enumWireNames` refuses quotes, backslashes and control characters)
    enum names = enumWireNames!E;
    static foreach (k, m; __traits(allMembers, E))
        if (v == __traits(getMember, E, m))
        {
            o.put("\"" ~ names[k] ~ "\"");
            return;
        }
    o.put("null");
}

/// Type error: records it and skips the value (parsing continues, to
/// report all the wrong fields at once, like FastAPI).
private bool typeMismatch(ref JsonReader r, ref FieldErrors errs, ref const FieldPath path, string type, string msg,
    FieldParams params = FieldParams.init)
{
    errs.addPath(path, type, msg, params);
    return r.skipValue();
}

/// Reads a JSON value into `v`. Returns false only on a syntax error;
/// type and validation errors go to `errs`.
bool readJson(T)(ref JsonReader r, ref T v, ref FieldErrors errs, ref FieldPath path)
{
    static if (is(T == JsonValue))
        return readJsonValue(r, v, errs, path, 0);
    else static if (is(T == Json!U, U))
        return readJson(r, v.value, errs, path);
    else static if (is(T == bool))
    {
        if (r.literal("true"))
            v = true;
        else if (r.literal("false"))
            v = false;
        else
            return typeMismatch(r, errs, path, parseErrorType!T, parseErrorMsg!T, parseErrorParams!T);
    }
    else static if (is(T == enum))
    {
        if (!r.peekIs('"'))
            return typeMismatch(r, errs, path, parseErrorType!T, parseErrorMsg!T, parseErrorParams!T);
        const(char)[] raw;
        bool esc;
        if (!r.rawString(raw, esc))
            return false;
        if (!parseEnumWire(raw, v))
            errs.addPath(path, parseErrorType!T, parseErrorMsg!T, parseErrorParams!T);
    }
    else static if (__traits(isIntegral, T) && !isCharType!T)
    {
        if (!r.peekNumber())
            return typeMismatch(r, errs, path, parseErrorType!T, parseErrorMsg!T, parseErrorParams!T);
        const(char)[] tok;
        if (!r.number(tok))
            return false;
        if (!parseInteger(tok, v))
            errs.addPath(path, parseErrorType!T, parseErrorMsg!T, parseErrorParams!T);
    }
    else static if (__traits(isFloating, T))
    {
        if (!r.peekNumber())
            return typeMismatch(r, errs, path, parseErrorType!T, parseErrorMsg!T, parseErrorParams!T);
        const(char)[] tok;
        if (!r.number(tok))
            return false;
        if (!parseFloat(tok, v))
            errs.addPath(path, parseErrorType!T, parseErrorMsg!T, parseErrorParams!T);
    }
    else static if (is(string : T)) // string, const(char)[]
    {
        if (!r.peekIs('"'))
            return typeMismatch(r, errs, path, "string_type", "expected a string");
        const(char)[] raw;
        bool esc;
        if (!r.rawString(raw, esc))
            return false;
        if (!validUtf8(raw)) // escapes decode to valid UTF-8 (lone surrogates are rejected), so the raw text decides
        {
            errs.addPath(path, "string_unicode", "invalid UTF-8");
            return true;
        }
        string decoded;
        if (!decodeJsonString(raw, esc, decoded))
            return r.syntax();
        v = decoded;
    }
    else static if (isTextType!T)
    {
        if (!r.peekIs('"'))
            return typeMismatch(r, errs, path, "string_type", "expected a string");
        const(char)[] raw;
        bool esc;
        if (!r.rawString(raw, esc))
            return false;
        if (!validUtf8(raw))
        {
            errs.addPath(path, "string_unicode", "invalid UTF-8");
            return true;
        }
        string decoded;
        if (!decodeJsonString(raw, esc, decoded))
            return r.syntax();
        if (!textFromString(decoded, v))
            errs.addPath(path, parseErrorType!T, parseErrorMsg!T, parseErrorParams!T);
    }
    else static if (is(T == Optional!U, U))
    {
        if (r.literal("null"))
            v = T.init;
        else
        {
            U tmp;
            if (!readJson(r, tmp, errs, path))
                return false;
            v = T(tmp);
        }
    }
    else static if (is(T == PatchField!U, U))
    {
        // present: null or a value (absent is the initial state, kept when the key never shows up)
        if (r.literal("null"))
            v = T.null_;
        else
        {
            U tmp;
            if (!readJson(r, tmp, errs, path))
                return false;
            v = T(tmp);
        }
    }
    else static if (is(T == V[K], V, K) && is(K == string))
    {
        // {"a": 1, "b": 2} -> int[string]; a repeated key keeps its last value
        if (!r.eat('{'))
            return typeMismatch(r, errs, path, "dict_type", "expected an object");
        T map;
        if (!r.eat('}'))
        {
            do
            {
                const(char)[] rawKey;
                bool kesc;
                if (!r.rawString(rawKey, kesc) || !r.eat(':'))
                    return r.syntax();
                string key;
                if (!validUtf8(rawKey))
                {
                    errs.addPath(path, "string_unicode", "invalid UTF-8");
                    if (!r.skipValue())
                        return false;
                    continue;
                }
                if (!decodeJsonString(rawKey, kesc, key))
                    return r.syntax();
                V item;
                immutable mark = path.pushKey(key);
                if (!readJson(r, item, errs, path))
                    return false;
                path.pop(mark);
                map[key] = item;
            }
            while (r.eat(','));
            if (!r.eat('}'))
                return r.syntax();
        }
        v = map;
    }
    else static if (is(T == U[], U))
    {
        if (!r.eat('['))
            return typeMismatch(r, errs, path, "list_type", "expected an array");
        v = null;
        if (r.eat(']'))
            return true;
        do
        {
            U e;
            immutable mark = path.pushIndex(v.length);
            if (!readJson(r, e, errs, path))
                return false;
            path.pop(mark);
            v ~= e;
        }
        while (r.eat(','));
        if (!r.eat(']'))
            return r.syntax();
    }
    else static if (is(T == struct))
    {
        if (!r.eat('{'))
            return typeMismatch(r, errs, path, "model_type", "expected an object");
        bool[T.tupleof.length] seen;
        if (!r.eat('}'))
        {
            do
            {
                const(char)[] key;
                bool esc;
                if (!r.rawString(key, esc) || !r.eat(':'))
                    return r.syntax();
                bool known = false;
                keys: switch (key) // string switch generated by static foreach
                {
                    static foreach (i; 0 .. T.tupleof.length)
                    {
                        static if (!hasUda!(T, i, jsonIgnore))
                        {
                            case jsonKeyOf!(T, i):
                                known = true;
                                seen[i] = true;
                                {
                                    immutable mark = path.pushKey(jsonKeyOf!(T, i));
                                    if (!readJson(r, v.tupleof[i], errs, path))
                                        return false;
                                    path.pop(mark);
                                }
                                break keys;
                        }
                    }
                    default:
                        break;
                }
                if (!known)
                {
                    static if (isStrict!T)
                    {
                        // the path keeps the name past this call: copy it (an error path, so the allocation is fine)
                        string name = key.idup;
                        if (esc && !decodeJsonString(key, true, name))
                            return r.syntax();
                        immutable mark = path.pushKey(name);
                        errs.addPath(path, "extra_forbidden", "Extra inputs are not permitted");
                        path.pop(mark);
                    }
                    if (!r.skipValue())
                        return false; // unknown fields are ignored, unless T is @strict (reported above)
                }
            }
            while (r.eat(','));
            if (!r.eat('}'))
                return r.syntax();
        }
        static foreach (i; 0 .. T.tupleof.length)
        {
            static if (!hasUda!(T, i, jsonIgnore))
            {{
                immutable mark = path.pushKey(jsonKeyOf!(T, i));
                static if (!hasUda!(T, i, optional) && !isOptional!(typeof(T.tupleof[i]))
                    && !isPatchField!(typeof(T.tupleof[i])))
                {
                    if (!seen[i])
                        errs.addPath(path, "missing", "Field required");
                }
                if (seen[i])
                    validateField!(T, i)(v.tupleof[i], errs, path);
                path.pop(mark);
            }}
        }
    }
    else
        static assert(0, "andaime: type '" ~ T.stringof ~ "' cannot be read from JSON. "
            ~ "Use bool, numbers, string, enum, arrays, string-keyed maps, structs, Optional!T or PatchField!T.");
    return true;
}

/// Decodes a whole JSON document into `v`. False if there was any error.
bool decodeJson(T)(const(char)[] text, ref T v, ref FieldErrors errs)
{
    auto r = JsonReader(text);
    FieldPath path;
    immutable before = errs.count;
    if (!readJson(r, v, errs, path))
    {
        // a syntax error makes the type errors found before it meaningless (they may come from the cut-off text)
        errs.count = before;
        errs.add("body", "", "json_invalid", r.errorText());
        return false;
    }
    r.ws();
    if (r.pos != text.length)
    {
        errs.add("body", "", "json_invalid", "invalid JSON at byte " ~ itoa(r.pos));
        return false;
    }
    return errs.count == before;
}

unittest
{
    enum Role { admin, user }
    struct Address { @minLength(8) string cep; }
    struct Dto
    {
        @minLength(3) string name;
        @inRange(0, 150) int age;
        Role role;
        Optional!string email;
        @jsonKey("tags_list") string[] tags;
        Address address;
        @jsonIgnore int secret = 7;
    }

    FieldErrors errs;
    Dto d;
    assert(decodeJson(`{"name":"Ana é \"x\"","age":30,"role":"admin","tags_list":["a","b"],`
        ~ `"address":{"cep":"01310-100"},"extra":{"deep":[1,2,{"x":null}]}}`, d, errs));
    assert(d.name == "Ana é \"x\"" && d.age == 30 && d.role == Role.admin && !d.email.has);
    assert(d.tags == ["a", "b"] && d.address.cep == "01310-100" && d.secret == 7);

    ByteBuffer b;
    writeJson(b, d);
    assert(b.data == `{"name":"Ana é \"x\"","age":30,"role":"admin","email":null,`
        ~ `"tags_list":["a","b"],"address":{"cep":"01310-100"}}`, b.data.idup);

    // several errors reported at once, with the field path and a machine-readable type
    errs.clear();
    Dto e;
    assert(!decodeJson(`{"name":"Al","age":"x","role":"root","tags_list":[],"address":{"cep":"1"}}`, e, errs));
    assert(errorSummary(errs) == [`int_parsing body,"age"`, `enum body,"role"`, `string_too_short body,"address","cep"`,
        `string_too_short body,"name"`], errorSummary(errs).to!string);
    assert(errs.list[0].message == "expected an integer between -2147483648 and 2147483647", errs.list[0].message);
    assert(errs.list[1].message == "expected one of: admin, user");
    assert(errs.list[2].message == "expected at least 8 characters");

    // syntax: the byte where parsing stopped
    errs.clear();
    assert(!decodeJson(`{"name": }`, e, errs));
    assert(errs.list[$ - 1].type == "json_invalid" && errs.list[$ - 1].message == "invalid JSON at byte 9", errs.list[$ - 1].message);
    errs.clear();
    assert(!decodeJson(`{"name":"Ana","age":1,"role":"user"} x`, e, errs));
    assert(errs.list[$ - 1].type == "json_invalid" && errs.list[$ - 1].message == "invalid JSON at byte 37");
}

version (unittest)
{
    import std.conv : to;

    /// "type location,locJson" of every error, for assertions.
    string[] errorSummary(ref const FieldErrors errs)
    {
        string[] r;
        foreach (ref fe; errs.list)
            r ~= fe.type ~ " " ~ fe.location ~ (fe.locJson.length ? "," ~ fe.locJson : "");
        return r;
    }
}

unittest
{
    struct Item { @minLength(2) string code; int qty; }
    struct Order { Item[] items; string[] tags; @maxLength(2) int[] ids; Optional!Item extra; }

    // the array index is part of loc; nested objects inside arrays too
    FieldErrors errs;
    Order o;
    assert(!decodeJson(`{"items":[{"code":"ab","qty":1},{"code":"x","qty":"no"},{"qty":2}],"tags":["a",5],"ids":[1,2,3]}`, o, errs));
    assert(errorSummary(errs) == [`int_parsing body,"items",1,"qty"`, `string_too_short body,"items",1,"code"`,
        `missing body,"items",2,"code"`, `string_type body,"tags",1`, `too_long body,"ids"`], errorSummary(errs).to!string);
    assert(errs.list[4].message == "expected at most 2 items");

    // wrong JSON kinds
    errs.clear();
    assert(!decodeJson(`{"items":{},"tags":"x","ids":[]}`, o, errs));
    assert(errorSummary(errs) == [`list_type body,"items"`, `list_type body,"tags"`]);
    errs.clear();
    assert(!decodeJson(`[1]`, o, errs));
    assert(errorSummary(errs) == [`model_type body`] && errs.list[0].message == "expected an object");
    errs.clear();
    Item it;
    assert(!decodeJson(`{"code":"ok","qty":1.5}`, it, errs) && errs.list[0].type == "int_parsing");
    errs.clear();
    assert(!decodeJson(`{"code":"ok","qty":99999999999}`, it, errs) && errs.list[0].type == "int_parsing");
}

unittest
{
    // lengths count characters, not bytes
    struct Name { @minLength(3) @maxLength(4) string v; }
    FieldErrors errs;
    Name n;
    assert(!decodeJson(`{"v":"çã"}`, n, errs) && errs.list[0].type == "string_too_short");
    errs.clear();
    assert(decodeJson(`{"v":"çãõ"}`, n, errs), "3 characters (6 bytes) satisfy minLength(3)");
    errs.clear();
    assert(decodeJson(`{"v":"çãõé"}`, n, errs), "4 characters (8 bytes) satisfy maxLength(4)");
    errs.clear();
    assert(!decodeJson(`{"v":"çãõéü"}`, n, errs) && errs.list[0].type == "string_too_long");
    errs.clear();
    assert(decodeJson(`{"v":"a\u00e7\u00e3"}`, n, errs), "escapes count as characters too");

    // invalid UTF-8 is an error, never a D string
    errs.clear();
    ubyte[] bad = cast(ubyte[]) `{"v":"abc`.dup ~ [cast(ubyte) 0xff] ~ cast(ubyte[]) `"}`.dup;
    assert(!decodeJson(cast(const(char)[]) bad, n, errs));
    assert(errs.list[0].type == "string_unicode" && errs.list[0].message == "invalid UTF-8");
}

unittest
{
    // @inRange: separate codes for each side, with the bound in the message
    struct R { @inRange(0, 150) int age; @inRange(0.5, 1.5) double ratio; }
    FieldErrors errs;
    R r;
    assert(!decodeJson(`{"age":-1,"ratio":2}`, r, errs));
    assert(errorSummary(errs) == [`greater_than_equal body,"age"`, `less_than_equal body,"ratio"`]);
    assert(errs.list[0].message == "must be >= 0" && errs.list[1].message == "must be <= 1.5");

    // too deep a path is cut with "..."
    FieldPath p;
    foreach (i; 0 .. 40)
        p.pushKey("k");
    assert(p.render().length > 0 && p.render()[$ - 6 .. $] == `,"..."`);

    // more errors than the capacity: counted, not lost silently
    struct Many { int[] v; }
    errs.clear();
    Many m;
    string js = `{"v":[`;
    foreach (i; 0 .. 20)
        js ~= (i ? `,"x"` : `"x"`);
    js ~= `]}`;
    assert(!decodeJson(js, m, errs));
    assert(errs.count == FieldErrors.capacity && errs.dropped == 4);
}

unittest
{
    // PatchField: absent, null and a value are three different things; never required; validated only with a value
    struct Address { string city; PatchField!string zip; }
    struct Upd
    {
        @minLength(3) PatchField!string nick;
        @inRange(0, 150) PatchField!int age;
        PatchField!Address address;
        PatchField!(string[]) tags;
    }

    FieldErrors errs;
    Upd u;
    assert(decodeJson(`{}`, u, errs));
    assert(u.nick.isAbsent && u.age.isAbsent && u.address.isAbsent && u.tags.isAbsent);
    assert(decodeJson(`{"nick":null,"age":30,"address":{"city":"Rio","zip":null},"tags":["a"]}`, u, errs));
    assert(u.nick.isNull && u.age.value == 30 && u.address.value.city == "Rio" && u.address.value.zip.isNull);
    assert(u.tags.value == ["a"]);

    ByteBuffer b;
    writeJson(b, u);
    assert(b.data == `{"nick":null,"age":30,"address":{"city":"Rio","zip":null},"tags":["a"]}`, b.data.idup);
    b.clear();
    Upd none;
    writeJson(b, none);
    assert(b.data == `{}`, b.data.idup);
    b.clear();
    auto arr = [PatchField!int.init, PatchField!int.null_, PatchField!int(1)];
    writeJson(b, arr);
    assert(b.data == `[null,null,1]`, "outside an object, absent is null");

    // wrong values report the field's path; null skips validation
    errs.clear();
    Upd e;
    assert(!decodeJson(`{"nick":"ab","age":"x","address":{"zip":5}}`, e, errs));
    assert(errorSummary(errs) == [`int_parsing body,"age"`, `string_type body,"address","zip"`,
        `missing body,"address","city"`, `string_too_short body,"nick"`], errorSummary(errs).to!string);
    errs.clear();
    assert(decodeJson(`{"nick":null,"age":null}`, e, errs));
    errs.clear();
    assert(!decodeJson(`{"age":151}`, e, errs) && errs.list[0].type == "less_than_equal");

    // in arrays of structs
    struct Batch { Upd[] items; }
    errs.clear();
    Batch bt;
    assert(!decodeJson(`{"items":[{},{"nick":null},{"nick":"x"}]}`, bt, errs));
    assert(errorSummary(errs) == [`string_too_short body,"items",2,"nick"`], errorSummary(errs).to!string);
    assert(bt.items[0].nick.isAbsent && bt.items[1].nick.isNull && bt.items[2].nick.hasValue);
}
