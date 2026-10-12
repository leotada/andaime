/// Parser incremental e zero-copy do head de uma requisição HTTP/1.1.
/// Puro (sem I/O): recebe bytes, devolve fatias. Alvo de fuzzing no M3.
module vela.http.parser;

import vela.http.types;

@safe:

struct Limits
{
    size_t maxHeadBytes = 8 * 1024;   /// 431 acima disso
    size_t maxTargetBytes = 4 * 1024; /// 414 acima disso
    size_t maxBodyBytes = 1024 * 1024; /// 413 acima disso
}

enum ParseStatus { complete, incomplete, error }

struct HeadResult
{
    ParseStatus status;
    size_t headLength;    /// bytes do head, incluindo o CRLFCRLF final
    size_t contentLength; /// tamanho do corpo a ler depois do head
    int errorStatus;      /// código HTTP a responder quando status == error
}

private HeadResult fail(int code) pure nothrow @nogc
{
    return HeadResult(ParseStatus.error, 0, 0, code);
}

private bool isTchar(char c) pure nothrow @nogc
{
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
        return true;
    switch (c)
    {
        case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
            return true;
        default:
            return false;
    }
}

/// Procura "\r\n\r\n". O M4 troca por busca vetorizada (core.simd).
private ptrdiff_t findHeadEnd(scope const(char)[] buf) pure nothrow @nogc
{
    if (buf.length < 4)
        return -1;
    foreach (i; 0 .. buf.length - 3)
        if (buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n')
            return i;
    return -1;
}

/// Faz o parse do head em `buf`. Em `complete`, todas as fatias de `req`
/// apontam para dentro de `buf`; `headerStore` é fornecido pelo chamador
/// (array fixo da conexão), então nada é alocado.
HeadResult parseRequestHead(return scope const(char)[] buf, ref Request req,
    return scope HeaderField[] headerStore, in Limits limits = Limits.init) pure nothrow @nogc
{
    auto end = findHeadEnd(buf);
    if (end < 0)
        return buf.length > limits.maxHeadBytes ? fail(431)
            : HeadResult(ParseStatus.incomplete);
    if (end + 4 > limits.maxHeadBytes)
        return fail(431);

    const(char)[] head = buf[0 .. end + 2]; // inclui o CRLF da última linha
    size_t p = 0;

    // ---- linha de requisição: METHOD SP target SP HTTP/1.x CRLF
    size_t s = p;
    while (p < head.length && head[p] != ' ')
        p++;
    if (p == head.length || p == s)
        return fail(400);
    req.method = parseMethod(head[s .. p]);
    if (req.method == Method.unknown)
        return fail(501);
    p++;

    s = p;
    while (p < head.length && head[p] != ' ' && head[p] != '\r')
        p++;
    if (p == head.length || head[p] != ' ' || p == s)
        return fail(400);
    req.target = head[s .. p];
    if (req.target.length > limits.maxTargetBytes)
        return fail(414);
    if (req.target[0] != '/' && !(req.method == Method.OPTIONS && req.target == "*"))
        return fail(400); // só origin-form no MVP
    foreach (char c; req.target)
        if (c <= ' ' || c == 0x7f)
            return fail(400);
    splitTarget(req.target, req.path, req.query);
    p++;

    // "HTTP/" digito "." digito CRLF: formato errado = 400; versão que não é 1.0/1.1 = 505
    if (p + 10 > head.length || head[p .. p + 5] != "HTTP/" || head[p + 6] != '.'
        || head[p + 5] < '0' || head[p + 5] > '9' || head[p + 7] < '0' || head[p + 7] > '9'
        || head[p + 8 .. p + 10] != "\r\n")
        return fail(400);
    if (head[p + 5] != '1')
        return fail(505);
    immutable char minor = head[p + 7];
    if (minor != '0' && minor != '1')
        return fail(505);
    req.keepAlive = minor == '1';
    p += 10;

    // ---- headers
    size_t n = 0;
    bool sawLength = false, sawTE = false;
    size_t contentLength = 0;
    while (p < head.length)
    {
        if (head[p] == ' ' || head[p] == '\t')
            return fail(400); // obs-fold é proibido (RFC 9112 §5.2)
        s = p;
        while (p < head.length && head[p] != ':' && head[p] != '\r')
        {
            if (!isTchar(head[p]))
                return fail(400);
            p++;
        }
        if (p == head.length || head[p] != ':' || p == s)
            return fail(400);
        auto name = head[s .. p];
        p++;
        while (p < head.length && (head[p] == ' ' || head[p] == '\t'))
            p++;
        s = p;
        while (p < head.length && head[p] != '\r')
        {
            if (head[p] == '\n' || head[p] == 0)
                return fail(400);
            p++;
        }
        size_t e = p;
        while (e > s && (head[e - 1] == ' ' || head[e - 1] == '\t'))
            e--;
        auto value = head[s .. e];
        if (p + 1 >= head.length || head[p + 1] != '\n')
            return fail(400);
        p += 2;

        if (n == headerStore.length)
            return fail(431);
        headerStore[n++] = HeaderField(name, value);

        if (equalsIgnoreCase(name, "content-length"))
        {
            size_t v = 0;
            if (value.length == 0 || value.length > 18)
                return fail(400);
            foreach (char c; value)
            {
                if (c < '0' || c > '9')
                    return fail(400);
                v = v * 10 + (c - '0');
            }
            if (sawLength && v != contentLength)
                return fail(400); // valores divergentes: possível smuggling
            sawLength = true;
            contentLength = v;
        }
        else if (equalsIgnoreCase(name, "transfer-encoding"))
            sawTE = true;
        else if (equalsIgnoreCase(name, "expect"))
        {
            if (!equalsIgnoreCase(value, "100-continue"))
                return fail(417);
        }
        else if (equalsIgnoreCase(name, "connection"))
        {
            if (equalsIgnoreCase(value, "close"))
                req.keepAlive = false;
            else if (equalsIgnoreCase(value, "keep-alive"))
                req.keepAlive = true;
        }
    }

    if (sawTE && sawLength)
        return fail(400); // RFC 9112 §6.1: rejeitar para evitar smuggling
    if (sawTE)
        return fail(501); // corpo chunked na requisição entra no M3
    if (contentLength > limits.maxBodyBytes)
        return fail(413);

    req.headers = headerStore[0 .. n];
    return HeadResult(ParseStatus.complete, end + 4, contentLength, 0);
}

unittest
{
    HeaderField[32] store;
    Request r;
    string raw = "PUT /users/42?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 7\r\n"
        ~ "Authorization:  Bearer t  \r\n\r\n{\"a\":1}";
    auto h = parseRequestHead(raw, r, store[]);
    assert(h.status == ParseStatus.complete);
    assert(r.method == Method.PUT && r.path == "/users/42" && r.query == "x=1");
    assert(r.header("authorization") == "Bearer t");
    assert(h.contentLength == 7 && raw[h.headLength .. $] == "{\"a\":1}");
    assert(r.keepAlive);

    // incompleto
    assert(parseRequestHead("GET / HTTP/1.1\r\nHost: a\r\n", r, store[]).status == ParseStatus.incomplete);
    // smuggling: CL + TE
    auto bad = parseRequestHead("POST / HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
        r, store[]);
    assert(bad.status == ParseStatus.error && bad.errorStatus == 400);
    // obs-fold
    assert(parseRequestHead("GET / HTTP/1.1\r\nA: b\r\n c\r\n\r\n", r, store[]).errorStatus == 400);
    // versão
    assert(parseRequestHead("GET / HTTP/2.0\r\n\r\n", r, store[]).errorStatus == 505);
    // HTTP/1.0 sem keep-alive fecha
    parseRequestHead("GET / HTTP/1.0\r\n\r\n", r, store[]);
    assert(!r.keepAlive);
}
