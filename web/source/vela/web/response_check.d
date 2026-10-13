/// The one place a response is checked before it goes on the wire: vela-owned headers are dropped, every name and value
/// is validated, `Date` is added. Used when a normal response is finished (`App.handle`) and when a streamed one is
/// committed (`vela.web.stream`), so both obey the same rules.
module vela.web.response_check;

@safe:

import vela.http.types;
import vela.http.date : httpDate;
import vela.web.context;

/// Headers vela writes itself: whatever the application sets for them is dropped (see `ResponseState`).
private immutable string[8] ownedHeaders = ["Content-Length", "Connection", "Keep-Alive", "Transfer-Encoding",
    "Upgrade", "Proxy-Connection", "TE", "Trailer"];

/// Drops the headers vela owns and adds `Date`; then validates the status line pieces. A header the application built
/// wrongly (CR/LF from user input in a redirect target, say) must never reach the wire, and must not be silently
/// "fixed": returns false after logging which header was wrong (its name, never its value, so the log cannot be forged
/// either). The caller turns that into a 500.
bool checkResponse(Context ctx)
{
    foreach (n; ownedHeaders)
        ctx.response.removeHeader(n);
    ctx.response.ensureHeader("Date", httpDate());
    const(char)[] badName;       // the header whose value is invalid
    string problem;              // set instead for the other kinds of violation
    if (ctx.response.headerOverflow)
        problem = "more than 32 response headers";
    else if (!isValidHeaderValue(ctx.response.contentType))
        badName = "Content-Type";
    else
        foreach (ref h; ctx.response.headers)
            if (!isValidHeaderName(h.name))
            {
                problem = "a header name that is not a token";
                break;
            }
            else if (!isValidHeaderValue(h.value))
            {
                badName = h.name;
                break;
            }
    if (badName.length == 0 && problem.length == 0)
        return true;
    logBadResponse(ctx, badName, problem);
    return false;
}

private void logBadResponse(Context ctx, scope const(char)[] badName, string problem) nothrow @trusted
{
    import core.stdc.stdio : fprintf, stderr;

    // @trusted: fprintf with explicit lengths; only a header name or a fixed text is printed, never a value
    immutable m = methodName(ctx.request.method);
    if (problem.length)
        fprintf(stderr, "vela: response to %.*s %.*s has %.*s; answering 500\n",
            cast(int) m.length, m.ptr, cast(int) ctx.request.path.length, ctx.request.path.ptr,
            cast(int) problem.length, problem.ptr);
    else
        fprintf(stderr, "vela: response to %.*s %.*s has an invalid header '%.*s' (CR, LF, NUL or a control character); answering 500\n",
            cast(int) m.length, m.ptr, cast(int) ctx.request.path.length, ctx.request.path.ptr,
            cast(int) badName.length, badName.ptr);
}
