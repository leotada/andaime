/// JSON text: escaping a string into a buffer, a pull reader over the text (tokens, strings, numbers, skipping), and
/// decoding a string's escapes. The typed reader and writer (`andaime.web.json`) and `JsonValue` sit on top of it.
module andaime.http.jsontext 2025;

@safe:

import andaime.http.buffer : ByteBuffer;
import andaime.http.numtext : itoa;

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

