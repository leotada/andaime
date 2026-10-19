/// `ANDAIME_ROUTES=1`: `tryServe` calls the build function once on the calling thread, prints `App.routeTable` to stdout
/// and returns true without opening a port (`andaime routes` relies on it). Serving would block until a signal, so
/// returning at all shows nothing was served. `ANDAIME_OPENAPI=1` does the same with the OpenAPI document (`andaime openapi`).
module routes_env 2025;

version (linux):

import andaime;
import andaime.engine : ServerConfig;

import core.stdc.stdio : fflush, stdout;
import core.sys.posix.stdlib : setenv, unsetenv;
import core.sys.posix.unistd : close, dup, dup2, pipe, read;
import core.thread : Thread;

int builds;
Thread builtOn;

string health() @safe => "ok";

App buildApp()
{
    builds++;
    builtOn = Thread.getThis();
    auto app = new App;
    app.get!("/health", health);
    return app;
}

/// Runs `tryServe` with `variable` set and returns what it wrote to stdout.
string capture(string variable, out bool ok)
{
    int[2] fds;
    assert(pipe(fds) == 0);
    immutable saved = dup(1);
    fflush(stdout);
    dup2(fds[1], 1);

    setenv(variable.ptr, "1", 1);
    ServerConfig cfg;
    cfg.port = 1; // a privileged port: binding it would fail, so success proves nothing was bound
    ok = tryServe(&buildApp, cfg);
    unsetenv(variable.ptr);

    fflush(stdout);
    dup2(saved, 1);
    close(saved);
    close(fds[1]);
    char[8192] buf;
    immutable n = read(fds[0], buf.ptr, buf.length);
    close(fds[0]);
    return buf[0 .. n > 0 ? n : 0].idup;
}

void main()
{
    bool ok;
    auto printed = capture("ANDAIME_ROUTES\0", ok);

    assert(ok, "tryServe should return true after printing the routes");
    assert(builds == 1, "the build function runs exactly once");
    assert(builtOn is Thread.getThis(), "the build function runs on the calling thread");
    assert(printed == "GET     /health  routes_env.health\n", printed);

    builds = 0;
    printed = capture("ANDAIME_OPENAPI\0", ok);
    assert(ok && builds == 1 && builtOn is Thread.getThis());
    assert(printed.length > 2 && printed[0 .. 2] == "{\n" && printed[$ - 2 .. $] == "}\n", printed);
    import std.algorithm : canFind;
    assert(printed.canFind(`"/health"`) && printed.canFind("\n  \"openapi\": \"3.0.3\","), printed);

    import core.stdc.stdio : printf;
    printf("ok  ANDAIME_ROUTES prints the route table, ANDAIME_OPENAPI the document, without serving\n");
}
