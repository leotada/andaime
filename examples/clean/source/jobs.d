/// Background jobs: the process roles, the jobs of the application and the composition root of their handlers. `main`
/// calls `serveWithJobs` instead of `serve`.
module jobs 2025;

@safe:

import andaime;
import andaime.jobs;
import std.meta : AliasSeq;
import app : buildApp, currentAdapters;
import adapters.jobs.users : SendWelcomeJob, SendWelcomeHandler;
import usecases.users : SendWelcome;
// andaime:imports

/// Every job of the application: the worker runs these.
alias AllJobs = AliasSeq!(
    SendWelcomeJob,
    // andaime:jobs
);

/// The composition root of the jobs: each job's handler, over this thread's adapters. It runs once, on the thread that
/// runs the jobs, as `buildApp` does for the routes; a job of `AllJobs` without a handler stops the start.
JobHandlers buildJobs()
{
    auto handlers = new JobHandlers;
    handlers.handle!SendWelcomeJob(new SendWelcomeHandler(new SendWelcome(currentAdapters().users)));
    // andaime:handlers
    return handlers;
}

/// What the job runner needs from the application: the handlers.
WorkerHooks jobHooks()
{
    WorkerHooks hooks;
    hooks.handlers = () => buildJobs();
    return hooks;
}

/// This thread's job store: the one its adapters enqueue into (`Adapters.jobStore` in `app.d`). The runners call it on the
/// thread that runs the jobs.
JobStore jobStore() => currentAdapters().jobStore;

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
    final switch (startup.role)
    {
        case ProcessRole.api:
            runApi(startup);
            serve(&buildApp, cfg);
            break;
        case ProcessRole.worker:
            runJobs!AllJobs(() => jobStore(), startup, cfg, true, 0, jobHooks());
            break;
        case ProcessRole.all:
            applyJobGrace(cfg);
            serve(&buildApp, cfg, supervisorHook!AllJobs(() => jobStore(), startup, jobHooks()));
            break;
    }
}
