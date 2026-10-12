/// Tests of the Postgres driver against a real server (VELA_PG = conninfo).
/// Without VELA_PG the test declares itself skipped (exit 0 with a warning).
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
    return "no timeout";
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

// ------------------------------------------------------------ infrastructure

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
    assert(0, "server did not become ready");
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

/// Test-server connections as seen by Postgres itself.
int backends(PgConn c)
{
    return c.query("select count(*)::int from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid() and application_name = 'vela_test'")
        .get!int(0, 0);
}

// ------------------------------------------------------------ tests

void setup()
{
    // standalone connection, outside the loop (blocking fallbacks of awaitFd)
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
    assert(n == 1, "the same SQL should have become a single prepared statement");

    // ALTER TABLE invalidates the plan of "select *": the driver forgets the statement and retries
    assert(c.query("select * from t_pc").cols == 1);
    c.exec("alter table t_pc add column b int default 7");
    auto r = c.query("select * from t_pc");
    assert(r.cols == 2 && r.get!int(0, 1) == 7, "the old plan should be discarded and the query repeated");

    // went past 128 different SQLs: the extras run without cache, no error
    foreach (i; 0 .. 150)
    {
        auto q = "select $1::int + " ~ itoa(i);
        assert(c.query(q, 5).get!int(0, 0) == 5 + i, q);
    }
    assert(c.usable);
    c.exec("drop table t_pc");
    ok("prepared statements: cache, invalidation by ALTER TABLE, limit of 128");
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
    ok("queries, typed parameters, Maybe, error with SQLSTATE, transaction with rollback");
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
    assert(f.status == 200 && fastMs < 50, "the worker got stuck waiting for the database");
    foreach (fd; fds)
    {
        auto r = recv(fd);
        assert(r.status == 200 && r.body == "slept 42", r.body);
    }
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    printf("ok  %d queries of 300 ms with 50 connections in %ld ms on one thread (/fast meanwhile: %ld ms)\n", N, ms, fastMs);
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
    assert(ms >= 580 && ms < 1100, "6 queries of 200 ms on 2 connections should take ~600 ms");
    ok("pool with 2 connections: 6 queries wait their turn without stalling the worker");
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
    close(fd); // client goes away with the query in the air
    assert(waitFor(() => s.loop.stats().inFlight == 0, 500), "fiber was not cancelled");

    // the database server received the cancellation: no 5 s pg_sleep left hanging
    auto c = PgConn.connect(conninfo, 5.seconds, 5.seconds);
    scope (exit) c.shutdown();
    assert(waitFor(() => c.query("select count(*)::int from pg_stat_activity where query like '%pg_sleep%' and pid <> pg_backend_pid() and state = 'active'").get!int(0, 0) == 0, 1500),
        "the query kept running on the server");
    ok("client goes away midway through the query: fiber cancelled, server receives the cancellation");
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
    assert(ms < 1500, "the query deadline was not respected");
    r = fetch(s.port, "/user/1"); // the pool opens another connection
    assert(r.body == "ana|ana@x.com", r.body);
    ok("query deadline: PgTimeout, connection discarded, next request carries on normally");
}

void main()
{
    auto env = getenv("VELA_PG");
    if (env is null)
    {
        printf("skipped: set VELA_PG to the conninfo of a test Postgres\n");
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
    printf("all Postgres tests passed\n");
}

import core.stdc.string : strlen;
