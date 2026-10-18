/// The jobs of users, run through a test store, with their use cases over in-memory adapters.
module tests.users_jobs;

@safe:

import andaime;
import andaime.jobs;
import adapters.jobs.provider : provided;
import adapters.jobs.users;
import adapters.memory.users : MemoryUserRepository;
import usecases.users;

unittest // SendWelcomeJob carries its payload and runs SendWelcome
{
    (() @trusted => provided!SendWelcome.provide(() => new SendWelcome(new MemoryUserRepository)))();
    auto store = new TestJobStore;
    SendWelcomeJob job;
    job.userId = 1;
    enqueue(store, job);
    store.assertEnqueued!SendWelcomeJob(`"userId":1`);
    store.drainJobs!SendWelcomeJob();
}
