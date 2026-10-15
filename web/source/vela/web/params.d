/// Types the user writes in handler signatures.
module vela.web.params;

@safe:

import vela.http.types : HeaderField;
import vela.http.ip : IpAddress;
import vela.http.texttype : isTextType;

/// JSON body decoded into `T`. Access the fields directly: `body.name`.
struct JsonBody(T)
{
    T value;
    alias value this;
}

/// The client's address (`ctx.clientIp()`): the TCP peer, or the real client behind a trusted proxy. A parameter kind of its
/// own: `string who(ClientIp ip) => ip.toString;`. Not shown in the OpenAPI document.
struct ClientIp
{
    IpAddress value;
    alias value this;
}

/// Value of a header, copied into a `string` you may keep (one small allocation per header parameter). For a
/// zero-copy view use `ctx.request.header("Name")` instead, which is valid during the request only.
struct Header(string name)
{
    enum string headerName = name;
    string value;
    alias value this;
}

/// Value of a cookie, copied into a `string` you may keep: `string me(Cookie!"session" s)`. Required like a header;
/// `Optional!(Cookie!"theme")` makes it optional.
struct Cookie(string name)
{
    enum string cookieName = name;
    string value;
    alias value this;
}

/// Value left by a middleware in `ctx.locals`. If no middleware set it,
/// the request fails with 500 (a configuration error, not the client's).
struct Local(T)
{
    T value;
    alias value this;
}

/// Optional parameter: `Optional!int page`, `Optional!(Header!"X-Trace")`. Defined in `vela:http` so the database
/// driver shares it (a NULL column is an empty `Optional`).
public import vela.http.optional : Optional;

/// A JSON field that may be absent, `null`, or a value (PATCH bodies). See `vela.http.patchfield`.
public import vela.http.patchfield : PatchField, isPatchField;

/// Return with a status other than 200: `return withStatus(201, user);`
struct WithStatus(T)
{
    int status;
    T value;
}

WithStatus!T withStatus(T)(int status, T value) => WithStatus!T(status, value);

/// Success status of a handler: `@status(201) Item create(JsonBody!NewItem b)`. Applies to a normal return (a handler that
/// returns `WithStatus` or `Response` decides for itself) and replaces the 204 of a `void` handler. OpenAPI documents it.
struct status { int code; }

/// Documents an error response of a handler (repeatable): `@responds(404, "User not found")`. Purely descriptive: the
/// handler still produces it by throwing `HttpError`.
struct responds { int code; string description; }

/// The `@status` code of handler `fn`, or 0 when it has none.
template successStatus(alias fn)
{
    enum successStatus = () {
        int r = 0;
        static foreach (a; __traits(getAttributes, fn))
            static if (is(typeof(a) == status))
                r = a.code;
        return r;
    }();
}

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
enum isCookie(T) = is(T == Cookie!n, string n);
enum isLocal(T) = is(T == Local!U, U);
enum isClientIp(T) = is(T == ClientIp);

/// A query list: an array of scalars that is not itself a text type (`int[] ids`, `string[] tags`, `Order[] sort`).
enum isScalarList(T) = is(T == U[], U) && !isScalar!T && isScalar!U;
enum isOptional(T) = is(T == Optional!U, U);
enum isWithStatus(T) = is(T == WithStatus!U, U);

enum isCharType(T) = is(immutable T == immutable char) || is(immutable T == immutable wchar)
    || is(immutable T == immutable dchar);

/// Scalars extractable from path, query or header: numbers, bool, enums, text, and your own text types
/// (`static bool fromString(text, out T)` plus `toString(sink)`; see `vela.http.texttype`).
enum isScalar(T) = is(T == bool) || is(T == enum)
    || (__traits(isIntegral, T) && !isCharType!T)
    || __traits(isFloating, T)
    || is(T == string) || is(T == const(char)[]) || isTextType!T;
