/// Minimal binding to libpq, loaded at run time (dlopen).
/// No headers and no `-lpq` at build time: andaime builds on any
/// machine, and only whoever uses the driver needs libpq installed
/// (`libpq5` on Debian/Ubuntu, `libpq` on Alpine).
module andaime.db.libpq 2025;

@safe:

import andaime.engine.os : dlOpen, dlSym, dlError;

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

/// `PQtransactionStatus`.
enum : int
{
    PQTRANS_IDLE = 0,
    PQTRANS_ACTIVE = 1,
    PQTRANS_INTRANS = 2,
    PQTRANS_INERROR = 3,
    PQTRANS_UNKNOWN = 4,
}

enum char PG_DIAG_SQLSTATE = 'C';

alias NoticeProc = extern (C) void function(void* arg, const(char)* message) nothrow;

/// One `LISTEN`/`NOTIFY` payload. `PQnotifies` returns this; `PQfreeNotify` frees it.
/// `next` is libpq's private list link. Callers copy `relname` and `extra`, then free the node.
extern (C) struct PGnotify
{
    char* relname;
    int be_pid;
    char* extra;
    PGnotify* next;
}

/// Function table. It lives in a struct on purpose: loose `extern (C)` variables would become
/// global symbols with the SAME name as libpq's functions, and the dynamic linker would make
/// libpq itself call our pointers instead of its own code.
struct Api
{
    extern (C) nothrow @nogc:

    PGconn* function(const(char)*) PQconnectStart;
    int function(PGconn*) PQconnectPoll;
    int function(const(PGconn)*) PQstatus;
    int function(const(PGconn)*) PQtransactionStatus;
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
    PGnotify* function(PGconn*) PQnotifies;
    void function(PGnotify*) PQfreeNotify;
}

__gshared Api pq;

private __gshared bool loaded;
private __gshared string loadError;

/// Loads libpq once. Returns null on success, or the error message.
string loadLibpq() @trusted
{
    synchronized (gLock)
        return loadLocked();
}

private __gshared Object gLock;

shared static this() @trusted
{
    gLock = new Object;
}

private string loadLocked() @trusted nothrow
{
    if (loaded)
        return null;
    if (loadError !is null)
        return loadError;

    version (linux)
        immutable string[] names = ["libpq.so.5\0", "libpq.so\0"];
    else version (OSX)
        immutable string[] names = [
            "libpq.5.dylib\0",
            "libpq.dylib\0",
            "/opt/homebrew/opt/libpq/lib/libpq.5.dylib\0",
            "/usr/local/opt/libpq/lib/libpq.5.dylib\0"
        ];
    else version (Windows)
        immutable string[] names = ["libpq.dll\0"];

    void* h;
    string detail;
    foreach (name; names)
        if ((h = dlOpen(name.ptr)) !is null)
            break;
        else if (detail is null)
            detail = dlError();
    if (h is null)
        return loadError = "andaime.db: libpq not found (install libpq5 / libpq)"
            ~ (detail is null ? "" : ": " ~ detail);

    static foreach (m; __traits(allMembers, Api))
    {
        {
            auto p = dlSym(h, (m ~ "\0").ptr);
            if (p is null)
                return loadError = "andaime.db: missing symbol in libpq: " ~ m;
            __traits(getMember, pq, m) = cast(typeof(__traits(getMember, pq, m))) p;
        }
    }
    loaded = true;
    return null;
}
