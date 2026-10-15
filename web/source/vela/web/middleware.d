/// Ready-made everyday middlewares: access log, request id and Bearer token.
module vela.web.middleware;

@safe:

import core.stdc.stdio : fprintf, stderr;
import core.time : MonoTime;

import vela.http.types : methodName;
import vela.web.context;
import vela.log : LogLevel, LogFormat, logEnabled, logFormat, logVela;

/// Request id (see `requestId`). Read it in handlers with `Local!RequestId`.
struct RequestId
{
    const(char)[] value; /// valid during the request
    alias value this;
}

/// One line per request on stderr, through `vela.log` at the `info` level. In the `text` format (the default):
/// `GET /users/7 200 1.3ms ip=203.0.113.7`; in `kv`/`json`: `msg=request method=GET target=/users/7 status=200
/// duration_us=1300 ip=203.0.113.7` plus time, level and the request id. Does not allocate.
Middleware accessLog()
{
    return (Context ctx, Next next) {
        immutable t0 = MonoTime.currTime;
        scope (exit)
            writeAccessLine(ctx, t0);
        next();
    };
}

private void writeAccessLine(Context ctx, MonoTime t0)
{
    if (!logEnabled(LogLevel.info))
        return;
    immutable us = (MonoTime.currTime - t0).total!"usecs";
    auto m = methodName(ctx.request.method);
    char[39] ipBuf = void;
    immutable ipLen = ctx.clientIp().format(ipBuf[]);
    if (logFormat != LogFormat.text)
    {
        logVela(LogLevel.info, null, "request", "method", m, "target", ctx.request.target,
            "status", ctx.response.status, "duration_us", us, "ip", ipBuf[0 .. ipLen]);
        return;
    }
    auto rid = ctx.locals.find!RequestId();
    // sound: every pointer/length pair below comes from a live slice
    () @trusted {
        fprintf(stderr, "%.*s %.*s %d %ld.%ldms ip=%.*s%s%.*s\n", cast(int) m.length, m.ptr,
            cast(int) ctx.request.target.length, ctx.request.target.ptr, ctx.response.status,
            cast(long)(us / 1000), cast(long)((us % 1000) / 100), cast(int) ipLen, ipBuf.ptr,
            rid is null ? "".ptr : " rid=".ptr, rid is null ? 0 : cast(int) rid.value.length,
            rid is null ? "".ptr : rid.value.ptr);
    }();
}

/// Ensures one id per request: reuses the received `X-Request-Id` (if short and
/// made only of safe characters) or generates 16 hex digits. Returns the id in the response header and
/// in `ctx.locals` (`Local!RequestId`).
Middleware requestId(string header = "X-Request-Id")
{
    return (Context ctx, Next next) {
        auto incoming = ctx.request.header(header);
        const(char)[] id;
        if (incoming.length > 0 && incoming.length <= 64 && allSafe(incoming))
            id = incoming;
        else
        {
            auto buf = ctx.scratch(16);
            fillRandomHex(buf);
            id = buf;
        }
        ctx.locals.set(RequestId(id));
        ctx.requestIdForLog = id; // vela.log adds it to the lines written during this request
        ctx.setHeader(header, id);
        next();
    };
}

private bool allSafe(const(char)[] s) pure nothrow @nogc @safe
{
    foreach (char c; s)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.'))
            return false;
    return true;
}

private ulong rngState; // thread-local: one generator per worker

private void fillRandomHex(char[] out_) nothrow @trusted
{
    if (rngState == 0)
    {
        import core.sys.posix.pthread : pthread_self;

        rngState = cast(ulong) MonoTime.currTime.ticks ^ (cast(ulong) pthread_self() * 0x9E3779B97F4A7C15UL) | 1;
    }
    foreach (i; 0 .. out_.length)
    {
        rngState ^= rngState << 13;
        rngState ^= rngState >> 7;
        rngState ^= rngState << 17;
        out_[i] = "0123456789abcdef"[(rngState >> 32) & 15];
    }
}

/// The token from `Authorization: Bearer <token>`, or null if absent/malformed.
const(char)[] bearerToken(Context ctx) pure nothrow @nogc @safe
{
    auto h = ctx.request.header("Authorization");
    if (h.length > 7 && (h[0 .. 7] == "Bearer " || h[0 .. 7] == "bearer "))
        return h[7 .. $];
    return null;
}
