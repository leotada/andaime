/// vela-pg features against a real server (VELA_PG = conninfo): array parameters. Without VELA_PG the test declares itself
/// skipped (prints `skip: <reason>` and exits 77).
module pg_features;

version (linux):

import vela;
import vela.db;

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
        threw = e.msg == "vela.db: the query did not return the column 'author_nickname' expected by UserSummary";
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
        threw = e.msg == "vela.db: column '?column?' has the value 'onIssue', which is not Photo";
    assert(threw);
    threw = false;
    try
        c.query("select 1 as id, 'x' as mail").rowsAs!Person;
    catch (PgError e)
        threw = e.msg == "vela.db: the query did not return the column 'first_name' expected by Person";
    assert(threw);

    c.exec("drop table t_task");
    c.exec("drop type t_task_type");
    ok("names and enums: @naming and @column in rowsAs, enums by wire name as parameters (enum, text, array) and cells");
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
        threw = e.msg == "vela.db: savepoint needs an open transaction (use transaction)";
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

void main()
{
    auto env = getenv("VELA_PG");
    if (env is null)
    {
        import core.stdc.stdio : fprintf, stderr;
        import core.stdc.stdlib : exit;

        fprintf(stderr, "skip: set VELA_PG to the conninfo of a test Postgres\n");
        exit(77);
    }
    conninfo = cast(string) env[0 .. strlen(env)].idup;
    testArrays();
    testNestedRows();
    testNamesAndEnums();
    testSavepoints();
    testRollbackHarness();
    printf("all Postgres feature tests passed\n");
}
