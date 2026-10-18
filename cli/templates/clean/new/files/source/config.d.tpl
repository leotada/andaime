/// The configuration: read from the environment once, in `main`, and read-only afterwards.
module config 2025;

@safe:
{{#pg}}

/// Where the repositories keep their data.
enum Store
{
    postgres, /// `DATABASE_URL` (the default)
    memory,   /// this process only, lost on exit: to try the app without a database (one worker)
}
{{/pg}}

struct Config
{
    ushort port = 8080;
{{#pg}}
    Store store = Store.postgres;
    string databaseUrl = "dbname={{appSnake}}";
{{/pg}}
}

{{#pg}}
/// Reads `PORT`, `STORE` (`postgres` or `memory`) and `DATABASE_URL` (a libpq conninfo or a postgresql:// URI).
{{/pg}}
{{^pg}}
/// Reads `PORT`.
{{/pg}}
Config loadConfig()
{
    Config c;
    c.port = toPort(env("PORT", "8080"));
{{#pg}}
    switch (env("STORE", "postgres"))
    {
        case "postgres":
            c.store = Store.postgres;
            break;
        case "memory":
            c.store = Store.memory;
            break;
        default:
            throw new Exception("STORE must be postgres or memory");
    }
    c.databaseUrl = env("DATABASE_URL", c.databaseUrl);
{{/pg}}
    return c;
}

private __gshared Config current; // written once by main before serving, then only read

/// The configuration. `@trusted`: `__gshared` data is `@system`, but `setConfig` writes it once before any worker exists
/// and everything afterwards reads it through this `const` view.
ref const(Config) config() @trusted => current;

/// The only writer: `main` calls it once, before serving (and tests, before they read it).
void setConfig(Config c) @system
{
    current = c;
}

/// The environment variable `name`, or `fallback` when it is not set.
private string env(const(char)* name, string fallback) @trusted
{
    import core.stdc.stdlib : getenv;
    import core.stdc.string : strlen;

    // sound: getenv returns a NUL-terminated string, copied here before anything can change the environment
    auto p = getenv(name);
    return p is null ? fallback : p[0 .. strlen(p)].idup;
}

private ushort toPort(string s)
{
    uint v;
    foreach (c; s)
    {
        if (c < '0' || c > '9' || v > 6553)
            throw new Exception("PORT must be a number from 1 to 65535, not '" ~ s ~ "'");
        v = v * 10 + (c - '0');
    }
    if (v == 0 || v > 65_535)
        throw new Exception("PORT must be a number from 1 to 65535, not '" ~ s ~ "'");
    return cast(ushort) v;
}
