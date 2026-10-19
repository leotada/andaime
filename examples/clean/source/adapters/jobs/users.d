/// The background jobs of users. Each one is a payload (what is stored) and a handler (an entry point, like a
/// controller) that hands the payload to a use case; `source/jobs.d` builds the handlers.
module adapters.jobs.users 2025;

@safe:

import andaime.values.optional : Optional;
import andaime.jobs;
import core.time; // the periods of @Every
import usecases.users;

/// The payload of SendWelcome: what is stored, nothing else.
@Job("default")
struct SendWelcomeJob
{
    long userId;
}

/// Runs SendWelcomeJob: an entry point, like a controller. It gets its use case from the jobs' composition root
/// (`buildJobs` in `source/jobs.d`) and hands it the payload.
final class SendWelcomeHandler
{
    private SendWelcome useCase;

    this(SendWelcome useCase)
    {
        this.useCase = useCase;
    }

    void perform(const SendWelcomeJob job, ref JobContext ctx) @safe
    {
        useCase.execute(job.userId);
    }
}

/// `SendWelcomeScheduler` over the job store: the job is a row in the same database. Inside a `PgUnitOfWork` the enqueue
/// joins its transaction (the outbox: stored and woken only if the work commits); a `MemoryUnitOfWork` that tracks the
/// store takes it back on a rollback.
final class QueuedSendWelcome : SendWelcomeScheduler
{
    private JobStore store;

    this(JobStore store)
    {
        this.store = store;
    }

    void schedule(long userId)
    {
        SendWelcomeJob job;
        job.userId = userId;
        enqueue(store, job);
    }
}
