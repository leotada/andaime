/// UDAs de DTO e acumulador de erros de validação (formato FastAPI).
module vela.web.dto;

/// Nome do campo no JSON quando difere do nome em D: `@jsonKey("user_name") string userName;`
struct jsonKey { string name; }
/// Campo opcional no JSON (ausente => mantém o valor inicial).
enum optional;
/// Campo nunca lido nem escrito em JSON.
enum jsonIgnore;
/// Comprimento mínimo de string/array.
struct minLength { size_t value; }
/// Comprimento máximo de string/array.
struct maxLength { size_t value; }
/// Faixa fechada para números: `@inRange(0, 150) int age;`
struct inRange { double min; double max; }

/// Um erro de validação. `location` é "path", "query", "header" ou "body".
struct FieldError
{
    string location;
    const(char)[] field;
    string message;
}

/// Capacidade fixa: coletar erros nunca aloca. Excedentes só são contados.
struct FieldErrors
{
    enum size_t capacity = 16;
    FieldError[capacity] items;
    size_t count;
    size_t dropped;

    void add(string location, const(char)[] field, string message) nothrow @nogc @safe
    {
        if (count < capacity)
            items[count++] = FieldError(location, field, message);
        else
            dropped++;
    }

    bool any() const nothrow @nogc @safe => count > 0;

    void clear() nothrow @nogc @safe
    {
        count = 0;
        dropped = 0;
    }

    const(FieldError)[] list() const nothrow @nogc @safe return => items[0 .. count];
}

/// Caminho do campo atual ("endereco.cep") num buffer fixo: só vira
/// string (alocando) quando um erro precisa ser reportado.
struct FieldPath
{
    private char[192] buf;
    private size_t len;

    size_t push(scope const(char)[] key) nothrow @nogc @safe
    {
        immutable old = len;
        if (len && len < buf.length)
            buf[len++] = '.';
        immutable n = key.length < buf.length - len ? key.length : buf.length - len;
        buf[len .. len + n] = key[0 .. n];
        len += n;
        return old;
    }

    void pop(size_t mark) nothrow @nogc @safe
    {
        len = mark;
    }

    const(char)[] current() const nothrow @nogc @safe return => buf[0 .. len];
}

/// true se o membro `i` de T carrega a UDA `A` (tipo ou enum).
template hasUda(T, size_t i, alias A)
{
    enum hasUda = () {
        bool r;
        static foreach (attr; __traits(getAttributes, T.tupleof[i]))
            static if (is(attr == A) || is(typeof(attr) == A))
                r = true;
        return r;
    }();
}

/// Chave JSON do campo `i` de T.
template jsonKeyOf(T, size_t i)
{
    enum jsonKeyOf = () {
        string r = __traits(identifier, T.tupleof[i]);
        static foreach (attr; __traits(getAttributes, T.tupleof[i]))
            static if (is(typeof(attr) == jsonKey))
                r = attr.name;
        return r;
    }();
}

/// Número -> texto em CTFE (evita std.conv no núcleo).
string ctNum(ulong v) pure nothrow @safe
{
    if (v == 0)
        return "0";
    string r;
    while (v)
    {
        r = cast(char)('0' + v % 10) ~ r;
        v /= 10;
    }
    return r;
}

private enum string minLenMsg(size_t n) = "abaixo do comprimento mínimo de " ~ ctNum(n);
private enum string maxLenMsg(size_t n) = "acima do comprimento máximo de " ~ ctNum(n);

/// Aplica as UDAs de validação do campo `i` ao valor já decodificado.
void validateField(T, size_t i, V)(ref const V value, ref FieldErrors errs, ref const FieldPath path)
{
    static foreach (attr; __traits(getAttributes, T.tupleof[i]))
    {
        static if (is(typeof(attr) == minLength))
        {
            static assert(__traits(compiles, value.length),
                "vela: @minLength só vale para string ou array (campo '" ~ __traits(identifier, T.tupleof[i]) ~ "')");
            if (value.length < attr.value)
                errs.add("body", path.current.idup, minLenMsg!(attr.value));
        }
        else static if (is(typeof(attr) == maxLength))
        {
            static assert(__traits(compiles, value.length),
                "vela: @maxLength só vale para string ou array (campo '" ~ __traits(identifier, T.tupleof[i]) ~ "')");
            if (value.length > attr.value)
                errs.add("body", path.current.idup, maxLenMsg!(attr.value));
        }
        else static if (is(typeof(attr) == inRange))
        {
            static assert(__traits(isArithmetic, V),
                "vela: @inRange só vale para números (campo '" ~ __traits(identifier, T.tupleof[i]) ~ "')");
            if (value < attr.min || value > attr.max)
                errs.add("body", path.current.idup, "fora da faixa permitida");
        }
    }
}
