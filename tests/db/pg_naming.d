/// The project's default naming (built with -version=AndaimeNamingSnakeCase): a struct with no attribute reads
/// snake_case columns with `rowsAs`, and `rowsAs!(T, Naming)` sets the policy for one call. Without ANDAIME_PG the test
/// prints `skip: ...` and exits 77.
module pg_naming 2025;

version (linux):

import andaime;
import andaime.db;

import core.stdc.stdio : fprintf, printf, stderr;
import core.stdc.stdlib : exit, getenv;
import core.stdc.string : strlen;
import core.time : seconds;

// a domain type: no andaime attribute
enum Plan { free, proYearly }
struct Company { long companyId; string displayName; Plan plan; }

void main()
{
    version (AndaimeNamingSnakeCase) {}
    else
    {
        // check.sh type-checks every test without flags; it runs this one with the version set
        fprintf(stderr, "skip: build tests/db/pg_naming.d with -version=AndaimeNamingSnakeCase\n");
        exit(77);
    }
    auto env = getenv("ANDAIME_PG");
    if (env is null)
    {
        fprintf(stderr, "skip: set ANDAIME_PG to the conninfo of a test Postgres\n");
        exit(77);
    }
    auto c = PgConn.connect(cast(string) env[0 .. strlen(env)].idup, 5.seconds, 10.seconds);
    scope (exit) c.shutdown();
    c.exec("create temp table companies(company_id bigint, display_name text, plan text)");
    c.exec("insert into companies values ($1, $2, $3)", 7L, "Acme", Plan.proYearly);
    assert(c.query("select plan from companies").get!string(0, 0) == "pro_yearly", "an enum parameter is snake_case too");

    auto rows = c.query("select company_id, display_name, plan from companies").rowsAs!Company;
    assert(rows == [Company(7, "Acme", Plan.proYearly)]);
    assert(c.query("select company_id, display_name, plan from companies").one!Company.displayName == "Acme");

    // the adapter picks the policy for one query
    auto camel = c.query(`select company_id as "companyId", display_name as "displayName", plan from companies`)
        .rowsAs!(Company, Naming.asIs);
    assert(camel[0].companyId == 7 && camel[0].plan == Plan.proYearly);
    assert(c.query(`select company_id as "companyId", display_name as "displayName", plan from companies`)
        .one!(Company, Naming.asIs).displayName == "Acme");
    printf("ok  rowsAs with the project's default naming and a per-call policy\n");
}
