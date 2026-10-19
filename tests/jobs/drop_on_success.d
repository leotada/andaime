/// `@Job(..., dropOnSuccess: true)`: a completed job leaves no payload in the memory store. A unique one keeps its row,
/// emptied, so its window still deduplicates. A failed one keeps its payload.
module drop_on_success 2025;

@safe:

import core.time : hours;
import andaime.jobs;

@Job("mail", dropOnSuccess: true)
struct MagicLink
{
    string token;
    void perform(ref JobContext) {}
}

@Job("mail", dropOnSuccess: true) @UniqueJob(1.hours)
struct Invite
{
    string token;
    void perform(ref JobContext) {}
}

@Job("mail", dropOnSuccess: true)
struct Broken
{
    string token;
    void perform(ref JobContext) { throw new Exception("smtp down"); }
}

@Job("mail")
struct Plain
{
    string token;
    void perform(ref JobContext) {}
}

unittest
{
    static assert(jobDropOnSuccess!MagicLink && !jobDropOnSuccess!Plain);

    auto store = new TestJobStore;
    enqueue(store, MagicLink("secret-1"));
    enqueue(store, Invite("secret-2"));
    enqueue(store, Broken("secret-3"));
    enqueue(store, Plain("kept"));
    store.drainJobs!(MagicLink, Invite, Broken, Plain)();

    string[] payloads;
    foreach (r; store.jobs())
        payloads ~= r.payload;
    assert(payloads == [`{}`, `{"token":"secret-3"}`, `{"token":"kept"}`], "only the failed and the plain job keep it");
    assert(!enqueue(store, Invite("secret-2")).inserted, "the emptied unique row still holds its window");
}
