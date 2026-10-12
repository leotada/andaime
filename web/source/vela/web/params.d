/// Tipos que o usuário escreve nas assinaturas dos handlers.
module vela.web.params;

import vela.http.types : HeaderField;

/// Corpo JSON decodificado em `T`. Acesse os campos direto: `body.name`.
struct JsonBody(T)
{
    T value;
    alias value this;
}

/// Valor de um header. É uma fatia zero-copy do buffer de rede:
/// válida só durante a requisição. Para guardar, use `.idup`.
struct Header(string name)
{
    enum string headerName = name;
    const(char)[] value;
    alias value this;
}

/// Valor deixado por um middleware em `ctx.locals`. Se nenhum middleware o
/// definiu, a requisição falha com 500 (erro de configuração, não do cliente).
struct Local(T)
{
    T value;
    alias value this;
}

/// Parâmetro opcional: `Optional!int page`, `Optional!(Header!"X-Trace")`.
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
        assert(_has, "Optional vazio: verifique .has antes de .get");
        return _value;
    }

    inout(T) getOr(inout(T) fallback) inout => _has ? _value : fallback;
}

/// Retorno com status diferente de 200: `return withStatus(201, user);`
struct WithStatus(T)
{
    int status;
    T value;
}

WithStatus!T withStatus(T)(int status, T value) => WithStatus!T(status, value);

/// Resposta montada à mão (redirect, content-type próprio, headers extras).
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

/// Lançada pelo handler para responder com erro: `throw new HttpError(404, "usuário não encontrado");`
class HttpError : Exception
{
    int status;

    this(int status, string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
        this.status = status;
    }
}

// ---- reconhecimento dos wrappers (rasos, sem recursão)

enum isJsonBody(T) = is(T == JsonBody!U, U);
enum isHeader(T) = is(T == Header!n, string n);
enum isLocal(T) = is(T == Local!U, U);
enum isOptional(T) = is(T == Optional!U, U);
enum isWithStatus(T) = is(T == WithStatus!U, U);

enum isCharType(T) = is(immutable T == immutable char) || is(immutable T == immutable wchar)
    || is(immutable T == immutable dchar);

/// Escalares extraíveis de path, query ou header.
enum isScalar(T) = is(T == bool) || is(T == enum)
    || (__traits(isIntegral, T) && !isCharType!T)
    || __traits(isFloating, T)
    || is(T == string) || is(T == const(char)[]);
