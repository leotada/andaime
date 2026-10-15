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
    printf("all Postgres feature tests passed\n");
}
