/// Types the user writes in handler signatures.
module vela.web.params;

@safe:

import vela.http.types : HeaderField;

/// JSON body decoded into `T`. Access the fields directly: `body.name`.
struct JsonBody(T)
{
    T value;
    alias value this;
}

/// Value of a header. It is a zero-copy slice of the network buffer:
/// valid only during the request. To keep it, use `.idup`.
struct Header(string name)
{
    enum string headerName = name;
    const(char)[] value;
    alias value this;
}

/// Value left by a middleware in `ctx.locals`. If no middleware set it,
/// the request fails with 500 (a configuration error, not the client's).
struct Local(T)
{
    T value;
    alias value this;
}

/// Optional parameter: `Optional!int page`, `Optional!(Header!"X-Trace")`.
struct Optional(T)
{
    private T _value;
    private bool _has;

    this(T v)
    {
        _value = v;
        _has = true;
    }

    bool has() const => _has;

    ref inout(T) get() inout return
    {
        assert(_has, "empty Optional: check .has before .get");
        return _value;
    }

    inout(T) getOr(inout(T) fallback) inout => _has ? _value : fallback;
}

/// Return with a status other than 200: `return withStatus(201, user);`
struct WithStatus(T)
{
    int status;
    T value;
}

WithStatus!T withStatus(T)(int status, T value) => WithStatus!T(status, value);

/// Hand-built response (redirect, custom content-type, extra headers).
struct Response
{
    int status = 200;
    const(char)[] contentType = "text/plain; charset=utf-8";
    const(char)[] body;
    HeaderField[] headers;

    static Response text(const(char)[] s, int status = 200) => Response(status, "text/plain; charset=utf-8", s);
    static Response html(const(char)[] s, int status = 200) => Response(status, "text/html; charset=utf-8", s);

    static Response redirect(const(char)[] location, int status = 307)
    {
        return Response(status, null, null, [HeaderField("Location", location)]);
    }
}

/// Thrown by the handler to respond with an error: `throw new HttpError(404, "user not found");`
class HttpError : Exception
{
    int status;

    this(int status, string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
        this.status = status;
    }
}

// ---- recognition of the wrappers (shallow, no recursion)

enum isJsonBody(T) = is(T == JsonBody!U, U);
enum isHeader(T) = is(T == Header!n, string n);
enum isLocal(T) = is(T == Local!U, U);
enum isOptional(T) = is(T == Optional!U, U);
enum isWithStatus(T) = is(T == WithStatus!U, U);

enum isCharType(T) = is(immutable T == immutable char) || is(immutable T == immutable wchar)
    || is(immutable T == immutable dchar);

/// Scalars extractable from path, query or header.
enum isScalar(T) = is(T == bool) || is(T == enum)
    || (__traits(isIntegral, T) && !isCharType!T)
    || __traits(isFloating, T)
    || is(T == string) || is(T == const(char)[]);
