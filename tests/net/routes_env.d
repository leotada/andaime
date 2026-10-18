/// `ANDAIME_ROUTES=1`: `tryServe` calls the build function once on the calling thread, prints `App.routeTable` to stdout
/// and returns true without opening a port (`andaime routes` relies on it). Serving would block until a signal, so
/// returning at all shows nothing was served.
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

void main()
{
    int[2] fds;
    assert(pipe(fds) == 0);
    immutable saved = dup(1);
    fflush(stdout);
    dup2(fds[1], 1);

    setenv("ANDAIME_ROUTES", "1", 1);
    ServerConfig cfg;
    cfg.port = 1; // a privileged port: binding it would fail, so success proves nothing was bound
    immutable ok = tryServe(&buildApp, cfg);
    unsetenv("ANDAIME_ROUTES");

    fflush(stdout);
    dup2(saved, 1);
    close(saved);
    close(fds[1]);
    char[4096] buf;
    immutable n = read(fds[0], buf.ptr, buf.length);
    close(fds[0]);
    auto printed = buf[0 .. n > 0 ? n : 0];

    assert(ok, "tryServe should return true after printing the routes");
    assert(builds == 1, "the build function runs exactly once");
    assert(builtOn is Thread.getThis(), "the build function runs on the calling thread");
    assert(printed == "GET     /health  routes_env.health\n", printed);

    import core.stdc.stdio : printf;
    printf("ok  ANDAIME_ROUTES prints the route table without serving\n");
}
