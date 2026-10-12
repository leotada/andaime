/// Testes do driver Postgres contra um servidor real (VELA_PG = conninfo).
/// Sem VELA_PG o teste se declara ignorado (exit 0 com aviso).
module pg_net;

version (linux):

import vela;
import vela.engine;
import vela.db;
import vela.server : handlerFactory;

import core.atomic : atomicLoad;
import core.stdc.stdio : printf, fflush, stdout;
import core.stdc.stdlib : getenv;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.socket;
import core.sys.posix.sys.time : timeval;
import core.sys.posix.unistd : close, read;
import core.thread : Thread;
import core.time;

__gshared string conninfo;
__gshared PgConfig cfg;

struct User { int id; string name; Maybe!string email; }

PgPool db() => pgPool(cfg);

// ------------------------------------------------------------ handlers

string fast() => "ok";

string user(int id)
{
    auto u = db.query("select id, name, email from t_users where id = $1", id).rowsAs!User;
    if (u.length == 0)
        return "none";
    return u[0].name ~ "|" ~ (u[0].email.has ? u[0].email.value : "-");
}

string wait(int ms)
{
    auto r = db.query("select pg_sleep($1::float8 / 1000)::text, $2::int + 1 as n", ms, 41);
    return "slept " ~ r.text(0, 1).idup;
}

string types()
{
    auto r = db.query("select $1::int8, $2::bool, $3::float8, $4::text, $5::text", long.min, true, 2.5, "a'b\"c", null);
    assert(r.get!long(0, 0) == long.min);
    assert(r.get!bool(0, 1));
    assert(r.get!double(0, 2) == 2.5);
    assert(r.get!string(0, 3) == "a'b\"c");
    assert(r.isNull(0, 4));
    assert(r.get!(Maybe!string)(0, 4).has == false);
    return "types ok";
}

string dup()
{
    try
        db.exec("insert into t_users(id, name) values (1, 'again')");
    catch (PgError e)
        return e.isUniqueViolation ? "unique " ~ e.sqlState : "other " ~ e.msg;
    return "no error";
}

string tx()
{
    try
        db.transaction((PgConn c) {
            c.exec("insert into t_users(id, name) values (100, 'tx')");
            throw new Exception("desfaz");
        });
    catch (Exception)
    {
    }
    auto n = db.query("select count(*)::int from t_users where id = 100").get!int(0, 0);
    db.transaction((PgConn c) { c.exec("insert into t_users(id, name) values (101, 'ok')"); });
    auto m = db.query("select count(*)::int from t_users where id = 101").get!int(0, 0);
    db.exec("delete from t_users where id = 101");
    return "rolled=" ~ (n == 0 ? "yes" : "no") ~ " committed=" ~ (m == 1 ? "yes" : "no");
}

string slowquery()
{
    try
        db.query("select pg_sleep(3)");
    catch (PgTimeout)
        return "timeout";
    return "sem timeout";
}

App buildApp()
{
    auto app = new App;
    app.get!("/fast", fast);
    app.get!("/user/{id}", user);
    app.get!("/wait/{ms}", wait);
    app.get!("/types", types);
    app.get!("/dup", dup);
    app.get!("/tx", tx);
    app.get!("/slowquery", slowquery);
    return app;
}

// ------------------------------------------------------------ infraestrutura

struct Server { EpollLoop loop; Thread thread; ushort port; }

Server start()
{
    ServerConfig sc;
    sc.port = 0;
    sc.workers = 1;
    sc.host = "127.0.0.1";
    sc.reusePort = false;
    auto loop = new EpollLoop;
    auto factory = handlerFactory(buildApp());
    auto t = new Thread({ loop.run(sc, factory); });
    t.start();
    foreach (_; 0 .. 400)
    {
        if (atomicLoad(loop.ready))
            return Server(loop, t, loop.boundPort);
        Thread.sleep(5.msecs);
    }
    assert(0, "servidor não ficou pronto");
}

void stop(ref Server s) { s.loop.stop(); s.thread.join(); }

ptrdiff_t rd(int fd, void* p, size_t n)
{
    import core.stdc.errno : errno, EINTR;
    for (;;)
    {
        auto r = read(fd, p, n);
        if (r >= 0 || errno != EINTR)
            return r;
    }
}

int dial(ushort port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    assert(connect(fd, cast(sockaddr*)&a, a.sizeof) == 0);
    timeval tv = timeval(10, 0);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tv.sizeof);
    return fd;
}

void send(int fd, string path)
{
    import core.sys.posix.sys.socket : send;
    auto s = "GET " ~ path ~ " HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n";
    send(fd, s.ptr, s.length, 0x4000);
}

struct Resp { int status; string body; }

Resp recv(int fd)
{
    import std.string : indexOf;
    import std.conv : to;
    string all;
    char[4096] tmp;
    for (;;)
    {
        auto n = rd(fd, tmp.ptr, tmp.length);
        if (n <= 0)
            break;
        all ~= tmp[0 .. n].idup;
    }
    close(fd);
    Resp r;
    if (all.length < 12)
        return r;
    r.status = all[9 .. 12].to!int;
    auto i = all.indexOf("\r\n\r\n");
    r.body = i < 0 ? "" : all[i + 4 .. $];
    return r;
}

Resp fetch(ushort port, string path)
{
    auto fd = dial(port);
    send(fd, path);
    return recv(fd);
}

bool waitFor(scope bool delegate() cond, int ms)
{
    foreach (_; 0 .. ms / 10)
    {
        if (cond())
            return true;
        Thread.sleep(10.msecs);
    }
    return cond();
}

void ok(string name) { printf("ok  %.*s\n", cast(int) name.length, name.ptr); fflush(stdout); }

/// Conexões do servidor de teste vistas pelo próprio Postgres.
int backends(PgConn c)
{
    return c.query("select count(*)::int from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid() and application_name = 'vela_test'")
        .get!int(0, 0);
}

// ------------------------------------------------------------ testes

void setup()
{
    // conexão avulsa, fora do loop (fallbacks bloqueantes do awaitFd)
    auto c = PgConn.connect(conninfo, 5.seconds, 10.seconds);
    scope (exit) c.shutdown();
    c.exec("drop table if exists t_users");
    c.exec("create table t_users(id int primary key, name text not null, email text)");
    c.exec("insert into t_users values (1, 'ana', 'ana@x.com'), (2, 'bia', null)");
}

void testPreparados()
{
    auto c = PgConn.connect(conninfo, 5.seconds, 10.seconds, true);
    scope (exit) c.shutdown();
    c.exec("drop table if exists t_pc");
    c.exec("create table t_pc(a int)");
    c.exec("insert into t_pc values (1), (2)");

    foreach (i; 0 .. 3)
        assert(c.query("select count(*)::int from t_pc where a >= $1", 1).get!int(0, 0) == 2);
    auto n = c.query("select count(*)::int from pg_prepared_statements where statement = $1", "select count(*)::int from t_pc where a >= $1").get!int(0, 0);
    assert(n == 1, "o mesmo SQL deveria ter virado um único statement preparado");

    // ALTER TABLE invalida o plano de "select *": o driver esquece o statement e repete
    assert(c.query("select * from t_pc").cols == 1);
    c.exec("alter table t_pc add column b int default 7");
    auto r = c.query("select * from t_pc");
    assert(r.cols == 2 && r.get!int(0, 1) == 7, "plano velho deveria ser descartado e a consulta repetida");

    // passou de 128 SQLs diferentes: os extras rodam sem cache, sem erro
    foreach (i; 0 .. 150)
    {
        auto q = "select $1::int + " ~ itoa(i);
        assert(c.query(q, 5).get!int(0, 0) == 5 + i, q);
    }
    assert(c.usable);
    c.exec("drop table t_pc");
    ok("statements preparados: cache, invalidação por ALTER TABLE, limite de 128");
}

string itoa(int v)
{
    char[16] t;
    size_t n = t.length;
    do { t[--n] = cast(char)('0' + v % 10); v /= 10; } while (v);
    return t[n .. $].idup;
}

void testBasico()
{
    auto s = start();
    scope (exit) stop(s);
    auto r = fetch(s.port, "/user/1");
    assert(r.status == 200 && r.body == "ana|ana@x.com", r.body);
    r = fetch(s.port, "/user/2");
    assert(r.status == 200 && r.body == "bia|-", r.body);
    r = fetch(s.port, "/user/9");
    assert(r.body == "none", r.body);
    r = fetch(s.port, "/types");
    assert(r.status == 200 && r.body == "types ok", r.body);
    r = fetch(s.port, "/dup");
    assert(r.body == "unique 23505", r.body);
    r = fetch(s.port, "/tx");
    assert(r.body == "rolled=yes committed=yes", r.body);
    ok("consultas, parâmetros tipados, Maybe, erro com SQLSTATE, transação com rollback");
}

void testNaoBloqueia()
{
    cfg.maxConns = 50;
    auto s = start();
    scope (exit) stop(s);

    enum N = 100;
    int[N] fds;
    immutable t0 = MonoTime.currTime;
    foreach (ref fd; fds)
    {
        fd = dial(s.port);
        send(fd, "/wait/300");
    }
    Thread.sleep(150.msecs);
    immutable t1 = MonoTime.currTime;
    auto f = fetch(s.port, "/fast");
    immutable fastMs = (MonoTime.currTime - t1).total!"msecs";
    assert(f.status == 200 && fastMs < 50, "o worker ficou preso esperando o banco");
    foreach (fd; fds)
    {
        auto r = recv(fd);
        assert(r.status == 200 && r.body == "slept 42", r.body);
    }
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    printf("ok  %d consultas de 300 ms com 50 conexões em %ld ms numa thread (/fast durante: %ld ms)\n", N, ms, fastMs);
    assert(ms < 1500);
}

void testPoolPequeno()
{
    cfg.maxConns = 2;
    auto s = start();
    scope (exit) stop(s);

    int[6] fds;
    immutable t0 = MonoTime.currTime;
    foreach (ref fd; fds)
    {
        fd = dial(s.port);
        send(fd, "/wait/200");
    }
    foreach (fd; fds)
    {
        auto r = recv(fd);
        assert(r.status == 200 && r.body == "slept 42", r.body);
    }
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(ms >= 580 && ms < 1100, "6 consultas de 200 ms em 2 conexões deveriam levar ~600 ms");
    ok("pool com 2 conexões: 6 consultas esperam a vez sem travar o worker");
}

void testCancelamento()
{
    cfg.maxConns = 4;
    auto s = start();
    scope (exit) stop(s);

    auto fd = dial(s.port);
    send(fd, "/wait/5000");
    assert(waitFor(() => s.loop.stats().inFlight == 1, 1000));
    Thread.sleep(100.msecs);
    close(fd); // cliente vai embora com a consulta no ar
    assert(waitFor(() => s.loop.stats().inFlight == 0, 500), "fiber não foi cancelado");

    // o servidor de banco recebeu o cancelamento: nada de pg_sleep de 5 s pendurado
    auto c = PgConn.connect(conninfo, 5.seconds, 5.seconds);
    scope (exit) c.shutdown();
    assert(waitFor(() => c.query("select count(*)::int from pg_stat_activity where query like '%pg_sleep%' and pid <> pg_backend_pid() and state = 'active'").get!int(0, 0) == 0, 1500),
        "a consulta continuou rodando no servidor");
    ok("cliente some no meio da consulta: fiber cancelado, servidor recebe o cancelamento");
}

void testPrazoDaConsulta()
{
    cfg.maxConns = 4;
    cfg.queryTimeout = 300.msecs;
    scope (exit) cfg.queryTimeout = 30.seconds;
    auto s = start();
    scope (exit) stop(s);
    immutable t0 = MonoTime.currTime;
    auto r = fetch(s.port, "/slowquery");
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(r.status == 200 && r.body == "timeout", r.body);
    assert(ms < 1500, "o prazo da consulta não foi respeitado");
    r = fetch(s.port, "/user/1"); // o pool abre outra conexão
    assert(r.body == "ana|ana@x.com", r.body);
    ok("prazo da consulta: PgTimeout, conexão descartada, próxima requisição segue normal");
}

void main()
{
    auto env = getenv("VELA_PG");
    if (env is null)
    {
        printf("pulado: defina VELA_PG com a conninfo de um Postgres de teste\n");
        return;
    }
    conninfo = cast(string) env[0 .. strlen(env)].idup;
    cfg.conninfo = conninfo ~ " application_name=vela_test";
    configureOffload(2, 64);
    setup();
    testPreparados();
    testBasico();
    testNaoBloqueia();
    testPoolPequeno();
    testCancelamento();
    testPrazoDaConsulta();
    printf("todos os testes do Postgres passaram\n");
}

import core.stdc.string : strlen;
