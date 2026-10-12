/// Ligação mínima com a libpq, carregada em tempo de execução (dlopen).
/// Sem cabeçalhos e sem `-lpq` na compilação: o vela compila em qualquer
/// máquina, e só quem usa o driver precisa da libpq instalada
/// (`libpq5` no Debian/Ubuntu, `libpq` no Alpine).
module vela.db.libpq;

import core.sys.posix.dlfcn : dlopen, dlsym, dlerror, RTLD_NOW;

package:

struct PGconn;
struct PGresult;
struct PGcancel;

enum : int
{
    CONNECTION_OK = 0,
    CONNECTION_BAD = 1,
}

enum : int
{
    PGRES_POLLING_FAILED = 0,
    PGRES_POLLING_READING = 1,
    PGRES_POLLING_WRITING = 2,
    PGRES_POLLING_OK = 3,
}

enum : int
{
    PGRES_EMPTY_QUERY = 0,
    PGRES_COMMAND_OK = 1,
    PGRES_TUPLES_OK = 2,
    PGRES_BAD_RESPONSE = 5,
    PGRES_NONFATAL_ERROR = 6,
    PGRES_FATAL_ERROR = 7,
}

enum char PG_DIAG_SQLSTATE = 'C';

alias NoticeProc = extern (C) void function(void* arg, const(char)* message) nothrow;

/// Tabela de funções. Fica numa struct de propósito: variáveis `extern (C)` soltas virariam
/// símbolos globais com o MESMO nome das funções da libpq, e o ligador dinâmico faria a
/// própria libpq chamar nossos ponteiros em vez do código dela.
struct Api
{
    extern (C) nothrow @nogc:

    PGconn* function(const(char)*) PQconnectStart;
    int function(PGconn*) PQconnectPoll;
    int function(const(PGconn)*) PQstatus;
    int function(const(PGconn)*) PQsocket;
    int function(PGconn*, int) PQsetnonblocking;
    void function(PGconn*) PQfinish;
    char* function(const(PGconn)*) PQerrorMessage;
    int function(PGconn*, const(char)*, int, const(uint)*, const(char*)*, const(int)*, const(int)*, int) PQsendQueryParams;
    int function(PGconn*, const(char)*, const(char)*, int, const(uint)*) PQsendPrepare;
    int function(PGconn*, const(char)*, int, const(char*)*, const(int)*, const(int)*, int) PQsendQueryPrepared;
    int function(PGconn*) PQconsumeInput;
    int function(PGconn*) PQisBusy;
    int function(PGconn*) PQflush;
    PGresult* function(PGconn*) PQgetResult;
    void function(PGresult*) PQclear;
    int function(const(PGresult)*) PQresultStatus;
    char* function(const(PGresult)*) PQresultErrorMessage;
    char* function(const(PGresult)*, int) PQresultErrorField;
    int function(const(PGresult)*) PQntuples;
    int function(const(PGresult)*) PQnfields;
    char* function(const(PGresult)*, int) PQfname;
    int function(const(PGresult)*, int, int) PQgetisnull;
    char* function(const(PGresult)*, int, int) PQgetvalue;
    int function(const(PGresult)*, int, int) PQgetlength;
    char* function(const(PGresult)*) PQcmdTuples;
    PGcancel* function(PGconn*) PQgetCancel;
    int function(PGcancel*, char*, int) PQcancel;
    void function(PGcancel*) PQfreeCancel;
    NoticeProc function(PGconn*, NoticeProc, void*) PQsetNoticeProcessor;
}

__gshared Api pq;

private __gshared bool loaded;
private __gshared string loadError;

/// Carrega a libpq uma vez. Devolve null se deu certo, ou a mensagem de erro.
string loadLibpq() @trusted
{
    synchronized (gLock)
        return loadLocked();
}

private __gshared Object gLock;

shared static this()
{
    gLock = new Object;
}

private string loadLocked() @trusted
{
    if (loaded)
        return null;
    if (loadError !is null)
        return loadError;

    void* h;
    foreach (name; ["libpq.so.5\0", "libpq.so\0", "libpq.5.dylib\0"])
        if ((h = dlopen(name.ptr, RTLD_NOW)) !is null)
            break;
    if (h is null)
        return loadError = "vela.db: libpq não encontrada (instale libpq5 / libpq)";

    static foreach (m; __traits(allMembers, Api))
    {
        {
            auto p = dlsym(h, (m ~ "\0").ptr);
            if (p is null)
                return loadError = "vela.db: símbolo ausente na libpq: " ~ m;
            __traits(getMember, pq, m) = cast(typeof(__traits(getMember, pq, m))) p;
        }
    }
    loaded = true;
    return null;
}
