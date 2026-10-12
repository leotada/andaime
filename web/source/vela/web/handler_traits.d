/// Introspecção de handlers em tempo de compilação.
///
/// Para cada rota registrada, `dispatch` gera (via `static foreach` raso,
/// sem recursão de templates) o código que extrai cada argumento do
/// request e chama o handler. `handlerError` valida a assinatura e devolve
/// UMA linha explicando o que corrigir, ou "" se está tudo certo.
///
/// Regras de binding, pela ordem:
///   1. nome do parâmetro aparece como {nome} na rota  -> path (escalar)
///   2. Context                                        -> o próprio contexto
///      Local!T                                        -> valor de ctx.locals (definido por middleware)
///   3. JsonBody!T                                     -> corpo JSON decodificado
///   4. Header!"Nome"                                  -> header obrigatório
///   5. Optional!X (X = escalar, Header, JsonBody)     -> opcional
///   6. escalar fora da rota                           -> query (default => opcional)
module vela.web.handler_traits;

import vela.http.types;
import vela.web.context;
import vela.web.params;
import vela.web.dto : FieldErrors, ctNum;
import vela.web.convert;
import vela.web.json;

// =====================================================================
// Padrão da rota (CTFE)
// =====================================================================

struct RouteInfo
{
    string[] params;  /// nomes dos {params}, em ordem
    bool[] catchAll;  /// true para {*resto}
    string error;     /// erro de sintaxe, se houver
}

RouteInfo parseRoute(string path) pure @safe
{
    RouteInfo info;
    if (path.length == 0 || path[0] != '/')
    {
        info.error = "a rota \"" ~ path ~ "\" deve começar com '/'";
        return info;
    }
    size_t i = 0;
    while (i < path.length)
    {
        if (path[i] == '{')
        {
            size_t j = i + 1;
            while (j < path.length && path[j] != '}' && path[j] != '/')
                j++;
            if (j == path.length || path[j] != '}')
            {
                info.error = "chave '{' sem '}' na rota \"" ~ path ~ "\"";
                return info;
            }
            string name = path[i + 1 .. j];
            bool rest = name.length && name[0] == '*';
            if (rest)
                name = name[1 .. $];
            if (name.length == 0)
            {
                info.error = "parâmetro sem nome na rota \"" ~ path ~ "\"";
                return info;
            }
            foreach (p; info.params)
                if (p == name)
                {
                    info.error = "parâmetro {" ~ name ~ "} repetido na rota \"" ~ path ~ "\"";
                    return info;
                }
            info.params ~= name;
            info.catchAll ~= rest;
            i = j + 1;
        }
        else
            i++;
    }
    if (info.params.length > PathParams.max)
        info.error = "a rota \"" ~ path ~ "\" tem mais de " ~ ctNum(PathParams.max) ~ " parâmetros";
    return info;
}

ptrdiff_t indexOfName(const string[] names, string name) pure nothrow @nogc @safe
{
    foreach (i, n; names)
        if (n == name)
            return i;
    return -1;
}

// =====================================================================
// Validação da assinatura: uma linha de erro, ou ""
// =====================================================================

/// Tipos de retorno aceitos.
enum isSupportedReturn(R) = is(R == void) || is(R : const(char)[]) || is(R == Response)
    || isWithStatus!R || is(R == struct) || is(R == U[], U) || isScalar!R;

template handlerError(Method method, string path, alias fn, string file, size_t line)
{
    enum string head = file ~ "(" ~ ctNum(line) ~ "): vela: handler '"
        ~ __traits(identifier, fn) ~ "' em " ~ methodName(method) ~ " " ~ path ~ ": ";

    static if (__traits(isTemplate, fn) || !is(typeof(fn)))
        enum handlerError = head ~ "o handler não tem tipo concreto. Se for um lambda, "
            ~ "declare os tipos dos parâmetros: (int id) => ...";
    else static if (is(typeof(fn) P == __parameters))
    {
        enum handlerError = () {
            auto info = parseRoute(path);
            if (info.error.length)
                return head ~ info.error;
            auto used = new bool[info.params.length];
            size_t bodies = 0;

            static foreach (i; 0 .. P.length)
            {{
                alias T = P[i];
                enum pname = __traits(identifier, P[i .. i + 1]);
                enum stc = __traits(getParameterStorageClasses, fn, i);
                enum bad = "o parâmetro '" ~ pname ~ "' ";
                foreach (s; stc)
                    if (s == "ref" || s == "out" || s == "lazy")
                        return head ~ bad ~ "não pode ser '" ~ s ~ "'; receba por valor";

                immutable ri = indexOfName(info.params, pname);
                if (ri >= 0)
                {
                    used[ri] = true;
                    if (!isScalar!T)
                        return head ~ bad ~ "vem da rota ({" ~ pname ~ "}) e precisa ser escalar "
                            ~ "(int, long, string, bool, enum...), mas é '" ~ T.stringof ~ "'";
                    if (info.catchAll[ri] && !is(T == string) && !is(T == const(char)[]))
                        return head ~ bad ~ "captura {*" ~ pname ~ "} e precisa ser string ou const(char)[]";
                }
                else
                {
                    static if (isJsonBody!T || is(T == Optional!(JsonBody!U), U))
                    {
                        bodies++;
                        if (method == Method.GET || method == Method.HEAD)
                            return head ~ bad ~ "é JsonBody, mas " ~ methodName(method)
                                ~ " não tem corpo; use POST, PUT ou PATCH";
                    }
                    else static if (is(T == Optional!U, U))
                    {
                        static if (!(isScalar!U || isHeader!U))
                            return head ~ bad ~ "é Optional!(" ~ U.stringof ~ "); Optional aceita "
                                ~ "escalar, Header!\"Nome\" ou JsonBody!T";
                    }
                    else static if (!(is(T == Context) || isLocal!T || isHeader!T || isScalar!T))
                        return head ~ bad ~ "tem tipo '" ~ T.stringof ~ "', que o vela não sabe extrair. "
                            ~ "Use escalar (int, string, enum...), JsonBody!T, Header!\"Nome\", Local!T, Optional!T ou Context";
                }
            }}

            foreach (k, u; used)
                if (!u)
                    return head ~ "a rota declara {" ~ info.params[k] ~ "}, mas a função não tem "
                        ~ "parâmetro chamado '" ~ info.params[k] ~ "'";
            if (bodies > 1)
                return head ~ "há mais de um JsonBody; junte os campos num único DTO";

            static if (is(typeof(fn) R == return))
                static if (!isSupportedReturn!R)
                    return head ~ "o retorno '" ~ R.stringof ~ "' não é suportado. Retorne void, "
                        ~ "string, um struct/array (JSON), WithStatus!T ou Response";
            return "";
        }();
    }
    else
        enum handlerError = head ~ "não é uma função";
}

// =====================================================================
// Dispatch gerado
// =====================================================================

/// Extrai os argumentos de `ctx`, chama o handler e escreve a resposta.
/// `self` (opcional) é a instância do controller para métodos.
void dispatch(Method method, string path, alias fn, Self...)(Context ctx, Self self)
    if (Self.length <= 1)
{
    static if (is(typeof(fn) P == __parameters))
    {
        enum info = parseRoute(path);
        P args;

        static foreach (i; 0 .. P.length)
        {{
            alias T = P[i];
            enum pname = __traits(identifier, P[i .. i + 1]);
            enum ri = indexOfName(info.params, pname);

            static if (ri >= 0)
                bindText(ctx, ctx.params[ri], false, "path", pname, args[i]);
            else static if (is(T == Context))
                args[i] = ctx;
            else static if (is(T == Local!U, U))
            {
                auto lp = ctx.locals.find!U();
                if (lp is null)
                    throw new Exception("Local!" ~ U.stringof ~ " ausente: nenhum middleware chamou ctx.locals.set(" ~ U.stringof ~ ")");
                args[i].value = *lp;
            }
            else static if (is(T == JsonBody!U, U))
                bindBody(ctx, args[i].value);
            else static if (is(T == Header!n, string n))
            {
                auto hv = ctx.request.header(n);
                if (hv is null)
                    ctx.errors.add("header", n, "header obrigatório ausente");
                else
                    args[i].value = hv;
            }
            else static if (is(T == Optional!U, U))
            {
                static if (is(U == Header!n, string n))
                {
                    auto hv = ctx.request.header(n);
                    if (hv !is null)
                        args[i] = T(U(hv));
                }
                else static if (is(U == JsonBody!V, V))
                {
                    if (ctx.request.body.length)
                    {
                        U tmp;
                        if (bindBody(ctx, tmp.value))
                            args[i] = T(tmp);
                    }
                }
                else
                {
                    const(char)[] raw;
                    if (ctx.request.rawQueryParam(pname, raw))
                    {
                        U tmp;
                        if (bindText(ctx, raw, true, "query", pname, tmp))
                            args[i] = T(tmp);
                    }
                }
            }
            else // escalar fora da rota => query
            {
                const(char)[] raw;
                if (ctx.request.rawQueryParam(pname, raw))
                    bindText(ctx, raw, true, "query", pname, args[i]);
                else
                {
                    // valor default declarado na assinatura (`int limit = 20`)
                    static if (is(typeof(((P[i .. i + 1] __a) => __a[0])())))
                        args[i] = ((P[i .. i + 1] __a) => __a[0])();
                    else
                        ctx.errors.add("query", pname, "parâmetro obrigatório ausente");
                }
            }
        }}

        if (ctx.errors.any)
            return writeValidationErrors(ctx);

        static if (Self.length)
            enum call = "__traits(child, self[0], fn)(args)";
        else
            enum call = "fn(args)";

        static if (is(typeof(mixin(call)) == void))
        {
            mixin(call ~ ";");
            ctx.response.status = 204;
        }
        else
        {
            auto result = mixin(call);
            writeResult(ctx, result);
        }
    }
    else
        static assert(0, "vela: dispatch sem handlerError antes (bug interno)");
}

private bool bindText(T)(Context ctx, const(char)[] raw, bool plusIsSpace, string loc,
    string name, ref T dest)
{
    const(char)[] text;
    if (!percentDecode(raw, plusIsSpace, text))
    {
        ctx.errors.add(loc, name, "codificação % inválida");
        return false;
    }
    if (!parseScalarText(text, dest))
    {
        ctx.errors.add(loc, name, typeHint!T);
        return false;
    }
    return true;
}

private bool bindBody(T)(Context ctx, ref T dest)
{
    if (ctx.request.body.length == 0)
    {
        ctx.errors.add("body", "", "corpo JSON obrigatório");
        return false;
    }
    return decodeJson(cast(const(char)[]) ctx.request.body, dest, ctx.errors);
}

/// 422 no formato do FastAPI: {"detail":[{"loc":["query","limit"],"msg":"..."}]}
void writeValidationErrors(Context ctx)
{
    auto o = &ctx.response.body;
    ctx.response.status = 422;
    ctx.response.contentType = "application/json";
    o.clear();
    o.put(`{"detail":[`);
    foreach (k, ref e; ctx.errors.list)
    {
        if (k)
            o.put(',');
        o.put(`{"loc":[`);
        writeJsonString(*o, e.location);
        if (e.field.length)
        {
            o.put(',');
            writeJsonString(*o, e.field);
        }
        o.put(`],"msg":`);
        writeJsonString(*o, e.message);
        o.put('}');
    }
    o.put("]}");
}

/// Escreve o valor retornado pelo handler.
void writeResult(R)(Context ctx, ref R r)
{
    static if (is(R == Response))
    {
        ctx.response.status = r.status;
        ctx.response.contentType = r.contentType;
        ctx.response.body.put(r.body);
        foreach (ref h; r.headers)
            ctx.response.setHeader(h.name, h.value);
    }
    else static if (is(R == WithStatus!U, U))
    {
        writeResult(ctx, r.value);
        ctx.response.status = r.status;
    }
    else static if (is(R : const(char)[]))
    {
        ctx.response.contentType = "text/plain; charset=utf-8";
        ctx.response.body.put(r);
    }
    else
    {
        ctx.response.contentType = "application/json";
        writeJson(ctx.response.body, r);
    }
}
