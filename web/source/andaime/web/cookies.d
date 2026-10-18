/// Cookies: reading (`Cookie!"name"` parameters, `ctx.cookie("name")`) and writing (`ctx.setCookie`, `ctx.deleteCookie`).
///
///     string whoAmI(Cookie!"session" s) => lookup(s.value);                 // required, a copy you may keep
///     string maybe(Optional!(Cookie!"theme") t) => t.has ? t.get.value : "light";
///
///     void login(Context ctx) { ctx.setCookie("session", token, CookieOptions(maxAge: Optional!long(3600))); }
///
/// `setCookie` is secure by default (`Secure; HttpOnly; SameSite=Lax; Path=/`). For local development over plain HTTP set
/// `secure: false` (browsers refuse `Secure` cookies on http:// origins other than localhost). An invalid name or value is a
/// programming error and throws (so the response is a 500).
module andaime.web.cookies 2025;

@safe:

import andaime.http.types : equalsIgnoreCase, isTchar;
import andaime.http.date : formatHttpDate;
import andaime.http.optional : Optional;
import andaime.web.context : Context;

enum SameSite : ubyte { lax, strict, none }

/// Attributes of a `Set-Cookie`. The defaults are the safe ones.
struct CookieOptions
{
    string path = "/";
    string domain;                        /// "" = the exact host
    Optional!long maxAge;                 /// seconds; 0 deletes the cookie
    Optional!long expires;                /// Unix time in seconds
    bool secure = true;
    bool httpOnly = true;
    SameSite sameSite = SameSite.lax;
}

/// The value of cookie `name` in the request, or null. Reads every `Cookie` header (HTTP/2 may send several) without
/// allocating; a quoted value loses its quotes. The slice is a view of the request: copy it to keep it.
const(char)[] cookie(const Context ctx, scope const(char)[] name) nothrow @nogc
{
    foreach (ref h; ctx.request.headers)
    {
        if (!equalsIgnoreCase(h.name, "cookie"))
            continue;
        auto v = h.value;
        size_t i = 0;
        while (i < v.length)
        {
            while (i < v.length && (v[i] == ' ' || v[i] == '\t' || v[i] == ';'))
                i++;
            size_t nameStart = i;
            while (i < v.length && v[i] != '=' && v[i] != ';')
                i++;
            auto key = v[nameStart .. i];
            const(char)[] val;
            if (i < v.length && v[i] == '=')
            {
                i++;
                while (i < v.length && (v[i] == ' ' || v[i] == '\t'))
                    i++;
                size_t vs = i;
                while (i < v.length && v[i] != ';')
                    i++;
                val = v[vs .. i];
                while (val.length && (val[$ - 1] == ' ' || val[$ - 1] == '\t'))
                    val = val[0 .. $ - 1];
                if (val.length >= 2 && val[0] == '"' && val[$ - 1] == '"')
                    val = val[1 .. $ - 1];
            }
            while (key.length && (key[$ - 1] == ' ' || key[$ - 1] == '\t'))
                key = key[0 .. $ - 1];
            if (key == name)
                return val.ptr is null ? v[0 .. 0] : val; // present but empty is "", not null
        }
    }
    return null;
}

/// Adds a `Set-Cookie` header. Several cookies in one response are fine. Throws on an invalid name, value or attribute.
void setCookie(Context ctx, scope const(char)[] name, scope const(char)[] value, CookieOptions opts = CookieOptions.init)
{
    if (!validCookieName(name))
        throw new Exception("andaime: invalid cookie name (it must be a token: letters, digits and !#$%&'*+-.^_`|~)");
    if (!validCookieValue(value))
        throw new Exception("andaime: invalid cookie value (no spaces, quotes, commas, semicolons, backslashes or control characters; "
            ~ "percent-encode it)");
    if (!validAttribute(opts.path) || !validAttribute(opts.domain))
        throw new Exception("andaime: invalid cookie Path or Domain (no semicolons or control characters)");
    if (opts.sameSite == SameSite.none && !opts.secure)
        throw new Exception("andaime: SameSite=None needs Secure");

    // the header is built in the context's scratch memory (valid for the whole request)
    size_t need = name.length + value.length + opts.path.length + opts.domain.length + 160;
    auto buf = ctx.scratch(need);
    size_t n;
    void put(scope const(char)[] s)
    {
        buf[n .. n + s.length] = s;
        n += s.length;
    }
    void putNum(long v)
    {
        char[20] t = void;
        size_t k = t.length;
        bool neg = v < 0;
        ulong u = neg ? cast(ulong)(-(v + 1)) + 1 : cast(ulong) v;
        do { t[--k] = cast(char)('0' + u % 10); u /= 10; } while (u);
        if (neg) t[--k] = '-';
        put(t[k .. $]);
    }
    put(name);
    put("=");
    put(value);
    if (opts.path.length)
    {
        put("; Path=");
        put(opts.path);
    }
    if (opts.domain.length)
    {
        put("; Domain=");
        put(opts.domain);
    }
    if (opts.maxAge.has)
    {
        put("; Max-Age=");
        putNum(opts.maxAge.get);
    }
    if (opts.expires.has)
    {
        char[29] date = void;
        formatHttpDate(cast(long) opts.expires.get, date);
        put("; Expires=");
        put(date[]);
    }
    if (opts.secure)
        put("; Secure");
    if (opts.httpOnly)
        put("; HttpOnly");
    final switch (opts.sameSite)
    {
        case SameSite.lax: put("; SameSite=Lax"); break;
        case SameSite.strict: put("; SameSite=Strict"); break;
        case SameSite.none: put("; SameSite=None"); break;
    }
    ctx.addHeader("Set-Cookie", buf[0 .. n]);
}

/// Asks the browser to delete the cookie (`Max-Age=0` and a date in the past). `path`/`domain` must match the ones it was set with.
void deleteCookie(Context ctx, scope const(char)[] name, string path = "/", string domain = null)
{
    CookieOptions o;
    o.path = path;
    o.domain = domain;
    o.maxAge = Optional!long(0);
    o.expires = Optional!long(0);
    ctx.setCookie(name, "", o);
}

/// A cookie name is a token (RFC 6265 §4.1.1).
bool validCookieName(scope const(char)[] s) pure nothrow @nogc
{
    if (s.length == 0)
        return false;
    foreach (char c; s)
        if (!isTchar(c))
            return false;
    return true;
}

/// cookie-octet (RFC 6265 §4.1.1): printable ASCII except space, `"`, `,`, `;` and `\`.
bool validCookieValue(scope const(char)[] s) pure nothrow @nogc
{
    foreach (char c; s)
        if (c <= ' ' || c >= 0x7f || c == '"' || c == ',' || c == ';' || c == '\\')
            return false;
    return true;
}

private bool validAttribute(scope const(char)[] s) pure nothrow @nogc
{
    foreach (char c; s)
        if (c < ' ' || c == 0x7f || c == ';')
            return false;
    return true;
}

unittest
{
    assert(validCookieName("session") && validCookieName("a-b_c") && !validCookieName("") && !validCookieName("a b")
        && !validCookieName("a=b") && !validCookieName("a;b"));
    assert(validCookieValue("abc123") && validCookieValue("") && validCookieValue("a%20b") && !validCookieValue("a b")
        && !validCookieValue("a;b") && !validCookieValue("a,b") && !validCookieValue("a\"b") && !validCookieValue("a\\b")
        && !validCookieValue("a\r\nb"));
}
