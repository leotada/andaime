/// The default `offload` pool follows the CPUs the process may use (its affinity mask), not 4: a process pinned with
/// `taskset -c 0` gets 1 thread, `-c 0-3` gets 4, and `configureOffload` still wins. The startup line says the size.
/// The test starts itself as a child under `taskset`; it skips (exit 77) without `taskset` or with fewer than 4 CPUs.
module offload_affinity 2025;

version (linux):

import andaime;
import andaime.engine.offload : offloadThreads;
import andaime.engine.os : usableCpuCount;

import core.stdc.stdio : fflush, printf, stdout;
import core.sys.posix.signal : kill, SIGTERM;
import core.sys.posix.unistd : getpid;
import core.thread : Thread;
import core.time : msecs;
import std.file : thisExePath;
import std.process : execute;
import std.string : strip;

@system:

/// Child modes: `size` prints the pool size; `override` sets 3 threads first; `serve` runs a server that does not accept,
/// stops itself, and prints the usual startup lines.
int child(string mode)
{
    if (mode == "override")
        assert(configureOffload(3, 16));
    if (mode == "serve")
    {
        new Thread({
            Thread.sleep(300.msecs);
            kill(getpid(), SIGTERM);
        }).start();
        ServerConfig cfg;
        cfg.accept = false;
        cfg.workers = 1;
        return tryServe(() => new App, cfg) ? 0 : 1;
    }
    printf("%u\n", offloadThreads());
    fflush(stdout);
    return 0;
}

string run(string cpus, string mode)
{
    auto r = execute(["taskset", "-c", cpus, thisExePath, mode]);
    assert(r.status == 0, "child under taskset -c " ~ cpus ~ " (" ~ mode ~ "): " ~ r.output);
    return r.output;
}

int main(string[] args)
{
    if (args.length > 1)
        return child(args[1]);

    if (execute(["taskset", "--version"]).status != 0)
    {
        import core.stdc.stdio : fprintf, stderr;

        fprintf(stderr, "skip: taskset is not installed\n");
        return 77;
    }
    if (usableCpuCount() < 4)
    {
        import core.stdc.stdio : fprintf, stderr;

        fprintf(stderr, "skip: needs 4 CPUs in this process's affinity mask\n");
        return 77;
    }

    assert(run("0", "size").strip == "1", "pinned to one CPU: a pool of 1");
    assert(run("0-3", "size").strip == "4", "four CPUs: a pool of 4");
    assert(run("0,2", "size").strip == "2", "two CPUs, not adjacent: a pool of 2");
    assert(run("0", "override").strip == "3", "configureOffload wins over the affinity");
    printf("ok  offload: the default pool is the number of CPUs the process may use; configureOffload overrides it\n");

    auto banner = run("0", "serve");
    assert(banner.length > 0 && banner[$ - 1] == '\n');
    import std.algorithm : canFind;

    assert(banner.canFind("andaime: offload pool of 1 thread (queue 256)\n"), banner);
    assert(run("0-3", "serve").canFind("andaime: offload pool of 4 threads (queue 256)\n"));
    printf("ok  the startup log says the size of the offload pool\n");
    return 0;
}
