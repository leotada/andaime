/// Driver PostgreSQL cooperativo sobre a libpq assíncrona.
///
/// Dentro de uma requisição, toda espera (conexão, envio, resposta) passa por
/// `awaitFd`: o fiber suspende e o worker atende outras conexões. Nenhuma
/// chamada bloqueia o loop, qualquer que seja a latência do banco (RDS remoto,
/// por exemplo). O DNS do host é resolvido numa thread do pool (`offload`).
///
/// ```d
/// auto db = pgPool("host=meu-rds.exemplo.rds.amazonaws.com dbname=app user=app");
/// auto res = db.query("select id, name from users where id = $1", id);
/// auto users = res.rowsAs!User;          // User tem campos id e name
/// ```
///
/// Regras:
///  - cada worker tem seu próprio pool de conexões (thread-local): use `pgPool`;
///  - uma conexão atende uma consulta por vez; o pool dá uma por fiber;
///  - se a requisição é cancelada ou a consulta estoura o prazo no meio, o
///    driver pede ao servidor para cancelar e DESCARTA a conexão (nunca a
///    devolve ao pool com resposta pendente);
///  - parâmetros vão em formato texto ($1, $2...), então não há SQL injection
///    por concatenação: nunca monte SQL com valores do usuário.
module vela.db.pg;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;
import core.time : Duration, MonoTime, msecs, seconds, minutes;

import core.sys.linux.sys.eventfd : eventfd;
import core.sys.posix.unistd : close, write;

import vela.engine.fiberio : awaitFd, currentScheduler, IoEvent, RequestCancelled;
import vela.engine.offload : offload, offloadPool;
import vela.db.libpq;

// ============================================================ erros

/// Erro do banco ou do driver. `sqlState` é o código de 5 caracteres do
/// PostgreSQL (ex.: "23505" = violação de unicidade); vazio para erros do driver.
class PgError : Exception
{
    string sqlState;

    this(string msg, string sqlState = null, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.sqlState = sqlState;
    }

    bool isUniqueViolation() const pure nothrow @safe @nogc => sqlState == "23505";
    bool isForeignKeyViolation() const pure nothrow @safe @nogc => sqlState == "23503";
}

/// A consulta passou do prazo (`PgConfig.queryTimeout`); o servidor foi avisado.
final class PgTimeout : PgError
{
    this(string msg = "vela.db: consulta passou do prazo", string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, "57014", file, line);
    }
}

// ============================================================ valores

/// Coluna/parâmetro que pode ser NULL.
struct Maybe(T)
{
    T value;
    bool has;

    this(T v) { value = v; has = true; }
    static Maybe none() { return Maybe.init; }
}

// ============================================================ resultado

/// Resultado de uma consulta. As fatias de `text` apontam para memória da
/// libpq e valem até `close()` (ou até o objeto ser coletado): copie com
/// `.idup` o que precisar guardar. `rowsAs` e `get` já copiam.
final class PgResult
{
    private PGresult* res;
    private string tag;

    /// Número de linhas e de colunas.
    int rows, cols;

    private this(PGresult* r)
    {
        res = r;
        rows = pq.PQntuples(r);
        cols = pq.PQnfields(r);
    }

    ~this() { close(); }

    void close() nothrow @nogc
    {
        if (res !is null)
        {
            pq.PQclear(res);
            res = null;
        }
    }

    /// Linhas afetadas por INSERT/UPDATE/DELETE ("" para SELECT).
    const(char)[] affected() const nothrow
    {
        auto p = pq.PQcmdTuples(res);
        return cstr(p);
    }

    bool isNull(int row, int col) const nothrow => pq.PQgetisnull(res, row, col) != 0;

    /// O valor em texto (zero-copy). Vazio para NULL: use `isNull` para distinguir.
    const(char)[] text(int row, int col) const nothrow
    {
        checkIdx(row, col);
        return pq.PQgetvalue(res, row, col)[0 .. pq.PQgetlength(res, row, col)];
    }

    /// Índice da coluna chamada `name`, ou -1.
    int column(const(char)[] name) const nothrow
    {
        foreach (c; 0 .. cols)
            if (cstr(pq.PQfname(res, c)) == name)
                return c;
        return -1;
    }

    /// Converte uma célula para `T` (inteiros, bool, double, string, Maybe!X).
    T get(T)(int row, int col) const
    {
        checkIdx(row, col);
        static if (is(T == Maybe!U, U))
        {
            if (isNull(row, col))
                return T.init;
            return T(get!U(row, col));
        }
        else
        {
            if (isNull(row, col))
                throw new PgError("vela.db: coluna '" ~ cstr(pq.PQfname(res, col)).idup
                        ~ "' é NULL; use Maybe!" ~ T.stringof ~ " no campo");
            return parseCell!T(text(row, col), cstr(pq.PQfname(res, col)));
        }
    }

    /// Mapeia todas as linhas para uma struct, casando campos e colunas pelo nome.
    T[] rowsAs(T)() const if (is(T == struct))
    {
        int[T.tupleof.length] idx;
        static foreach (i, f; T.tupleof)
        {
            idx[i] = column(__traits(identifier, f));
            if (idx[i] < 0)
                throw new PgError("vela.db: a consulta não devolveu a coluna '"
                        ~ __traits(identifier, f) ~ "' esperada por " ~ T.stringof);
        }
        auto out_ = new T[rows];
        foreach (r; 0 .. rows)
        {
            static foreach (i, f; T.tupleof)
                mixin("out_[r].", __traits(identifier, f), " = get!(typeof(f))(r, idx[i]);");
        }
        return out_;
    }

    /// Primeira linha como struct; lança se não houver.
    T one(T)() const if (is(T == struct))
    {
        auto all = rowsAs!T;
        if (all.length == 0)
            throw new PgError("vela.db: a consulta não devolveu linhas");
        return all[0];
    }

    private void checkIdx(int row, int col) const nothrow
    {
        assert(row >= 0 && row < rows && col >= 0 && col < cols, "vela.db: linha/coluna fora do resultado");
    }
}

private const(char)[] cstr(const(char)* p) nothrow
{
    if (p is null)
        return null;
    size_t n;
    while (p[n])
        n++;
    return p[0 .. n];
}

private T parseCell(T)(const(char)[] s, const(char)[] col)
{
    import std.traits : isIntegral, isSigned, isFloatingPoint, isSomeString;

    static if (is(T == bool))
    {
        if (s == "t") return true;
        if (s == "f") return false;
        throw badCell(col, "bool", s);
    }
    else static if (isIntegral!T)
    {
        size_t i;
        bool neg;
        if (s.length && (s[0] == '-' || s[0] == '+'))
        {
            neg = s[0] == '-';
            i = 1;
        }
        if (i == s.length)
            throw badCell(col, T.stringof, s);
        ulong acc;
        for (; i < s.length; i++)
        {
            immutable d = s[i] - '0';
            if (d < 0 || d > 9 || acc > (ulong.max - d) / 10)
                throw badCell(col, T.stringof, s);
            acc = acc * 10 + d;
        }
        static if (isSigned!T)
        {
            if (neg ? acc > cast(ulong) T.max + 1 : acc > cast(ulong) T.max)
                throw badCell(col, T.stringof, s);
            return cast(T)(neg ? -cast(long) acc : cast(long) acc);
        }
        else
        {
            if ((neg && acc != 0) || acc > T.max)
                throw badCell(col, T.stringof, s);
            return cast(T) acc;
        }
    }
    else static if (isFloatingPoint!T)
    {
        // os valores da libpq são terminados em zero
        const(char)* end;
        auto v = strtod(s.ptr, &end);
        if (end != s.ptr + s.length || s.length == 0)
            throw badCell(col, T.stringof, s);
        return cast(T) v;
    }
    else static if (isSomeString!T)
        return s.idup;
    else
        static assert(0, "vela.db: tipo de campo não suportado em rowsAs/get: " ~ T.stringof
                ~ " (use inteiros, bool, double, string ou Maybe!X)");
}

private PgError badCell(const(char)[] col, string type, const(char)[] val)
{
    return new PgError("vela.db: coluna '" ~ col.idup ~ "' tem o valor '" ~ val.idup ~ "', que não é " ~ type);
}

// ============================================================ parâmetros

/// Codifica os parâmetros em texto para PQsendQueryParams.
private struct Encoded(size_t N)
{
    char[] buf;
    const(char)*[N] vals;

    this(Args...)(ref Args args)
    {
        ptrdiff_t[N] offs;
        static foreach (i; 0 .. N)
            offs[i] = put(args[i]);
        foreach (i; 0 .. N)
            vals[i] = offs[i] < 0 ? null : buf.ptr + offs[i];
    }

    private ptrdiff_t put(A)(ref A a)
    {
        import std.traits : isIntegral, isFloatingPoint, isSomeString, Unqual;

        alias U = Unqual!A;
        static if (is(U == typeof(null)))
            return -1;
        else static if (is(U == Maybe!X, X))
            return a.has ? put(a.value) : -1;
        else static if (is(U == bool))
            return append(a ? "t" : "f");
        else static if (isIntegral!U)
        {
            char[24] tmp;
            size_t n = tmp.length;
            bool neg = a < 0;
            ulong v = neg ? -cast(long) a : a;
            do
            {
                tmp[--n] = cast(char)('0' + v % 10);
                v /= 10;
            }
            while (v);
            if (neg)
                tmp[--n] = '-';
            return append(tmp[n .. $]);
        }
        else static if (isFloatingPoint!U)
        {
            char[40] tmp;
            auto n = snprintf(tmp.ptr, tmp.length, "%.17g", cast(double) a);
            return append(tmp[0 .. n]);
        }
        else static if (isSomeString!U || is(U : const(char)[]))
            return append(a);
        else
            static assert(0, "vela.db: parâmetro de tipo não suportado: " ~ A.stringof
                    ~ " (use inteiros, bool, double, string, null ou Maybe!X)");
    }

    private ptrdiff_t append(const(char)[] s)
    {
        immutable at = buf.length;
        buf ~= s;
        buf ~= '\0';
        return at;
    }
}

// ============================================================ configuração

struct PgConfig
{
    string conninfo;                      /// "host=... dbname=... user=..." ou URI postgresql://
    uint maxConns = 8;                    /// conexões por worker
    Duration connectTimeout = 10.seconds;
    Duration acquireTimeout = 5.seconds;  /// espera por uma conexão livre
    Duration queryTimeout = 30.seconds;   /// prazo de cada consulta
    Duration idleTimeout = 5.minutes;     /// conexão ociosa por mais que isso é descartada
    /// Prepara cada SQL na primeira vez e reaproveita o plano nas próximas (até 128 por
    /// conexão). Desligado por padrão: PgBouncer em modo transaction e alguns proxies
    /// não aceitam statements nomeados. Ligue quando falar direto com o Postgres/RDS.
    bool cacheStatements = false;
}

// ============================================================ conexão

/// Uma conexão. Use pelo pool (`PgPool.acquire`/`query`); uma consulta por vez.
final class PgConn
{
    private PGconn* c;
    private Duration queryTimeout;
    private bool cacheStatements;
    private uint[string] stmts;      // SQL -> número do statement preparado nesta conexão
    private enum maxStatements = 128;
    private MonoTime lastUsed;
    package bool broken;

    private this(PGconn* conn, Duration qt, bool cache)
    {
        c = conn;
        queryTimeout = qt;
        cacheStatements = cache;
        lastUsed = MonoTime.currTime;
    }

    ~this() { shutdown(); }

    /// Fecha a conexão (idempotente).
    void shutdown() nothrow @nogc
    {
        if (c !is null)
        {
            pq.PQfinish(c);
            c = null;
        }
        broken = true;
    }

    bool usable() const nothrow => c !is null && !broken && pq.PQstatus(c) == CONNECTION_OK;

    /// Abre uma conexão sem bloquear o worker.
    static PgConn connect(string conninfo, Duration connectTimeout, Duration queryTimeout, bool cacheStatements = false)
    {
        if (auto err = loadLibpq())
            throw new PgError(err);

        // PQconnectStart resolve DNS de forma síncrona: numa thread do pool.
        auto zinfo = (conninfo ~ '\0');
        PGconn* c = offload(() => pq.PQconnectStart(zinfo.ptr));
        if (c is null)
            throw new PgError("vela.db: PQconnectStart falhou (sem memória)");
        auto conn = new PgConn(c, queryTimeout, cacheStatements);
        pq.PQsetNoticeProcessor(c, &silentNotice, null);

        scope (failure)
            conn.shutdown();

        if (pq.PQstatus(c) == CONNECTION_BAD)
            throw new PgError("vela.db: " ~ conn.lastError());
        pq.PQsetnonblocking(c, 1);

        immutable deadline = MonoTime.currTime + connectTimeout;
        int state = PGRES_POLLING_WRITING;
        for (;;)
        {
            immutable left = deadline - MonoTime.currTime;
            if (left <= Duration.zero)
                throw new PgError("vela.db: tempo esgotado ao conectar");
            immutable fd = pq.PQsocket(c);
            if (fd < 0)
                throw new PgError("vela.db: " ~ conn.lastError());
            if (state == PGRES_POLLING_READING)
            {
                if (awaitFd(fd, IoEvent.readable, left) == 0)
                    throw new PgError("vela.db: tempo esgotado ao conectar");
            }
            else if (state == PGRES_POLLING_WRITING)
            {
                if (awaitFd(fd, IoEvent.writable, left) == 0)
                    throw new PgError("vela.db: tempo esgotado ao conectar");
            }
            state = pq.PQconnectPoll(c);
            if (state == PGRES_POLLING_OK)
                break;
            if (state == PGRES_POLLING_FAILED)
                throw new PgError("vela.db: " ~ conn.lastError());
        }
        return conn;
    }

    /// Executa `sql` com parâmetros $1..$n e devolve o resultado.
    PgResult query(Args...)(const(char)[] sql, Args args)
    {
        auto enc = Encoded!(Args.length)(args);
        return run(sql, enc.vals[]);
    }

    private void exec_(const(char)[] sql)
    {
        immutable old = cacheStatements;
        cacheStatements = false; // utilitários como DEALLOCATE não passam pelo cache
        scope (exit)
            cacheStatements = old;
        run(sql, null, true).close();
    }

    /// Executa um comando sem interesse no resultado (BEGIN, UPDATE...).
    void exec(Args...)(const(char)[] sql, Args args)
    {
        query(sql, args).close();
    }

    private PgResult run(const(char)[] sql, const(char)*[] vals, bool retried = false)
    {
        if (!usable)
            throw new PgError("vela.db: conexão fechada");
        auto zsql = sql ~ '\0';

        bool clean;
        scope (exit)
        {
            lastUsed = MonoTime.currTime;
            if (!clean) // cancelamento, prazo ou erro de rede no meio: a conexão não volta ao pool
                abort();
        }

        immutable deadline = queryTimeout == Duration.max ? MonoTime.max : MonoTime.currTime + queryTimeout;

        bool cached;
        uint stmtNo;
        if (cacheStatements)
        {
            if (auto p = sql in stmts)
            {
                stmtNo = *p;
                cached = true;
            }
            else if (stmts.length < maxStatements)
            {
                stmtNo = cast(uint) stmts.length + 1;
                prepare(sql, zsql, stmtNo, vals.length, deadline);
                stmts[sql.idup] = stmtNo;
                cached = true;
            }
        }

        if (cached)
        {
            char[16] name = stmtName(stmtNo);
            if (!pq.PQsendQueryPrepared(c, name.ptr, cast(int) vals.length,
                    vals.length ? vals.ptr : null, null, null, 0))
                throw new PgError("vela.db: " ~ lastError());
        }
        else if (!pq.PQsendQueryParams(c, zsql.ptr, cast(int) vals.length, null,
                vals.length ? vals.ptr : null, null, null, 0))
            throw new PgError("vela.db: " ~ lastError());

        flush(deadline);

        PGresult* kept;
        bool keptIsError;
        scope (failure)
            if (kept !is null)
                pq.PQclear(kept);

        for (;;)
        {
            waitResult(deadline);
            auto r = pq.PQgetResult(c);
            if (r is null)
                break;
            immutable st = pq.PQresultStatus(r);
            immutable isErr = st == PGRES_FATAL_ERROR || st == PGRES_BAD_RESPONSE;
            if (isErr && !keptIsError)
            {
                if (kept !is null)
                    pq.PQclear(kept);
                kept = r;
                keptIsError = true;
            }
            else if (!isErr && !keptIsError)
            {
                if (kept !is null)
                    pq.PQclear(kept);
                kept = r; // vale o último resultado do comando
            }
            else
                pq.PQclear(r);
        }
        clean = true;

        if (kept is null)
            throw new PgError("vela.db: o servidor não devolveu resultado");
        if (keptIsError)
        {
            auto state = cstr(pq.PQresultErrorField(kept, PG_DIAG_SQLSTATE)).idup;
            auto msg = cstr(pq.PQresultErrorMessage(kept)).idup;
            pq.PQclear(kept);
            kept = null;
            if (cached && state == "0A000" && !retried)
            {
                // "cached plan must not change result type" (ALTER TABLE depois de preparar):
                // esquece o statement e repete uma vez
                stmts.remove(cast(string) sql);
                exec_("DEALLOCATE ALL");
                stmts = null;
                return run(sql, vals, true);
            }
            throw new PgError(trimEol(msg), state);
        }
        return new PgResult(kept);
    }

    /// Prepara `sql` como statement `no` e espera a confirmação do servidor.
    private void prepare(const(char)[] sql, const(char)[] zsql, uint no, size_t nparams, MonoTime deadline)
    {
        char[16] name = stmtName(no);
        if (!pq.PQsendPrepare(c, name.ptr, zsql.ptr, cast(int) nparams, null))
            throw new PgError("vela.db: " ~ lastError());
        flush(deadline);
        PGresult* err;
        for (;;)
        {
            waitResult(deadline);
            auto r = pq.PQgetResult(c);
            if (r is null)
                break;
            immutable st = pq.PQresultStatus(r);
            if ((st == PGRES_FATAL_ERROR || st == PGRES_BAD_RESPONSE) && err is null)
                err = r;
            else
                pq.PQclear(r);
        }
        if (err !is null)
        {
            auto state = cstr(pq.PQresultErrorField(err, PG_DIAG_SQLSTATE)).idup;
            auto msg = trimEol(cstr(pq.PQresultErrorMessage(err)).idup);
            pq.PQclear(err);
            throw new PgError(msg, state);
        }
    }

    private static char[16] stmtName(uint no) pure nothrow @nogc @safe
    {
        char[16] n = 0;
        n[0] = 'v';
        n[1] = 'e';
        size_t i = 2;
        char[10] t;
        size_t k = t.length;
        do
        {
            t[--k] = cast(char)('0' + no % 10);
            no /= 10;
        }
        while (no);
        n[i .. i + (t.length - k)] = t[k .. $];
        return n;
    }

    /// Termina de enviar a consulta (o buffer de saída pode não caber de uma vez).
    private void flush(MonoTime deadline)
    {
        for (;;)
        {
            immutable f = pq.PQflush(c);
            if (f == 0)
                return;
            if (f < 0)
                throw new PgError("vela.db: " ~ lastError());
            immutable ev = awaitFd(pq.PQsocket(c), IoEvent.writable | IoEvent.readable, left(deadline));
            if (ev == 0)
                throw new PgTimeout;
            if (ev & IoEvent.readable)
                if (!pq.PQconsumeInput(c))
                    throw new PgError("vela.db: " ~ lastError());
        }
    }

    /// Espera até `PQgetResult` poder devolver sem bloquear.
    private void waitResult(MonoTime deadline)
    {
        while (pq.PQisBusy(c))
        {
            if (awaitFd(pq.PQsocket(c), IoEvent.readable, left(deadline)) == 0)
                throw new PgTimeout;
            if (!pq.PQconsumeInput(c))
                throw new PgError("vela.db: " ~ lastError());
        }
    }

    private static Duration left(MonoTime deadline)
    {
        if (deadline == MonoTime.max)
            return Duration.max;
        immutable d = deadline - MonoTime.currTime;
        return d <= Duration.zero ? Duration.zero : d;
    }

    /// Pede ao servidor para cancelar o que está rodando e fecha a conexão.
    /// O cancelamento abre outra conexão TCP; vai para o pool de threads para
    /// não segurar o worker (se o pool estiver cheio, faz na hora).
    private void abort() nothrow
    {
        if (c is null)
            return;
        auto cancel = pq.PQgetCancel(c);
        if (cancel !is null)
        {
            bool queued;
            try
                queued = offloadPool().submit(() { sendCancel(cancel); });
            catch (Throwable)
                queued = false;
            if (!queued)
                sendCancel(cancel);
        }
        shutdown();
    }

    private static void sendCancel(PGcancel* cancel) nothrow
    {
        char[256] err;
        pq.PQcancel(cancel, err.ptr, cast(int) err.length);
        pq.PQfreeCancel(cancel);
    }

    private string lastError() nothrow
    {
        return trimEol(cstr(pq.PQerrorMessage(c)).idup);
    }
}

private extern (C) void silentNotice(void*, const(char)*) nothrow
{
}

private string trimEol(string s) pure nothrow @safe
{
    while (s.length && (s[$ - 1] == '\n' || s[$ - 1] == '\r'))
        s = s[0 .. $ - 1];
    return s;
}

// ============================================================ pool

private final class Waiter
{
    int efd = -1;
    PgConn conn;     /// entregue direto por release()
    bool signaled;
}

/// Pool de conexões de UM worker (não é thread-safe de propósito: cada worker
/// tem o seu, veja `pgPool`).
final class PgPool
{
    private PgConfig cfg;
    private PgConn[] idle;
    private uint open;
    private Waiter[] waiters;

    this(PgConfig cfg)
    {
        assert(cfg.maxConns > 0, "vela.db: maxConns precisa ser > 0");
        this.cfg = cfg;
    }

    /// Conexões abertas (ociosas + emprestadas) e ociosas.
    uint openCount() const nothrow => open;
    size_t idleCount() const nothrow => idle.length;

    /// Pega uma conexão, abrindo outra se couber ou esperando uma livre.
    /// Devolva com `release` (ou use `lease`/`query`).
    PgConn acquire()
    {
        immutable deadline = MonoTime.currTime + cfg.acquireTimeout;
        for (;;)
        {
            while (idle.length)
            {
                auto c = idle[$ - 1];
                idle = idle[0 .. $ - 1];
                if (c.usable && MonoTime.currTime - c.lastUsed < cfg.idleTimeout)
                    return c;
                c.shutdown();
                open--;
            }
            if (open < cfg.maxConns)
            {
                open++;
                try
                    return PgConn.connect(cfg.conninfo, cfg.connectTimeout, cfg.queryTimeout, cfg.cacheStatements);
                catch (Throwable t)
                {
                    open--;
                    wakeOne(null); // alguém esperando pode tentar abrir a sua
                    throw t;
                }
            }

            // pool cheio: entra na fila e espera uma devolução
            auto w = new Waiter;
            w.efd = eventfd(0, 0x800 | 0x80000);
            if (w.efd < 0)
                throw new PgError("vela.db: eventfd falhou");
            waiters ~= w;
            bool served;
            scope (exit)
            {
                removeWaiter(w);
                close(w.efd);
                if (!served && w.signaled)
                {
                    // fomos acordados mas saímos antes de usar (prazo/cancelamento):
                    // repassa a conexão (ou a vaga) ao próximo da fila
                    if (w.conn !is null)
                        release(w.conn);
                    else
                        wakeOne(null);
                }
            }
            immutable left = deadline - MonoTime.currTime;
            if (left <= Duration.zero || awaitFd(w.efd, IoEvent.readable, left) == 0)
                throw new PgError("vela.db: pool de conexões esgotado (todas em uso por mais de "
                        ~ "acquireTimeout)");
            served = true;
            if (w.conn !is null)
                return w.conn;
            // acordado sem conexão: uma foi descartada; tenta de novo
        }
    }

    /// Devolve a conexão. Quebrada/fechada: é descartada e libera a vaga.
    void release(PgConn c) nothrow
    {
        if (c is null)
            return;
        if (!c.usable)
        {
            c.shutdown();
            open--;
            wakeOne(null);
            return;
        }
        if (wakeOne(c))
            return;
        idle ~= c;
    }

    /// Acorda o primeiro da fila, entregando `c` (pode ser null = "vaga livre").
    private bool wakeOne(PgConn c) nothrow
    {
        foreach (i, w; waiters)
        {
            if (w.signaled)
                continue;
            w.signaled = true;
            w.conn = c;
            ulong one = 1;
            write(w.efd, &one, one.sizeof);
            return true;
        }
        return false;
    }

    private void removeWaiter(Waiter w) nothrow
    {
        foreach (i, x; waiters)
            if (x is w)
            {
                waiters = waiters[0 .. i] ~ waiters[i + 1 .. $];
                return;
            }
    }

    /// Empresta uma conexão por escopo: devolvida sozinha ao sair.
    Lease lease() => Lease(this, acquire());

    /// Atalho: pega uma conexão, executa e devolve.
    PgResult query(Args...)(const(char)[] sql, Args args)
    {
        auto l = lease();
        return l.conn.query(sql, args);
    }

    void exec(Args...)(const(char)[] sql, Args args)
    {
        query(sql, args).close();
    }

    /// Roda `body` dentro de BEGIN/COMMIT na mesma conexão; ROLLBACK se lançar.
    T transaction(T)(T delegate(PgConn) body_)
    {
        auto l = lease();
        l.conn.exec("BEGIN");
        try
        {
            static if (is(T == void))
            {
                body_(l.conn);
                l.conn.exec("COMMIT");
            }
            else
            {
                auto r = body_(l.conn);
                l.conn.exec("COMMIT");
                return r;
            }
        }
        catch (Throwable t)
        {
            if (l.conn.usable)
            {
                try
                    l.conn.exec("ROLLBACK");
                catch (Throwable)
                    l.conn.shutdown();
            }
            throw t;
        }
    }

    /// Fecha todas as conexões ociosas.
    void closeAll() nothrow
    {
        foreach (c; idle)
        {
            c.shutdown();
            open--;
        }
        idle = null;
    }
}

/// Conexão emprestada; devolve ao pool no destrutor.
struct Lease
{
    private PgPool pool;
    PgConn conn;

    @disable this(this);

    private this(PgPool p, PgConn c) { pool = p; conn = c; }

    ~this()
    {
        if (pool !is null)
            pool.release(conn);
    }
}

private PgPool[string] tlsPools; // thread-local: um pool por worker

/// O pool deste worker para `conninfo` (criado no primeiro uso). Chame de
/// dentro dos handlers: cada thread/worker ganha o seu, sem locks.
PgPool pgPool(string conninfo, uint maxConns = 8)
{
    if (auto p = conninfo in tlsPools)
        return *p;
    PgConfig cfg;
    cfg.conninfo = conninfo;
    cfg.maxConns = maxConns;
    return tlsPools[conninfo] = new PgPool(cfg);
}

/// Idem, com configuração completa.
PgPool pgPool(PgConfig cfg)
{
    if (auto p = cfg.conninfo in tlsPools)
        return *p;
    return tlsPools[cfg.conninfo] = new PgPool(cfg);
}
