/// Background jobs: the process roles, the job store, the jobs of the application and the use cases they call. `main`
/// calls `serveWithJobs` instead of `serve`.
module jobs;

@safe:

import andaime;
import andaime.jobs;
import andaime.jobs.pg : PgJobStore;
import std.meta : AliasSeq;
import app : buildApp, currentAdapters;
import config : config, Store;
import adapters.jobs.provider : provided;
import adapters.jobs.users : SendWelcomeJob;
import usecases.users : SendWelcome;
// andaime:imports

/// Every job of the application: the worker runs these.
alias AllJobs = AliasSeq!(
    SendWelcomeJob,
    // andaime:jobs
);

/// How each thread that runs jobs builds the use cases they call.
void provideUseCases() @system
{
    provided!SendWelcome.provide(() => new SendWelcome(currentAdapters().users));
    // andaime:provide
}

/// This thread's job store: Postgres, or an in-memory one with `STORE=memory`.
JobStore jobStore()
{
    static JobStore store; // thread-local: one per worker
    if (store is null)
    {
        if (config.store == Store.memory)
            store = new InMemoryJobStore;
        else
            store = new PgJobStore(config.databaseUrl);
    }
    return store;
}

/// `serve`, in the role given on the command line:
///
/// - `--role=api` (the default): HTTP only; handlers enqueue, another process runs the jobs.
/// - `--role=worker`: runs the jobs, no routes.
/// - `--role=all`: both in one process (the only choice with `STORE=memory`).
///
/// `--queues=default:5,mail:2` sets which queues this process runs and how many jobs of each at once.
void serveWithJobs(string[] args, ServerConfig cfg)
{
    auto startup = parseStartup(args);
    (() @trusted => provideUseCases())(); // sound: once, on the main thread, before any worker exists
    final switch (startup.role)
    {
        case ProcessRole.api:
            runApi(startup);
            serve(&buildApp, cfg);
            break;
        case ProcessRole.worker:
            runJobs!AllJobs(jobStore(), startup, cfg);
            break;
        case ProcessRole.all:
            applyJobGrace(cfg);
            serve(&buildApp, cfg, supervisorHook!AllJobs(jobStore(), startup));
            break;
    }
}
