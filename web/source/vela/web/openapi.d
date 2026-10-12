/// `openapi.json` gerado a partir das assinaturas dos handlers.
///
/// A mesma introspecção que gera o dispatch (nomes e tipos dos parâmetros,
/// DTOs, tipo de retorno) descreve a API: o contrato HTTP não é escrito duas vezes.
///
///     app.serveOpenApi(OpenApiInfo("Minha API", "1.0.0"));   // GET /openapi.json e /docs
///
/// Detalhes:
///  - `{param}` na rota -> parâmetro de path; escalar fora da rota -> query
///    (obrigatório, a menos que tenha valor default ou seja Optional);
///  - `Header!"X"` -> header; `JsonBody!T` -> requestBody com o schema de T;
///  - `Context` e `Local!T` não aparecem (não vêm do cliente);
///  - structs viram `components/schemas`; `@minLength`, `@maxLength`, `@inRange`,
///    `@jsonKey`, `@optional` e `@jsonIgnore` são respeitados;
///  - `@summary("texto")` no handler preenche o resumo da operação.
module vela.web.openapi;

import vela.http.types : Method, methodName;
import vela.web.params;
import vela.web.context : Context;
import vela.web.dto : jsonKey, optional, jsonIgnore, minLength, maxLength, inRange, hasUda;
import vela.web.handler_traits : parseRoute, indexOfName;

/// Texto de uma linha da operação: `@summary("Busca um usuário") UserResponse getUser(long id)`.
struct summary { string text; }

struct OpenApiInfo
{
    string title = "API";
    string version_ = "0.1.0";
    string description;
    /// Caminho do JSON; "" = não serve.
    string jsonPath = "/openapi.json";
    /// Caminho da página interativa (Swagger UI via CDN); "" = não serve.
    string docsPath = "/docs";
}

/// Schemas nomeados (`components/schemas`) acumulados durante a geração.
struct Components
{
    string[string] schemas;      // nome -> JSON
    bool[string] building;       // evita recursão infinita em tipos que se referenciam
}

alias OpDescribe = string delegate(ref Components comps, string pattern) @safe;

// ------------------------------------------------------------ JSON mínimo

string q(scope const(char)[] s) pure @safe
{
    string o = "\"";
    foreach (char c; s)
    {
        switch (c)
        {
            case '"': o ~= `\"`; break;
            case '\\': o ~= `\\`; break;
            case '\n': o ~= `\n`; break;
            case '\r': o ~= `\r`; break;
            case '\t': o ~= `\t`; break;
            default:
                if (c < ' ')
                {
                    o ~= `\u00`;
                    o ~= "0123456789abcdef"[c >> 4];
                    o ~= "0123456789abcdef"[c & 15];
                }
                else
                    o ~= c;
        }
    }
    return o ~ "\"";
}

private string num(double v) @safe
{
    // inteiros exatos sem notação científica (@inRange costuma ter limites inteiros)
    if (v == cast(long) v && v > -1e15 && v < 1e15)
        return itoa(cast(long) v);
    import core.stdc.stdio : snprintf;

    char[40] t;
    auto n = (() @trusted => snprintf(t.ptr, t.length, "%.17g", v))();
    return t[0 .. n].idup;
}

private string itoa(long v) pure @safe
{
    if (v == 0)
        return "0";
    bool neg = v < 0;
    ulong u = neg ? cast(ulong)(-(v + 1)) + 1 : cast(ulong) v;
    string r;
    while (u)
    {
        r = cast(char)('0' + u % 10) ~ r;
        u /= 10;
    }
    return neg ? "-" ~ r : r;
}

// ------------------------------------------------------------ schemas de tipos

/// Schema JSON (inline ou `$ref`) do tipo T.
string schemaOf(T)(ref Components comps) @safe
{
    static if (is(T == bool))
        return `{"type":"boolean"}`;
    else static if (is(T == enum))
    {
        string vals;
        static foreach (m; __traits(allMembers, T))
            vals ~= (vals.length ? "," : "") ~ q(m);
        return `{"type":"string","enum":[` ~ vals ~ `]}`;
    }
    else static if (__traits(isIntegral, T) && !isCharType!T)
    {
        static if (T.sizeof == 8)
            enum fmt = `"int64"`;
        else
            enum fmt = `"int32"`;
        static if (__traits(isUnsigned, T))
            return `{"type":"integer","format":` ~ fmt ~ `,"minimum":0}`;
        else
            return `{"type":"integer","format":` ~ fmt ~ `}`;
    }
    else static if (__traits(isFloating, T))
        return `{"type":"number"}`;
    else static if (is(T : const(char)[]))
        return `{"type":"string"}`;
    else static if (is(T == Optional!U, U))
        return schemaOf!U(comps);
    else static if (is(T == JsonBody!U, U))
        return schemaOf!U(comps);
    else static if (is(T == WithStatus!U, U))
        return schemaOf!U(comps);
    else static if (is(T == U[], U) || is(T == U[n], U, size_t n))
        return `{"type":"array","items":` ~ schemaOf!U(comps) ~ `}`;
    else static if (is(T == struct))
    {
        enum name = schemaName!T;
        if (name !in comps.schemas && name !in comps.building)
        {
            comps.building[name] = true;
            comps.schemas[name] = structSchema!T(comps);
            comps.building.remove(name);
        }
        return `{"$ref":"#/components/schemas/` ~ name ~ `"}`;
    }
    else
        return `{}`;
}

private enum schemaName(T) = T.stringof;

private string structSchema(T)(ref Components comps) @safe
{
    string props, req;
    static foreach (i; 0 .. T.tupleof.length)
    {
        static if (!hasUda!(T, i, jsonIgnore))
        {{
            alias F = typeof(T.tupleof[i]);
            enum key = jsonKeyOfField!(T, i);
            string sch = schemaOf!F(comps);
            string extra;
            static foreach (attr; __traits(getAttributes, T.tupleof[i]))
            {
                static if (is(typeof(attr) == minLength))
                    extra ~= `,"` ~ (is(F : const(char)[]) ? "minLength" : "minItems") ~ `":` ~ itoa(attr.value);
                else static if (is(typeof(attr) == maxLength))
                    extra ~= `,"` ~ (is(F : const(char)[]) ? "maxLength" : "maxItems") ~ `":` ~ itoa(attr.value);
                else static if (is(typeof(attr) == inRange))
                    extra ~= `,"minimum":` ~ num(attr.min) ~ `,"maximum":` ~ num(attr.max);
            }
            static if (is(F == Optional!U, U))
                extra ~= `,"nullable":true`;
            if (extra.length)
            {
                // injeta as restrições no objeto do schema (se for $ref, embrulha em allOf)
                if (sch.length > 8 && sch[0 .. 7] == `{"$ref"`)
                    sch = `{"allOf":[` ~ sch ~ `]` ~ extra ~ `}`;
                else
                    sch = sch[0 .. $ - 1] ~ extra ~ `}`;
            }
            props ~= (props.length ? "," : "") ~ q(key) ~ ":" ~ sch;
            static if (!hasUda!(T, i, optional) && !isOptional!F)
                req ~= (req.length ? "," : "") ~ q(key);
        }}
    }
    return `{"type":"object","properties":{` ~ props ~ `}` ~ (req.length ? `,"required":[` ~ req ~ `]` : "") ~ `}`;
}

private template jsonKeyOfField(T, size_t i)
{
    enum jsonKeyOfField = () {
        string r = __traits(identifier, T.tupleof[i]);
        static foreach (attr; __traits(getAttributes, T.tupleof[i]))
            static if (is(typeof(attr) == jsonKey))
                r = attr.name;
        return r;
    }();
}

// ------------------------------------------------------------ descrição de uma operação

/// Gera o objeto de operação OpenAPI para o handler `fn` registrado em `method path`.
string describeOperation(Method method, string path, alias fn)(ref Components comps, string pattern) @safe
{
    static if (is(typeof(fn) P == __parameters))
    {
        enum info = parseRoute(path);
        string params, bodySchema;
        bool bodyRequired;
        bool canFail;

        static foreach (i; 0 .. P.length)
        {{
            alias T = P[i];
            enum pname = __traits(identifier, P[i .. i + 1]);
            enum ri = indexOfName(info.params, pname);

            static if (ri >= 0)
            {
                params ~= (params.length ? "," : "") ~ `{"name":` ~ q(pname) ~ `,"in":"path","required":true,"schema":`
                    ~ schemaOf!T(comps) ~ `}`;
                canFail = true;
            }
            else static if (is(T == Context) || isLocal!T)
            {
            }
            else static if (is(T == JsonBody!U, U))
            {
                bodySchema = schemaOf!U(comps);
                bodyRequired = true;
                canFail = true;
            }
            else static if (is(T == Header!n, string n))
            {
                params ~= (params.length ? "," : "") ~ `{"name":` ~ q(n) ~ `,"in":"header","required":true,"schema":{"type":"string"}}`;
                canFail = true;
            }
            else static if (is(T == Optional!U, U))
            {
                static if (is(U == Header!n, string n))
                    params ~= (params.length ? "," : "") ~ `{"name":` ~ q(n) ~ `,"in":"header","required":false,"schema":{"type":"string"}}`;
                else static if (is(U == JsonBody!V, V))
                {
                    bodySchema = schemaOf!V(comps);
                    bodyRequired = false;
                    canFail = true;
                }
                else
                {
                    params ~= (params.length ? "," : "") ~ `{"name":` ~ q(pname) ~ `,"in":"query","required":false,"schema":`
                        ~ schemaOf!U(comps) ~ `}`;
                    canFail = true;
                }
            }
            else // escalar fora da rota => query
            {
                enum hasDefault = is(typeof(((P[i .. i + 1] __a) => __a[0])()));
                params ~= (params.length ? "," : "") ~ `{"name":` ~ q(pname) ~ `,"in":"query","required":`
                    ~ (hasDefault ? "false" : "true") ~ `,"schema":` ~ schemaOf!T(comps) ~ `}`;
                canFail = true;
            }
        }}

        string o = `{"operationId":` ~ q(opId!fn);
        static foreach (attr; __traits(getAttributes, fn))
            static if (is(typeof(attr) == summary))
                o ~= `,"summary":` ~ q(attr.text);
        if (params.length)
            o ~= `,"parameters":[` ~ params ~ `]`;
        if (bodySchema.length)
            o ~= `,"requestBody":{"required":` ~ (bodyRequired ? "true" : "false")
                ~ `,"content":{"application/json":{"schema":` ~ bodySchema ~ `}}}`;

        // respostas
        string resp;
        static if (is(typeof(fn) R == return))
        {
            static if (is(R == void))
                resp = `"204":{"description":"Sem conteúdo"}`;
            else static if (is(R : const(char)[]))
                resp = `"200":{"description":"OK","content":{"text/plain":{"schema":{"type":"string"}}}}`;
            else static if (is(R == Response))
                resp = `"200":{"description":"OK"}`;
            else
                resp = `"200":{"description":"OK","content":{"application/json":{"schema":` ~ schemaOf!R(comps) ~ `}}}`;
        }
        if (canFail)
        {
            ensureValidationError(comps);
            resp ~= (resp.length ? "," : "") ~ `"422":{"description":"Erro de validação","content":{"application/json":`
                ~ `{"schema":{"$ref":"#/components/schemas/HTTPValidationError"}}}}`;
        }
        o ~= `,"responses":{` ~ resp ~ `}}`;
        return o;
    }
    else
        return `{}`;
}

private template opId(alias fn)
{
    static if (__traits(compiles, __traits(identifier, fn)))
        enum opId = __traits(identifier, fn);
    else
        enum opId = "handler";
}

private void ensureValidationError(ref Components comps) @safe
{
    if ("HTTPValidationError" !in comps.schemas)
        comps.schemas["HTTPValidationError"] = `{"type":"object","properties":{"detail":{"type":"array","items":`
            ~ `{"type":"object","properties":{"loc":{"type":"array","items":{"type":"string"}},"msg":{"type":"string"}},`
            ~ `"required":["loc","msg"]}}}}`;
}

// ------------------------------------------------------------ documento

struct OpRecord
{
    Method method;
    string pattern;     // como foi registrado (inclui o prefixo do grupo)
    OpDescribe describe; // null para rotas sem introspecção (estáticos...)
}

/// `{*resto}` -> `{resto}` (OpenAPI não conhece o asterisco).
private string openApiPath(string pattern) pure @safe
{
    string o;
    foreach (i, c; pattern)
        if (!(c == '*' && i > 0 && pattern[i - 1] == '{'))
            o ~= c;
    return o;
}

string buildOpenApi(const(OpRecord)[] ops, OpenApiInfo info) @safe
{
    Components comps;
    // agrupa por path preservando a ordem de registro
    string[] order;
    string[string] byPath;
    foreach (ref op; ops)
    {
        if (op.describe is null)
            continue;
        auto p = openApiPath(op.pattern);
        string verb;
        final switch (op.method)
        {
            case Method.GET: verb = "get"; break;
            case Method.HEAD: verb = "head"; break;
            case Method.POST: verb = "post"; break;
            case Method.PUT: verb = "put"; break;
            case Method.PATCH: verb = "patch"; break;
            case Method.DELETE: verb = "delete"; break;
            case Method.OPTIONS: verb = "options"; break;
            case Method.unknown: continue;
        }
        auto body_ = q(verb) ~ ":" ~ op.describe(comps, op.pattern);
        if (auto cur = p in byPath)
            *cur ~= "," ~ body_;
        else
        {
            order ~= p;
            byPath[p] = body_;
        }
    }

    string paths;
    foreach (p; order)
        paths ~= (paths.length ? "," : "") ~ q(p) ~ ":{" ~ byPath[p] ~ "}";
    string schemas;
    foreach (name; sortedKeys(comps.schemas))
        schemas ~= (schemas.length ? "," : "") ~ q(name) ~ ":" ~ comps.schemas[name];

    string o = `{"openapi":"3.0.3","info":{"title":` ~ q(info.title) ~ `,"version":` ~ q(info.version_);
    if (info.description.length)
        o ~= `,"description":` ~ q(info.description);
    o ~= `},"paths":{` ~ paths ~ `},"components":{"schemas":{` ~ schemas ~ `}}}`;
    return o;
}

private string[] sortedKeys(string[string] aa) @safe
{
    string[] k = aa.keys;
    // insertion sort: poucos schemas e sem importar std.algorithm
    foreach (i; 1 .. k.length)
        for (size_t j = i; j > 0 && k[j - 1] > k[j]; j--)
        {
            auto t = k[j];
            k[j] = k[j - 1];
            k[j - 1] = t;
        }
    return k;
}

/// Página interativa (Swagger UI carregado de CDN pelo navegador do usuário).
string docsHtml(string jsonPath, string title) @safe
{
    return `<!doctype html><html><head><meta charset="utf-8"><title>` ~ title
        ~ ` — docs</title><meta name="viewport" content="width=device-width, initial-scale=1">`
        ~ `<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui.css"></head>`
        ~ `<body><div id="ui"></div><script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui-bundle.js"></script>`
        ~ `<script>SwaggerUIBundle({url:` ~ q(jsonPath) ~ `,dom_id:"#ui"})</script></body></html>`;
}
