/// JSON mínimo guiado por reflexão: escreve direto no buffer de resposta
/// e lê sem DOM intermediário. Só a Phobos leve; sem std.json.
module vela.web.json;

import vela.http.buffer;
import vela.web.dto;
import vela.web.params : Optional, isOptional, isCharType;
import vela.web.convert : parseInteger, parseFloat, typeHint;

// =====================================================================
// Escrita
// =====================================================================

void writeJson(T)(ref ByteBuffer o, ref const T v)
{
    static if (is(T == bool))
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
    else static if (is(T == struct))
    {
        o.put('{');
        bool first = true;
        static foreach (i; 0 .. T.tupleof.length)
        {
            static if (!hasUda!(T, i, jsonIgnore))
            {
                if (!first)
                    o.put(',');
                first = false;
                o.put(quotedKey!(T, i)); // "\"nome\":" pronto em compilação
                writeJson(o, v.tupleof[i]);
            }
        }
        o.put('}');
    }
    else
        static assert(0, "vela: o tipo '" ~ T.stringof ~ "' não é serializável em JSON. "
            ~ "Use bool, números, string, enum, arrays, structs ou Optional!T.");
}

private enum string quotedKey(T, size_t i) = "\"" ~ jsonKeyOf!(T, i) ~ "\":";

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
    static immutable char[16] hexd = "0123456789abcdef";
    o.put('"');
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
    o.put('"');
}

// =====================================================================
// Leitura
// =====================================================================

struct JsonReader
{
    const(char)[] s;
    size_t pos;
    size_t errorPos = size_t.max;

nothrow @nogc @safe:

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

    /// Marca erro de sintaxe (aborta o parse).
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

    /// String crua entre aspas (fatia do texto); `escaped` diz se precisa decodificar.
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

/// Decodifica escapes JSON para uma string nova (GC). Sem escapes: só `idup`.
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
                if (cp >= 0xD800 && cp <= 0xDBFF) // par substituto
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
    result = (() @trusted => cast(string) o)(); // único dono: seguro tornar imutável
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

/// Erro de tipo: registra e pula o valor (o parse continua, para
/// reportar todos os campos errados de uma vez, como o FastAPI).
private bool typeMismatch(ref JsonReader r, ref FieldErrors errs, ref const FieldPath path, string msg)
{
    errs.add("body", path.current.idup, msg);
    return r.skipValue();
}

/// Lê um valor JSON em `v`. Retorna false só em erro de sintaxe;
/// erros de tipo e validação vão para `errs`.
bool readJson(T)(ref JsonReader r, ref T v, ref FieldErrors errs, ref FieldPath path)
{
    static if (is(T == bool))
    {
        if (r.literal("true"))
            v = true;
        else if (r.literal("false"))
            v = false;
        else
            return typeMismatch(r, errs, path, typeHint!T);
    }
    else static if (is(T == enum))
    {
        if (!r.peekIs('"'))
            return typeMismatch(r, errs, path, typeHint!T);
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
            errs.add("body", path.current.idup, typeHint!T);
    }
    else static if (__traits(isIntegral, T) && !isCharType!T)
    {
        if (!r.peekNumber())
            return typeMismatch(r, errs, path, typeHint!T);
        const(char)[] tok;
        if (!r.number(tok))
            return false;
        if (!parseInteger(tok, v))
            errs.add("body", path.current.idup, typeHint!T);
    }
    else static if (__traits(isFloating, T))
    {
        if (!r.peekNumber())
            return typeMismatch(r, errs, path, typeHint!T);
        const(char)[] tok;
        if (!r.number(tok))
            return false;
        if (!parseFloat(tok, v))
            errs.add("body", path.current.idup, typeHint!T);
    }
    else static if (is(string : T)) // string, const(char)[]
    {
        if (!r.peekIs('"'))
            return typeMismatch(r, errs, path, "esperado string");
        const(char)[] raw;
        bool esc;
        if (!r.rawString(raw, esc))
            return false;
        string decoded;
        if (!decodeJsonString(raw, esc, decoded))
            return r.syntax();
        v = decoded;
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
    else static if (is(T == U[], U))
    {
        if (!r.eat('['))
            return typeMismatch(r, errs, path, "esperado array");
        v = null;
        if (r.eat(']'))
            return true;
        do
        {
            U e;
            if (!readJson(r, e, errs, path))
                return false;
            v ~= e;
        }
        while (r.eat(','));
        if (!r.eat(']'))
            return r.syntax();
    }
    else static if (is(T == struct))
    {
        if (!r.eat('{'))
            return typeMismatch(r, errs, path, "esperado objeto");
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
                keys: switch (key) // switch de strings gerado por static foreach
                {
                    static foreach (i; 0 .. T.tupleof.length)
                    {
                        static if (!hasUda!(T, i, jsonIgnore))
                        {
                            case jsonKeyOf!(T, i):
                                known = true;
                                seen[i] = true;
                                {
                                    immutable mark = path.push(jsonKeyOf!(T, i));
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
                    return false; // campos desconhecidos são ignorados
            }
            while (r.eat(','));
            if (!r.eat('}'))
                return r.syntax();
        }
        static foreach (i; 0 .. T.tupleof.length)
        {
            static if (!hasUda!(T, i, jsonIgnore))
            {{
                immutable mark = path.push(jsonKeyOf!(T, i));
                static if (!hasUda!(T, i, optional) && !isOptional!(typeof(T.tupleof[i])))
                {
                    if (!seen[i])
                        errs.add("body", path.current.idup, "campo obrigatório");
                }
                if (seen[i])
                    validateField!(T, i)(v.tupleof[i], errs, path);
                path.pop(mark);
            }}
        }
    }
    else
        static assert(0, "vela: o tipo '" ~ T.stringof ~ "' não pode ser lido de JSON. "
            ~ "Use bool, números, string, enum, arrays, structs ou Optional!T.");
    return true;
}

/// Decodifica um documento JSON inteiro em `v`. Falso se houve qualquer erro.
bool decodeJson(T)(const(char)[] text, ref T v, ref FieldErrors errs)
{
    auto r = JsonReader(text);
    FieldPath path;
    immutable before = errs.count;
    if (!readJson(r, v, errs, path))
    {
        errs.add("body", "", "JSON inválido");
        return false;
    }
    r.ws();
    if (r.pos != text.length)
    {
        errs.add("body", "", "conteúdo extra depois do JSON");
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

    // vários erros reportados de uma vez, com caminho do campo
    errs.clear();
    Dto e;
    assert(!decodeJson(`{"name":"Al","age":"x","role":"root","tags_list":[],"address":{"cep":"1"}}`, e, errs));
    const(char)[][] fields;
    foreach (ref fe; errs.list)
        fields ~= fe.field;
    assert(fields == ["age", "role", "address.cep", "name"]);

    // sintaxe
    errs.clear();
    assert(!decodeJson(`{"name": }`, e, errs) && errs.list[$ - 1].message == "JSON inválido");
}
