/// andaime:pg features against a real server (ANDAIME_PG = conninfo): array parameters. Without ANDAIME_PG the test declares itself
/// skipped (prints `skip: <reason>` and exits 77).
module pg_features 2025;

version (linux):

import andaime;
import andaime.db;

import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;
import core.stdc.string : strlen;
import core.time;

__gshared string conninfo;

struct Uuid
{
    string text;

    static bool fromString(scope const(char)[] t, out Uuid v)
    {
        if (t.length != 36)
            return false;
        v.text = t.idup;
        return true;
    }

    void toString(scope void delegate(scope const(char)[]) @safe sink) const { sink(text); }
}

void ok(string what)
{
    printf("ok  %.*s\n", cast(int) what.length, what.ptr);
}

PgConn connect() => PgConn.connect(conninfo, 5.seconds, 10.seconds);

void testArrays()
{
    auto c = connect();
    scope (exit) c.shutdown();
    c.exec("drop table if exists t_arr");
    c.exec("create table t_arr(id uuid primary key, n int, label text)");
    c.exec("insert into t_arr values ('00000000-0000-0000-0000-000000000001', 1, 'a'),"
        ~ ` ('00000000-0000-0000-0000-000000000002', 2, 'b,c'), ('00000000-0000-0000-0000-000000000003', 3, 'd"e\f')`);

    // text types: = any($1::uuid[])
    auto ids = [Uuid("00000000-0000-0000-0000-000000000001"), Uuid("00000000-0000-0000-0000-000000000003")];
    auto r = c.query("select n from t_arr where id = any($1::uuid[]) order by n", ids);
    assert(r.rows == 2 && r.get!int(0, 0) == 1 && r.get!int(1, 0) == 3);

    // integers, and the empty array matches nothing
    assert(c.query("select count(*)::int from t_arr where n = any($1::int[])", [2, 3, 99]).get!int(0, 0) == 2);
    int[] none;
    assert(c.query("select count(*)::int from t_arr where n = any($1::int[])", none).get!int(0, 0) == 0);
    assert(c.query("select cardinality($1::int[])", none).get!int(0, 0) == 0);
    assert(c.query("select $1::bigint[]", [long.min, 0, long.max]).get!string(0, 0)
        == "{-9223372036854775808,0,9223372036854775807}");

    // strings: commas, quotes, backslashes, braces, spaces, the word NULL and empty strings stay data
    auto labels = ["b,c", `d"e\f`, "{x}", " sp ", "NULL", "", "çã"];
    r = c.query("select x from unnest($1::text[]) with ordinality as u(x, i) order by i", labels);
    assert(r.rows == cast(int) labels.length);
    foreach (i, l; labels)
        assert(r.get!string(cast(int) i, 0) == l, l);
    assert(c.query("select count(*)::int from t_arr where label = any($1::text[])", labels).get!int(0, 0) == 2);

    // Optional elements: empty is NULL; const arrays work
    auto opt = [Optional!int(1), Optional!int.init, Optional!int(3)];
    assert(c.query("select $1::int[]::text", opt).get!string(0, 0) == "{1,NULL,3}");
    const int[] fixed = [5, 6];
    assert(c.query("select $1::int[]::text", fixed).get!string(0, 0) == "{5,6}");
    bool[] flags = [true, false];
    assert(c.query("select $1::bool[]::text", flags).get!string(0, 0) == "{t,f}");

    c.exec("drop table t_arr");
    ok("array parameters: uuid[], int[], bigint[], text[] with special characters, empty, Optional elements, bool[]");
}

struct UserSummary { int id; string email; Optional!string nickname; }
struct Post { int id; string title; @prefix("author_") Optional!UserSummary author; }
struct Audit { string action; @prefix("by_") UserSummary by; @prefix("post_") Optional!PostRef post; }
struct PostRef { int id; @prefix("owner_") Optional!UserSummary owner; }

void testNestedRows()
{
    auto c = connect();
    scope (exit) c.shutdown();
    c.exec("drop table if exists t_posts");
    c.exec("drop table if exists t_people");
    c.exec("create table t_people(id int primary key, email text not null, nickname text)");
    c.exec("create table t_posts(id int primary key, title text not null, author_id int references t_people)");
    c.exec("insert into t_people values (1, 'ana@x.com', null), (2, 'bia@x.com', 'bia')");
    c.exec("insert into t_posts values (10, 'first', 1), (11, 'orphan', null), (12, 'third', 2)");

    // a LEFT JOIN: the author is there, or all its columns are NULL and the Optional is empty
    auto posts = c.query("select p.id, p.title, u.id as author_id, u.email as author_email, u.nickname as author_nickname"
        ~ " from t_posts p left join t_people u on u.id = p.author_id order by p.id").rowsAs!Post;
    assert(posts.length == 3);
    assert(posts[0].author.has && posts[0].author.get.email == "ana@x.com" && !posts[0].author.get.nickname.has);
    assert(!posts[1].author.has, "no author: every author_ column is NULL");
    assert(posts[2].author.get.nickname.get == "bia");

    // a missing column still throws, with the prefixed name
    bool threw;
    try
        c.query("select p.id, p.title, null::int as author_id, null::text as author_email from t_posts p").rowsAs!Post;
    catch (PgError e)
        threw = e.msg == "andaime.db: the query did not return the column 'author_nickname' expected by UserSummary";
    assert(threw);

    // a required (non-Optional) nested struct, and prefixes that compose (post_owner_...)
    auto a = c.query("select 'edit' as action, 2 as by_id, 'bia@x.com' as by_email, null::text as by_nickname,"
        ~ " 10 as post_id, 1 as post_owner_id, 'ana@x.com' as post_owner_email, 'a' as post_owner_nickname").one!Audit;
    assert(a.by.id == 2 && a.post.get.id == 10 && a.post.get.owner.get.email == "ana@x.com");
    a = c.query("select 'login' as action, 1 as by_id, 'ana@x.com' as by_email, null::text as by_nickname,"
        ~ " null::int as post_id, null::int as post_owner_id, null::text as post_owner_email,"
        ~ " null::text as post_owner_nickname").one!Audit;
    assert(!a.post.has);

    // a NULL in a required nested column is the usual error
    threw = false;
    try
        c.query("select 'x' as action, null::int as by_id, 'e' as by_email, null::text as by_nickname, null::int as post_id,"
            ~ " null::int as post_owner_id, null::text as post_owner_email, null::text as post_owner_nickname").one!Audit;
    catch (PgError e)
        threw = true;
    assert(threw);

    c.exec("drop table t_posts");
    c.exec("drop table t_people");
    ok("nested rows: @prefix on Optional and required structs, LEFT JOIN with no match, composed prefixes, missing column");
}

@naming(Naming.kebabCase) enum TaskType { task, taskInstance, workflowInstance }
enum Photo { none, @wireName("on_issue") onIssue }

@naming(Naming.snakeCase)
struct Person { int id; string firstName; @column("mail") string email; }

@naming(Naming.snakeCase)
struct Task
{
    int id;
    TaskType taskType;
    Optional!Photo photoRule;
    @prefix("assignee_") Optional!Person assignedTo;
}

void testNamesAndEnums()
{
    auto c = connect();
    scope (exit) c.shutdown();
    c.exec("drop table if exists t_task");
    c.exec("drop type if exists t_task_type");
    c.exec("create type t_task_type as enum ('task', 'task-instance', 'workflow-instance')");
    c.exec("create table t_task(id int primary key, task_type t_task_type not null, photo_rule text, assignee_id int)");

    // enum parameters go by wire name, into a Postgres enum and into text
    c.exec("insert into t_task values (1, $1::t_task_type, $2, null), (2, $3, null, 7)",
        TaskType.taskInstance, Photo.onIssue, TaskType.workflowInstance);
    assert(c.query("select task_type::text from t_task where id = 1").get!string(0, 0) == "task-instance");
    assert(c.query("select photo_rule from t_task where id = 1").get!string(0, 0) == "on_issue");
    assert(c.query("select count(*)::int from t_task where task_type = any($1::t_task_type[])",
        [TaskType.task, TaskType.workflowInstance]).get!int(0, 0) == 1, "an array of enums");

    // rows: snake_case columns, @column, @prefix before the nested struct's own names, enums by wire name
    auto tasks = c.query("select t.id, t.task_type, t.photo_rule, t.assignee_id, p.first_name as assignee_first_name,"
        ~ " p.mail as assignee_mail from t_task t left join (values (7, 'Ana', 'a@x.com')) as p(id, first_name, mail)"
        ~ " on p.id = t.assignee_id order by t.id").rowsAs!Task;
    assert(tasks.length == 2);
    assert(tasks[0].taskType == TaskType.taskInstance && tasks[0].photoRule.get == Photo.onIssue);
    assert(!tasks[0].assignedTo.has);
    assert(tasks[1].taskType == TaskType.workflowInstance && !tasks[1].photoRule.has);
    assert(tasks[1].assignedTo.get.id == 7 && tasks[1].assignedTo.get.firstName == "Ana"
        && tasks[1].assignedTo.get.email == "a@x.com");
    assert(c.query("select 'on_issue'").get!Photo(0, 0) == Photo.onIssue);

    // a label that is no wire name, and a missing column named by its snake_case spelling
    bool threw;
    try
        c.query("select 'onIssue'").get!Photo(0, 0);
    catch (PgError e)
        threw = e.msg == "andaime.db: column '?column?' has the value 'onIssue', which is not Photo";
    assert(threw);
    threw = false;
    try
        c.query("select 1 as id, 'x' as mail").rowsAs!Person;
    catch (PgError e)
        threw = e.msg == "andaime.db: the query did not return the column 'first_name' expected by Person";
    assert(threw);

    c.exec("drop table t_task");
    c.exec("drop type t_task_type");
    ok("names and enums: @naming and @column in rowsAs, enums by wire name as parameters (enum, text, array) and cells");
}

struct TagRef { int id; string name; }

@naming(Naming.snakeCase)
struct TaskWithTags
{
    int id;
    Uuid[] tagIds;
    Json!(TagRef[]) tags;
    Optional!(Json!JsonValue) meta;
}

void testReadArraysAndJson()
{
    auto c = connect();
    scope (exit) c.shutdown();

    // arrays of every element kind, quoting included
    assert(c.query("select '{1,-2,3}'::int[]").get!(int[])(0, 0) == [1, -2, 3]);
    assert(c.query("select '{}'::int[]").get!(int[])(0, 0).length == 0);
    auto labels = ["b,c", `d"e\f`, "{x}", " sp ", "NULL", "", "çã"];
    assert(c.query("select $1::text[]", labels).get!(string[])(0, 0) == labels, "a text[] round trip");
    assert(c.query("select '{t,f}'::bool[]").get!(bool[])(0, 0) == [true, false]);
    assert(c.query("select '{1.5,-2.25}'::float8[]").get!(double[])(0, 0) == [1.5, -2.25]);
    auto ids = c.query("select array['00000000-0000-0000-0000-000000000001'::uuid, '00000000-0000-0000-0000-000000000002']")
        .get!(Uuid[])(0, 0);
    assert(ids.length == 2 && ids[1].text == "00000000-0000-0000-0000-000000000002");
    assert(c.query("select '{1,NULL,3}'::int[]").get!(Optional!int[])(0, 0) == [Optional!int(1), Optional!int.init,
        Optional!int(3)]);
    assert(c.query("select $1::text[]", [Photo.onIssue, Photo.none]).get!(Photo[])(0, 0) == [Photo.onIssue, Photo.none]);
    assert(!c.query("select null::int[]").get!(Optional!(int[]))(0, 0).has);

    // what an array of a type cannot hold
    bool threw;
    try
        c.query("select '{1,NULL}'::int[]").get!(int[])(0, 0);
    catch (PgError e)
        threw = e.msg == "andaime.db: column 'int4' has a NULL element; use Optional!(int)[] in the field";
    assert(threw);
    threw = false;
    try
        c.query("select '{{1,2},{3,4}}'::int[]").get!(int[])(0, 0);
    catch (PgError e)
        threw = e.msg == "andaime.db: column 'int4' is a multidimensional array; read it as string";
    assert(threw);
    threw = false;
    try
        c.query("select '[0:1]={1,2}'::int[]").get!(int[])(0, 0);
    catch (PgError e)
        threw = true;
    assert(threw, "explicit bounds");

    // one query with array_agg and json_agg instead of one query per relation
    c.exec("drop table if exists t_tag_link");
    c.exec("drop table if exists t_tag");
    c.exec("create table t_tag(id int primary key, uid uuid not null, name text not null)");
    c.exec("create table t_tag_link(task_id int, tag_id int references t_tag)");
    c.exec("insert into t_tag values (1, '00000000-0000-0000-0000-00000000000a', 'red'), (2, '00000000-0000-0000-0000-00000000000b', 'blue')");
    c.exec("insert into t_tag_link values (10, 1), (10, 2)");
    auto rows = c.query("select x.id,"
        ~ " coalesce(array_agg(g.uid order by g.id) filter (where g.id is not null), '{}') as tag_ids,"
        ~ " coalesce(json_agg(json_build_object('id', g.id, 'name', g.name) order by g.id) filter (where g.id is not null), '[]') as tags,"
        ~ " case when x.id = 10 then '{\"pinned\":true}'::jsonb end as meta"
        ~ " from (values (10), (11)) as x(id) left join t_tag_link l on l.task_id = x.id left join t_tag g on g.id = l.tag_id"
        ~ " group by x.id order by x.id").rowsAs!TaskWithTags;
    assert(rows.length == 2);
    assert(rows[0].tagIds.length == 2 && rows[0].tagIds[0].text == "00000000-0000-0000-0000-00000000000a");
    assert(rows[0].tags.length == 2 && rows[0].tags[1].name == "blue");
    assert(rows[0].meta.get["pinned"].asBool);
    assert(rows[1].tagIds.length == 0 && rows[1].tags.length == 0 && !rows[1].meta.has);

    // a row goes back out as plain JSON, and Json!T is also a parameter
    assert(toJson(rows[0]) == `{"id":10,"tag_ids":["00000000-0000-0000-0000-00000000000a","00000000-0000-0000-0000-00000000000b"],`
        ~ `"tags":[{"id":1,"name":"red"},{"id":2,"name":"blue"}],"meta":{"pinned":true}}`, toJson(rows[0]));
    assert(c.query("select ($1::jsonb) -> 1 ->> 'name'", rows[0].tags).get!string(0, 0) == "blue");

    // a column that is not JSON for T
    threw = false;
    try
        c.query(`select '[{"id":"x"}]'::json`).get!(Json!(TagRef[]))(0, 0);
    catch (PgError e)
        threw = true;
    assert(threw);

    c.exec("drop table t_tag_link");
    c.exec("drop table t_tag");
    ok("reading arrays (int, text, bool, float, uuid, enum, NULL elements) and json/jsonb into Json!T; array_agg + json_agg rows");
}

void testQueryHook()
{
    QueryEvent[] seen;
    PgConfig cfg;
    cfg.conninfo = conninfo;
    cfg.onQuery = (ref const QueryEvent e) @safe {
        QueryEvent copy = e;
        copy.sql = e.sql.idup;
        seen ~= copy;
    };
    auto pool = new PgPool(cfg);
    scope (exit) pool.closeAll();

    assert(pool.query("select generate_series(1, $1)", 3).rows == 3);
    assert(seen.length == 1 && seen[0].sql == "select generate_series(1, $1)" && seen[0].rows == 3 && seen[0].error is null
        && !seen[0].internal && seen[0].duration >= Duration.zero);

    // a failure is reported with its message and SQLSTATE, then thrown as usual
    seen = null;
    bool threw;
    try
        pool.exec("select 1/0");
    catch (PgError e)
        threw = e.sqlState == "22012";
    assert(threw && seen.length == 1 && seen[0].rows == -1 && seen[0].sqlState == "22012" && seen[0].error.length);

    // transactions: andaime's own statements are marked internal
    seen = null;
    pool.transaction((PgConn x) { x.exec("select 1"); });
    string[] kinds;
    foreach (e; seen)
        kinds ~= (e.internal ? "internal " : "") ~ e.sql.idup;
    assert(kinds == ["internal BEGIN", "select 1", "internal COMMIT"], kinds[0]);

    // the test harness: only the app's statements, not its BEGIN and ROLLBACK
    seen = null;
    pool.rollbackAfter(() @safe { pool.exec("select 2"); pool.exec("select 3"); });
    assert(seen.length == 2 && seen[0].sql == "select 2" && seen[1].sql == "select 3");
    ok("onQuery: SQL, rows, duration, errors with SQLSTATE, internal BEGIN/COMMIT, rollbackAfter counts only the app");
}

int count(PgConn c) => c.query("select count(*)::int from t_sp").get!int(0, 0);

void testSavepoints()
{
    auto c = connect();
    scope (exit) c.shutdown();
    c.exec("drop table if exists t_sp");
    c.exec("create table t_sp(n int unique)");
    assert(!c.inTransaction);

    // a savepoint needs a transaction
    bool threw;
    try
        c.savepoint((PgConn x) { });
    catch (PgError e)
        threw = e.msg == "andaime.db: savepoint needs an open transaction (use transaction)";
    assert(threw);

    // inside a transaction: a failed savepoint rolls back only its own work, the rest commits
    c.transaction((PgConn x) {
        assert(x.inTransaction);
        x.exec("insert into t_sp values (1)");
        try
            x.savepoint((PgConn y) {
                y.exec("insert into t_sp values (2)");
                y.exec("insert into t_sp values (1)"); // unique violation: the transaction would be aborted without it
            });
        catch (PgError e)
            assert(e.isUniqueViolation);
        x.savepoint((PgConn y) { y.exec("insert into t_sp values (3)"); });
        // nested savepoints, and transaction() inside a transaction is a savepoint too
        x.transaction((PgConn y) {
            y.exec("insert into t_sp values (4)");
            try
                y.savepoint((PgConn z) {
                    z.exec("insert into t_sp values (5)");
                    throw new Exception("undo 5");
                });
            catch (Exception) {}
        });
    });
    assert(!c.inTransaction);
    assert(c.query("select string_agg(n::text, ',' order by n) from t_sp").get!string(0, 0) == "1,3,4");

    // the result of the body comes back
    assert(c.transaction((PgConn x) => x.savepoint((PgConn y) => y.query("select 7").get!int(0, 0))) == 7);

    // read only: reads work, a write fails with 25006 and rolls back; nested, it is a savepoint of the outer mode
    assert(c.transaction((PgConn x) => x.query("select current_setting('transaction_read_only')").get!string(0, 0),
        TxMode.readOnly) == "on");
    threw = false;
    try
        c.transaction((PgConn x) { x.exec("insert into t_sp values (99)"); }, TxMode.readOnly);
    catch (PgError e)
        threw = e.sqlState == "25006";
    assert(threw && !c.inTransaction && count(c) == 3);
    c.transaction((PgConn x) {
        x.transaction((PgConn y) { y.exec("insert into t_sp values (98)"); }, TxMode.readOnly);
    });
    assert(count(c) == 4, "a nested read-only block keeps the outer read-write mode");
    c.exec("delete from t_sp");
    ok("savepoints: SAVEPOINT/RELEASE/ROLLBACK TO, nesting, transaction() inside a transaction, return values");
}

void testRollbackHarness()
{
    PgConfig cfg;
    cfg.conninfo = conninfo;
    auto pool = new PgPool(cfg);

    // the code under test commits through the pool; the harness rolls everything back
    pool.rollbackAfter(() @safe {
        pool.exec("insert into t_sp values (10)");
        pool.transaction((PgConn x) { x.exec("insert into t_sp values (11)"); });
        try
            pool.transaction((PgConn x) {
                x.exec("insert into t_sp values (12)");
                throw new Exception("the app's own rollback");
            });
        catch (Exception) {}
        assert(pool.query("select string_agg(n::text, ',' order by n) from t_sp").get!string(0, 0) == "10,11",
            "inside the harness, the app sees its own writes");
        assert(pool.openCount == 0, "the pinned connection is not one of the pool's");
    });
    auto c = connect();
    scope (exit) c.shutdown();
    assert(count(c) == 0, "everything was rolled back");

    // after unpinning, the pool hands out its own connections again
    pool.exec("insert into t_sp values (20)");
    assert(count(c) == 1 && pool.openCount == 1);
    c.exec("drop table t_sp");
    pool.closeAll();
    ok("test harness: rollbackAfter pins one connection, app transactions become savepoints, nothing survives");
}

/// Three idle pooled connections are closed by the server (as a restart or a failover does); the next queries still work.
void testStaleConnections()
{
    import core.thread : Thread;

    int[] openThree(PgPool pool)
    {
        auto a = pool.lease(), b = pool.lease(), c = pool.lease();
        int[] pids;
        foreach (conn; [a.conn, b.conn, c.conn])
            pids ~= conn.query("select pg_backend_pid()").get!int(0, 0);
        return pids;
    }

    void terminate(int[] pids)
    {
        auto admin = connect();
        scope (exit) admin.shutdown();
        foreach (pid; pids)
            admin.exec("select pg_terminate_backend($1)", pid);
        Thread.sleep(100.msecs); // the FATAL and the close reach the idle sockets
    }

    PgConfig cfg;
    cfg.conninfo = conninfo;
    cfg.pingAfter = 50.msecs;
    auto pool = new PgPool(cfg);
    auto pids = openThree(pool);
    assert(pool.idleCount == 3);
    terminate(pids);
    foreach (_; 0 .. 3)
        assert(pool.query("select 1").get!int(0, 0) == 1, "a stale pooled connection reached the caller");
    assert(pool.openCount == 1, "the three dead connections were dropped and one new one opened");
    pool.closeAll();

    // without the check (idle for less than pingAfter), the first statement on a dead connection fails
    cfg.pingAfter = 1.hours;
    auto unchecked = new PgPool(cfg);
    terminate(openThree(unchecked));
    bool failed;
    try
        unchecked.query("select 1");
    catch (PgError)
        failed = true;
    assert(failed, "the test did not close the connections");
    unchecked.closeAll();
    ok("pool: idle connections the server closed are dropped before use (pingAfter)");
}

/// andaime's `Uuid` (a text type) as a `uuid` column: a parameter, and back through `rowsAs`.
void testLibraryUuid()
{
    import andaime.values.uuid : LibUuid = Uuid;

    struct Row { LibUuid id; string name; }
    auto c = connect();
    scope (exit) c.shutdown();
    c.exec("create temp table t_uuid(id uuid primary key, name text)");
    auto id = uuid7();
    c.exec("insert into t_uuid values ($1, $2)", id, "ana");
    auto rows = c.query("select id, name from t_uuid where id = $1", id).rowsAs!Row;
    assert(rows.length == 1 && rows[0].id == id && rows[0].name == "ana");
    assert(c.query("select id::text from t_uuid").get!string(0, 0) == id.toString);
    ok("Uuid: a uuid column through parameters and rowsAs");
}

int rowsIn(PgConn c, string table) => c.query("select count(*)::int from " ~ table).get!int(0, 0);

/// The ambient transaction, on the calling thread (no fiber: the thread's table): code that only holds the pool joins it.
void testAmbient()
{
    auto admin = connect();
    scope (exit) admin.shutdown();
    admin.exec("drop table if exists t_orders");
    admin.exec("drop table if exists t_lines");
    admin.exec("create table t_orders(id int primary key)");
    admin.exec("create table t_lines(order_id int, n int)");
    scope (exit)
    {
        admin.exec("drop table t_orders");
        admin.exec("drop table t_lines");
    }

    PgConfig cfg;
    cfg.conninfo = conninfo;
    auto pool = new PgPool(cfg);
    // two "repositories" that only know the pool
    void addOrder(int id) { pool.exec("insert into t_orders values ($1)", id); }
    void addLine(int id, int n) { pool.exec("insert into t_lines values ($1, $2)", id, n); }

    // one connection for every statement of the transaction
    assert(!pool.inTransaction);
    pool.transaction((PgConn tx) {
        assert(pool.inTransaction);
        immutable pid = tx.query("select pg_backend_pid()").get!int(0, 0);
        assert(pool.query("select pg_backend_pid()").get!int(0, 0) == pid);
        auto l = pool.lease();
        assert(l.conn is tx);
        addOrder(1);
        addLine(1, 10);
        assert(pool.openCount == 1);
    });
    assert(!pool.inTransaction && rowsIn(admin, "t_orders") == 1 && rowsIn(admin, "t_lines") == 1);

    // a failure rolls back both tables
    try
        pool.transaction((PgConn _) {
            addOrder(2);
            addLine(2, 20);
            throw new Exception("rule broken");
        });
    catch (Exception) {}
    assert(rowsIn(admin, "t_orders") == 1 && rowsIn(admin, "t_lines") == 1, "both writes were rolled back");

    // a nested transaction is a savepoint: its failure keeps the outer work
    pool.transaction((PgConn _) {
        addOrder(3);
        try
            pool.transaction((PgConn __) {
                addLine(3, 30);
                throw new Exception("inner");
            });
        catch (Exception) {}
        addLine(3, 31);
    });
    assert(admin.query("select string_agg(n::text, ',') from t_lines where order_id = 3").get!string(0, 0) == "31");

    // afterCommit: after the outermost commit, in order; never after a rollback; a failed savepoint drops its own
    string[] ran;
    pool.transaction((PgConn _) {
        pool.afterCommit(() { ran ~= "a"; });
        pool.transaction((PgConn __) { pool.afterCommit(() { ran ~= "b"; }); });
        try
            pool.transaction((PgConn __) {
                pool.afterCommit(() { ran ~= "dropped"; });
                throw new Exception("inner");
            });
        catch (Exception) {}
        assert(ran.length == 0, "nothing runs before the commit");
    });
    assert(ran == ["a", "b"], "after the commit, in order");
    ran = null;
    try
        pool.transaction((PgConn _) {
            pool.afterCommit(() { ran ~= "never"; });
            throw new Exception("rollback");
        });
    catch (Exception) {}
    assert(ran.length == 0);
    pool.afterCommit(() { ran ~= "now"; });
    assert(ran == ["now"], "outside a transaction it runs at once");

    // a failing callback is reported, does not undo the commit, and the others still run
    Exception reported;
    PgConfig cfg2 = cfg;
    cfg2.onCallbackError = (Exception e) nothrow { reported = e; };
    auto pool2 = new PgPool(cfg2);
    ran = null;
    pool2.transaction((PgConn _) {
        pool2.exec("insert into t_orders values (4)");
        pool2.afterCommit(() { throw new Exception("mail server down"); });
        pool2.afterCommit(() { ran ~= "second"; });
    });
    assert(reported !is null && reported.msg == "mail server down" && ran == ["second"]);
    assert(admin.query("select count(*)::int from t_orders where id = 4").get!int(0, 0) == 1);
    // the callbacks run once the connection is back: they can use the pool
    pool2.transaction((PgConn _) {
        pool2.afterCommit(() { assert(!pool2.inTransaction && pool2.query("select 1").get!int(0, 0) == 1); });
    });

    // inside rollbackAfter, the app's outermost transaction is a savepoint; its callbacks run when it ends
    ran = null;
    pool.rollbackAfter(() {
        pool.transaction((PgConn _) {
            addOrder(5);
            addLine(5, 50);
            pool.afterCommit(() { ran ~= "harness"; });
        });
        assert(ran == ["harness"]);
        assert(pool.query("select count(*)::int from t_orders where id = 5").get!int(0, 0) == 1);
    });
    assert(admin.query("select count(*)::int from t_orders where id = 5").get!int(0, 0) == 0, "the harness rolled back");

    // requireTransaction: no autocommit statement on the pool
    PgConfig strict = cfg;
    strict.requireTransaction = true;
    auto pool3 = new PgPool(strict);
    bool refused;
    try
        pool3.exec("insert into t_orders values (6)");
    catch (PgError e)
        refused = e.msg == "andaime.db: requireTransaction is set; run this statement inside pool.transaction";
    assert(refused);
    pool3.transaction((PgConn _) { pool3.exec("insert into t_orders values (6)"); });
    assert(admin.query("select count(*)::int from t_orders where id = 6").get!int(0, 0) == 1);

    pool.closeAll();
    pool2.closeAll();
    pool3.closeAll();
    ok("ambient transaction: the pool's statements join it, rollback undoes both tables, savepoints, afterCommit, "
        ~ "rollbackAfter, requireTransaction");
}

shared int fibersDone, fiberFailures, offloadAsserted;
int fibersInserted, fibersRead; // the worker thread's: both fibers run on it

/// Two fibers of one worker, each in its own transaction, interleaving at every wait; offload does not see either.
void ambientFibers() @system
{
    import core.atomic : atomicOp;
    import core.exception : AssertError;

    auto pool = pgPool(conninfo);
    void one(int id)
    {
        try
        {
            static void offloadQuery(PgPool pool) @trusted // catches the AssertError offload carries back
            {
                try
                    offload(() @safe => pool.query("select 1").get!int(0, 0));
                catch (AssertError e)
                    atomicOp!"+="(offloadAsserted, 1);
            }
            pool.transaction((PgConn tx) @safe {
                pool.exec("insert into t_fibers values ($1)", id);
                // both fibers are inside their transaction, with their row inserted, before either reads or commits
                fibersInserted++;
                while (fibersInserted < 2)
                    sleep(5.msecs);
                auto seen = pool.query("select string_agg(n::text, ',') from t_fibers").get!string(0, 0);
                fibersRead++;
                while (fibersRead < 2)
                    sleep(5.msecs);
                if (seen != (id == 1 ? "1" : "2"))
                    atomicOp!"+="(fiberFailures, 1); // saw the other fiber's uncommitted row
                if (id == 1)
                    offloadQuery(pool);
            });
        }
        catch (Throwable t)
            atomicOp!"+="(fiberFailures, 1);
        atomicOp!"+="(fibersDone, 1);
    }
    spawn(() @trusted { one(1); });
    spawn(() @trusted { one(2); });
}

void testAmbientFibers() @system
{
    import core.atomic : atomicLoad;
    import core.sys.posix.signal : kill, SIGTERM;
    import core.sys.posix.unistd : getpid;
    import core.thread : Thread;

    auto admin = connect();
    scope (exit) admin.shutdown();
    admin.exec("drop table if exists t_fibers");
    admin.exec("create table t_fibers(n int)");
    scope (exit) admin.exec("drop table t_fibers");

    ServerConfig cfg;
    cfg.accept = false;
    cfg.workers = 1;
    App delegate() @system build = () => new App;
    auto t = new Thread({ tryServe(build, cfg, () @trusted { ambientFibers(); }); });
    t.start();
    foreach (_; 0 .. 400)
    {
        if (atomicLoad(fibersDone) == 2)
            break;
        Thread.sleep(10.msecs);
    }
    kill(getpid(), SIGTERM);
    t.join();
    assert(atomicLoad(fibersDone) == 2 && atomicLoad(fiberFailures) == 0, "the fibers' transactions mixed");
    version (assert)
        assert(atomicLoad(offloadAsserted) == 1, "a pooled query inside offload during a transaction should assert");
    assert(rowsIn(admin, "t_fibers") == 2);
    ok("ambient transaction: two fibers keep their own; offload inside one asserts");
}

void main()
{
    auto env = getenv("ANDAIME_PG");
    if (env is null)
    {
        import core.stdc.stdio : fprintf, stderr;
        import core.stdc.stdlib : exit;

        fprintf(stderr, "skip: set ANDAIME_PG to the conninfo of a test Postgres\n");
        exit(77);
    }
    conninfo = cast(string) env[0 .. strlen(env)].idup;
    testArrays();
    testNestedRows();
    testNamesAndEnums();
    testReadArraysAndJson();
    testQueryHook();
    testSavepoints();
    testRollbackHarness();
    testStaleConnections();
    testLibraryUuid();
    testAmbient();
    testAmbientFibers();
    printf("all Postgres feature tests passed\n");
}
