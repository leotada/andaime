/// The jobs of users, run through a test store, with their use cases over in-memory adapters.
module tests.users_jobs 2025;

@safe:

import andaime;
import andaime.jobs;
import adapters.jobs.users;
import adapters.memory.users : MemoryUserRepository;
import usecases.users;

unittest // SendWelcomeJob carries its payload, and its handler runs SendWelcome
{
    auto handlers = new JobHandlers;
    handlers.handle!SendWelcomeJob(new SendWelcomeHandler(new SendWelcome(new MemoryUserRepository)));
    auto store = new TestJobStore;
    SendWelcomeJob job;
    job.userId = 1;
    enqueue(store, job);
    store.assertEnqueued!SendWelcomeJob(`"user_id":1`);
    store.drainJobs!SendWelcomeJob(handlers);
}
