/// Minimal reflection-driven JSON: writes straight into the response buffer
/// and reads without an intermediate DOM. Light Phobos only; no std.json.
module vela.web.json;

@safe:

import vela.http.buffer;
import vela.web.dto;
import vela.web.params : Optional, isOptional, isCharType, PatchField, isPatchField;
import vela.web.convert : parseInteger, parseFloat, parseErrorType, parseErrorMsg;
import vela.web.numtext : itoa;
import vela.http.utf8 : validUtf8;
import vela.http.texttype : isTextType, textFromString, textToString;
import vela.web.jsonvalue : JsonValue, readJsonValue, writeJsonValue;

// =====================================================================
// Writing
// =====================================================================

void writeJson(T)(ref ByteBuffer o, ref const T v)
{
    static if (is(T == JsonValue))
        writeJsonValue(o, v);
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
                // an absent PatchField is not written at all
                if (!isPatchField!(typeof(T.tupleof[i])) || isPresentField(v.tupleof[i]))
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
        static assert(0, "vela: type '" ~ T.stringof ~ "' is not serializable to JSON. "
            ~ "Use bool, numbers, string, enum, arrays, string-keyed maps, structs, Optional!T or PatchField!T.");
}

private enum string quotedKey(T, size_t i) = "\"" ~ jsonKeyOf!(T, i) ~ "\":";

/// Whether a struct member is written: always, except an absent `PatchField`.
private bool isPresentField(F)(ref const F f)
{
    static if (isPatchField!F)
        return f.isPresent;
    else
        return true;
}

private void writeEnum(E)(ref ByteBuffer o, E v)
{
    static foreach (m; __traits(allMembers, E))
        if (v == __traits(getMember, E, m))
        {
            o.put("\"" ~ m ~ "\"");
            return;
        }
    o.put("null");
}

void writeJsonString(ref ByteBuffer o, scope const(char)[] s) nothrow @nogc @safe
{
    o.put('"');
    writeJsonEscaped(o, s);
    o.put('"');
}

/// The characters of `s` as they go inside a JSON string (no quotes).
void writeJsonEscaped(ref ByteBuffer o, scope const(char)[] s) nothrow @nogc @safe
{
    static immutable char[16] hexd = "0123456789abcdef";
    size_t start = 0;
    foreach (i, char c; s)
    {
        if (c != '"' && c != '\\' && c >= 0x20)
            continue;
        o.put(s[start .. i]);
        switch (c)
        {
            case '"': o.put(`\"`); break;
            case '\\': o.put(`\\`); break;
            case '\n': o.put(`\n`); break;
            case '\r': o.put(`\r`); break;
            case '\t': o.put(`\t`); break;
            default:
                o.put(`\u00`);
                o.put(hexd[c >> 4]);
                o.put(hexd[c & 15]);
        }
        start = i + 1;
    }
    o.put(s[start .. $]);
}

// =====================================================================
// Reading
// =====================================================================

struct JsonReader
{
    const(char)[] s;
    size_t pos;
    size_t errorPos = size_t.max;
    string errorWhy; /// what broke, when it was more than a syntax error ("JSON nested deeper than 64 levels")

    /// The error as one line: `invalid JSON at byte 12`, or `<errorWhy> at byte 12`.
    string errorText() const pure nothrow @safe
        => (errorWhy.length ? errorWhy : "invalid JSON") ~ " at byte " ~ itoa(errorPos == size_t.max ? pos : errorPos);

nothrow @nogc @safe:

    /// Flags an error that is not plain syntax (a broken limit); aborts the parse like `syntax`.
    bool fail(string why)
    {
        if (errorPos == size_t.max)
        {
            errorPos = pos;
            errorWhy = why;
        }
        return false;
    }

    void ws()
    {
        while (pos < s.length && (s[pos] == ' ' || s[pos] == '\t' || s[pos] == '\n' || s[pos] == '\r'))
            pos++;
    }

    bool eat(char c)
    {
        ws();
        if (pos < s.length && s[pos] == c)
        {
            pos++;
            return true;
        }
        return false;
    }

    bool peekIs(char c)
    {
        ws();
        return pos < s.length && s[pos] == c;
    }

    bool peekNumber()
    {
        ws();
        return pos < s.length && (s[pos] == '-' || (s[pos] >= '0' && s[pos] <= '9'));
    }

    /// Flags a syntax error (aborts the parse).
    bool syntax()
    {
        if (errorPos == size_t.max)
            errorPos = pos;
        return false;
    }

    bool literal(string lit)
    {
        ws();
        if (s.length - pos >= lit.length && s[pos .. pos + lit.length] == lit)
        {
            pos += lit.length;
            return true;
        }
        return false;
    }

    /// Raw quoted string (slice of the text); `escaped` says whether it needs decoding.
    bool rawString(out const(char)[] raw, out bool escaped)
    {
        ws();
        if (pos >= s.length || s[pos] != '"')
            return syntax();
        immutable st = ++pos;
        while (pos < s.length)
        {
            immutable char c = s[pos];
            if (c == '"')
            {
                raw = s[st .. pos++];
                return true;
            }
            if (c == '\\')
            {
                escaped = true;
                pos += 2;
                continue;
            }
            if (c < 0x20)
                return syntax();
            pos++;
        }
        return syntax();
    }

    bool number(out const(char)[] tok)
    {
        ws();
        immutable st = pos;
        while (pos < s.length)
        {
            immutable char c = s[pos];
            if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E')
                pos++;
            else
                break;
        }
        tok = s[st .. pos];
        if (tok.length == 0)
            return syntax();
        return true;
    }

    bool skipValue(int depth = 0)
    {
        if (depth > 64)
            return syntax();
        ws();
        if (pos >= s.length)
            return syntax();
        const(char)[] raw;
        bool esc;
        switch (s[pos])
        {
            case '"':
                return rawString(raw, esc);
            case '{':
                pos++;
                if (eat('}'))
                    return true;
                do
                {
                    if (!rawString(raw, esc) || !eat(':') || !skipValue(depth + 1))
                        return syntax();
                }
                while (eat(','));
                return eat('}') || syntax();
            case '[':
                pos++;
                if (eat(']'))
                    return true;
                do
                {
                    if (!skipValue(depth + 1))
                        return false;
                }
                while (eat(','));
                return eat(']') || syntax();
            case 't':
                return literal("true") || syntax();
            case 'f':
                return literal("false") || syntax();
            case 'n':
                return literal("null") || syntax();
            default:
                return number(raw);
        }
    }
}

/// Decodes JSON escapes into a new string (GC). Without escapes: just `idup`.
bool decodeJsonString(scope const(char)[] raw, bool escaped, out string result) @safe pure nothrow
{
    if (!escaped)
    {
        result = raw.idup;
        return true;
    }
    static int hex4(scope const(char)[] h) pure nothrow @nogc
    {
        int v = 0;
        foreach (char c; h)
        {
            v <<= 4;
            if (c >= '0' && c <= '9') v |= c - '0';
            else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
            else return -1;
        }
        return v;
    }

    char[] o;
    o.reserve(raw.length);
    for (size_t i = 0; i < raw.length; i++)
    {
        char c = raw[i];
        if (c != '\\')
        {
            o ~= c;
            continue;
        }
        if (++i >= raw.length)
            return false;
        switch (raw[i])
        {
            case '"': o ~= '"'; break;
            case '\\': o ~= '\\'; break;
            case '/': o ~= '/'; break;
            case 'b': o ~= '\b'; break;
            case 'f': o ~= '\f'; break;
            case 'n': o ~= '\n'; break;
            case 'r': o ~= '\r'; break;
            case 't': o ~= '\t'; break;
            case 'u':
                if (i + 4 >= raw.length)
                    return false;
                int cp = hex4(raw[i + 1 .. i + 5]);
                i += 4;
                if (cp < 0)
                    return false;
                if (cp >= 0xD800 && cp <= 0xDBFF) // surrogate pair
                {
                    if (i + 6 >= raw.length || raw[i + 1] != '\\' || raw[i + 2] != 'u')
                        return false;
                    int lo = hex4(raw[i + 3 .. i + 7]);
                    if (lo < 0xDC00 || lo > 0xDFFF)
                        return false;
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    i += 6;
                }
                else if (cp >= 0xDC00 && cp <= 0xDFFF)
                    return false;
                encodeUtf8(o, cp);
                break;
            default:
                return false;
        }
    }
    result = (() @trusted => cast(string) o)(); // sole owner: safe to make immutable
    return true;
}

private void encodeUtf8(ref char[] o, int cp) @safe pure nothrow
{
    if (cp < 0x80)
        o ~= cast(char) cp;
    else if (cp < 0x800)
    {
        o ~= cast(char)(0xC0 | (cp >> 6));
        o ~= cast(char)(0x80 | (cp & 0x3F));
    }
    else if (cp < 0x10000)
    {
        o ~= cast(char)(0xE0 | (cp >> 12));
        o ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
        o ~= cast(char)(0x80 | (cp & 0x3F));
    }
    else
    {
        o ~= cast(char)(0xF0 | (cp >> 18));
        o ~= cast(char)(0x80 | ((cp >> 12) & 0x3F));
        o ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
        o ~= cast(char)(0x80 | (cp & 0x3F));
    }
}

/// Type error: records it and skips the value (parsing continues, to
/// report all the wrong fields at once, like FastAPI).
private bool typeMismatch(ref JsonReader r, ref FieldErrors errs, ref const FieldPath path, string type, string msg)
{
    errs.addPath(path, type, msg);
    return r.skipValue();
}

/// Reads a JSON value into `v`. Returns false only on a syntax error;
/// type and validation errors go to `errs`.
bool readJson(T)(ref JsonReader r, ref T v, ref FieldErrors errs, ref FieldPath path)
{
    static if (is(T == JsonValue))
        return readJsonValue(r, v, errs, path, 0);
    else static if (is(T == bool))
    {
        if (r.literal("true"))
            v = true;
        else if (r.literal("false"))
            v = false;
        else
            return typeMismatch(r, errs, path, parseErrorType!T, parseErrorMsg!T);
    }
    else static if (is(T == enum))
    {
        if (!r.peekIs('"'))
            return typeMismatch(r, errs, path, parseErrorType!T, parseErrorMsg!T);
        const(char)[] raw;
        bool esc;
        if (!r.rawString(raw, esc))
            return false;
        bool ok = false;
        static foreach (m; __traits(allMembers, T))
            if (!ok && raw == m)
            {
                v = __traits(getMember, T, m);
                ok = true;
            }
        if (!ok)
            errs.addPath(path, parseErrorType!T, parseErrorMsg!T);
    }
    else static if (__traits(isIntegral, T) && !isCharType!T)
    {
        if (!r.peekNumber())
            return typeMismatch(r, errs, path, parseErrorType!T, parseErrorMsg!T);
        const(char)[] tok;
        if (!r.number(tok))
            return false;
        if (!parseInteger(tok, v))
            errs.addPath(path, parseErrorType!T, parseErrorMsg!T);
    }
    else static if (__traits(isFloating, T))
    {
        if (!r.peekNumber())
            return typeMismatch(r, errs, path, parseErrorType!T, parseErrorMsg!T);
        const(char)[] tok;
        if (!r.number(tok))
            return false;
        if (!parseFloat(tok, v))
            errs.addPath(path, parseErrorType!T, parseErrorMsg!T);
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
            errs.addPath(path, parseErrorType!T, parseErrorMsg!T);
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
                if (!known && !r.skipValue())
                    return false; // unknown fields are ignored
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
        static assert(0, "vela: type '" ~ T.stringof ~ "' cannot be read from JSON. "
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
        ~ `"tags_list":["a","b"],"address":{"cep":"01310-100"}}`, b.data);

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
    assert(b.data == `{"nick":null,"age":30,"address":{"city":"Rio","zip":null},"tags":["a"]}`, b.data);
    b.clear();
    Upd none;
    writeJson(b, none);
    assert(b.data == `{}`, b.data);
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
