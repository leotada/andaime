/// Header `Date` (IMF-fixdate, RFC 9110 §5.6.7) com cache de um segundo.
/// Formatar uma vez por segundo por thread é mais barato que por resposta.
module vela.http.date;

import core.stdc.time : time_t, time, tm;
import core.sys.posix.time : gmtime_r;

/// Escreve "Mon, 12 Oct 2026 21:10:00 GMT" (29 bytes) para o instante `t`.
void formatHttpDate(time_t t, ref char[29] buf) nothrow @nogc @trusted
{
    static immutable string[7] days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    static immutable string[12] months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

    tm parts;
    gmtime_r(&t, &parts);

    void two(size_t at, int v)
    {
        buf[at] = cast(char)('0' + v / 10);
        buf[at + 1] = cast(char)('0' + v % 10);
    }

    buf[0 .. 3] = days[parts.tm_wday][];
    buf[3 .. 5] = ", ";
    two(5, parts.tm_mday);
    buf[7] = ' ';
    buf[8 .. 11] = months[parts.tm_mon][];
    buf[11] = ' ';
    immutable year = parts.tm_year + 1900;
    two(12, year / 100);
    two(14, year % 100);
    buf[16] = ' ';
    two(17, parts.tm_hour);
    buf[19] = ':';
    two(20, parts.tm_min);
    buf[22] = ':';
    two(23, parts.tm_sec);
    buf[25 .. 29] = " GMT";
}

private char[29] cached;       // variáveis de módulo são thread-local: um cache por worker
private time_t cachedAt = -1;

/// O `Date` de agora. A fatia vale até a próxima chamada nesta thread: use-a
/// já (o `setHeader` e o `writeResponseHead` acontecem sem suspender o fiber).
const(char)[] httpDate() nothrow @nogc @trusted
{
    immutable now = time(null);
    if (now != cachedAt)
    {
        formatHttpDate(now, cached);
        cachedAt = now;
    }
    return cached[];
}

unittest
{
    char[29] b;
    formatHttpDate(0, b);
    assert(b[] == "Thu, 01 Jan 1970 00:00:00 GMT", b[]);
    formatHttpDate(951_782_400, b);
    assert(b[] == "Tue, 29 Feb 2000 00:00:00 GMT", b[]);
    formatHttpDate(1_760_303_400, b);
    assert(b[] == "Sun, 12 Oct 2025 21:10:00 GMT", b[]);
    formatHttpDate(1_709_164_800, b);
    assert(b[] == "Thu, 29 Feb 2024 00:00:00 GMT", b[]);
    assert(httpDate().length == 29 && httpDate()[$ - 4 .. $] == " GMT");
}
