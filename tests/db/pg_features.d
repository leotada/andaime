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
    printf("all Postgres feature tests passed\n");
}
