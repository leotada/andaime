/// The one place a response is checked before it goes on the wire: andaime-owned headers are dropped, every name and value
/// is validated, `Date` is added. Used when a normal response is finished (`App.handle`) and when a streamed one is
/// committed (`andaime.web.stream`), so both obey the same rules.
module andaime.web.response_check 2025;

@safe:

import andaime.http.types;
import andaime.http.date : httpDate;
import andaime.log : LogLevel, logAndaime;
import andaime.web.context;

/// Headers andaime writes itself: whatever the application sets for them is dropped (see `ResponseState`).
private immutable string[8] ownedHeaders = ["Content-Length", "Connection", "Keep-Alive", "Transfer-Encoding",
    "Upgrade", "Proxy-Connection", "TE", "Trailer"];

/// Drops the headers andaime owns and adds `Date`; then validates the status line pieces. A header the application built
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

/// Only a header name or a fixed text is logged, never a value.
private void logBadResponse(Context ctx, scope const(char)[] badName, string problem) nothrow
{
    immutable m = methodName(ctx.request.method);
    try
    {
        // the text format keeps the line as it always was; kv and json get the same facts as fields
        const(char)[] what = problem.length ? problem : "an invalid header '" ~ badName
            ~ "' (CR, LF, NUL or a control character)";
        logAndaime(LogLevel.warn, "andaime: response to " ~ m ~ " " ~ ctx.request.path ~ " has " ~ what ~ "; answering 500",
            "response has a bad header", "method", m, "path", ctx.request.path, "problem", what);
    }
    catch (Exception)
    {
        // the line is lost, never the request
    }
}
