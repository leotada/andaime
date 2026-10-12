/// Middlewares prontos para o dia a dia: log de acesso, id de requisição e token Bearer.
module vela.web.middleware;

import core.stdc.stdio : fprintf, stderr;
import core.time : MonoTime;

import vela.http.types : methodName;
import vela.web.context;

/// Id da requisição (veja `requestId`). Leia em handlers com `Local!RequestId`.
struct RequestId
{
    const(char)[] value; /// válido durante a requisição
    alias value this;
}

/// Uma linha por requisição em stderr: `GET /users/7 200 1.3ms`.
/// Não aloca; escreva o seu se precisar de JSON/estruturado.
Middleware accessLog()
{
    return (Context ctx, Next next) {
        immutable t0 = MonoTime.currTime;
        scope (exit)
        {
            immutable us = (MonoTime.currTime - t0).total!"usecs";
            auto m = methodName(ctx.request.method);
            auto rid = ctx.locals.find!RequestId();
            fprintf(stderr, "%.*s %.*s %d %ld.%ldms%s%.*s\n", cast(int) m.length, m.ptr,
                cast(int) ctx.request.target.length, ctx.request.target.ptr, ctx.response.status,
                cast(long)(us / 1000), cast(long)((us % 1000) / 100),
                rid is null ? "".ptr : " rid=".ptr, rid is null ? 0 : cast(int) rid.value.length,
                rid is null ? "".ptr : rid.value.ptr);
        }
        next();
    };
}

/// Garante um id por requisição: reaproveita o `X-Request-Id` recebido (se for curto e
/// só tiver caracteres seguros) ou gera 16 hex. Devolve o id no header da resposta e
/// em `ctx.locals` (`Local!RequestId`).
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

private ulong rngState; // thread-local: um gerador por worker

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

/// O token de `Authorization: Bearer <token>`, ou null se ausente/malformado.
const(char)[] bearerToken(Context ctx) pure nothrow @nogc @safe
{
    auto h = ctx.request.header("Authorization");
    if (h.length > 7 && (h[0 .. 7] == "Bearer " || h[0 .. 7] == "bearer "))
        return h[7 .. $];
    return null;
}
