/// @UniqueJob: one row per payload per window. A discarded row does not hold the window.
module unique;

@safe:

import core.time : minutes;
import vela.jobs;

final class Clock
{
    long us;
    long now() @safe nothrow
    {
        return us;
    }
}

@Job("default")
@UniqueJob(1.minutes)
struct Once
{
    string body;
    void perform(ref JobContext ctx)
    {
    }
}

@Job("other")
@UniqueJob(1.minutes)
struct Twice
{
    string body;
    void perform(ref JobContext ctx)
    {
    }
}

unittest
{
    auto clock = new Clock;
    auto store = new TestJobStore(&clock.now);
    Once job;
    job.body = "same";

    auto a = enqueue(store, job);
    auto b = enqueue(store, job, 1); // a different priority must not create a second row
    assert(a.inserted && !b.inserted && a.id == b.id);
    assert(store.jobs.length == 1);
    assert(store.jobs[0].priority == 100);
    assert(store.jobs[0].uniqueSlot == 0);
    assert(store.jobs[0].payload == `{"body":"same"}`);
    assert(store.jobs[0].uniqueKey == fnv1aHex(store.jobs[0].payload));
    assert(store.jobs[0].uniqueKey.length == 16);

    clock.us = 60_000_000 - 1;
    auto c = enqueue(store, job);
    assert(!c.inserted && c.id == a.id);
    assert(store.jobs.length == 1);

    clock.us = 60_000_000;
    auto d = enqueue(store, job);
    assert(d.inserted && d.id != a.id);
    assert(store.jobs.length == 2);
    assert(store.jobs[1].uniqueSlot == 60_000_000);

    job.body = "other";
    auto e = enqueue(store, job);
    assert(e.inserted && e.id != d.id);
    assert(store.jobs.length == 3);

    // Same JSON, different job name: the window is per job.
    Twice other;
    other.body = "other";
    auto f = enqueue(store, other);
    assert(f.inserted);
    assert(store.jobs.length == 4);
}

unittest
{
    // A discarded row leaves the window, so the same payload can be enqueued again.
    auto clock = new Clock;
    clock.us = 5_000;
    auto store = new TestJobStore(&clock.now);
    Once job;
    job.body = "same";
    auto a = enqueue(store, job);
    auto claimed = store.claimBatch("default", 1);
    assert(claimed.length == 1 && claimed[0].id == a.id);
    store.discard(a.id, "gone");
    auto b = enqueue(store, job);
    assert(b.inserted && b.id != a.id);
    assert(store.jobs.length == 2);
    assert(store.jobs[0].state == JobState.discarded);
    assert(store.jobs[1].state == JobState.available);
    assert(store.jobs[0].uniqueSlot == store.jobs[1].uniqueSlot);
}

unittest
{
    // A completed row still holds the window.
    auto clock = new Clock;
    auto store = new TestJobStore(&clock.now);
    Once job;
    job.body = "same";
    auto a = enqueue(store, job);
    store.drainJobs!Once();
    assert(store.jobs[0].state == JobState.completed);
    auto b = enqueue(store, job);
    assert(!b.inserted && b.id == a.id);
    assert(store.jobs.length == 1 && store.jobs[0].state == JobState.completed);
}

unittest
{
    // A running row holds the window too. The second enqueue does not change it.
    auto clock = new Clock;
    auto store = new TestJobStore(&clock.now);
    Once job;
    job.body = "same";
    auto a = enqueue(store, job);
    assert(store.claimBatch("default", 1).length == 1);
    auto b = enqueue(store, job);
    assert(!b.inserted && b.id == a.id);
    assert(store.jobs.length == 1 && store.jobs[0].state == JobState.running);
}

unittest
{
    // A key filled in before enqueue (what a Postgres insert does) dedups the same way.
    auto clock = new Clock;
    clock.us = 80_000;
    auto store = new TestJobStore(&clock.now);
    JobSpec spec;
    spec.queue = "default";
    spec.name = "pkg.Job";
    spec.payload = `{"n":1}`;
    spec.uniqueKey = fnv1aHex(spec.payload);
    spec.uniqueSlot = uniqueSlot(clock.us, 1.minutes);
    auto a = store.enqueue(spec);
    auto b = store.enqueue(spec);
    assert(a.inserted && !b.inserted && a.id == b.id);
    spec.uniqueSlot = uniqueSlot(clock.us + 60_000_000, 1.minutes);
    assert(store.enqueue(spec).inserted);
    assert(store.jobs.length == 2);
}
