/// Claim order: priority ascending, then runAt, then id. A future runAt stays scheduled.
module queue_order;

@safe:

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
struct Task
{
    string label;
    void perform(ref JobContext ctx)
    {
    }
}

@Job("critical")
struct Urgent
{
    string label;
    void perform(ref JobContext ctx)
    {
    }
}

private string[] payloads(JobRecord[] rows)
{
    string[] p;
    foreach (r; rows)
        p ~= r.payload;
    return p;
}

unittest
{
    auto clock = new Clock;
    clock.us = 1_000_000;
    auto store = new TestJobStore(&clock.now);

    Task p100;
    p100.label = "p100";
    Task later;
    later.label = "later";
    Task p50;
    p50.label = "p50";
    Task p50b;
    p50b.label = "p50b";
    Task low;
    low.label = "low";
    Urgent hot;
    hot.label = "hot";

    assert(enqueue(store, p100).inserted);
    assert(enqueueAt(store, later, clock.us + 5_000_000, 50).inserted);
    assert(enqueue(store, p50, 50).inserted);
    assert(enqueue(store, p50b, 50).inserted);
    assert(enqueueAt(store, low, clock.us - 1, 200).inserted);
    assert(enqueue(store, hot, 10).inserted);

    auto rows = store.jobs;
    assert(rows[0].state == JobState.available && rows[0].priority == 100);
    assert(rows[1].state == JobState.scheduled && rows[1].runAtUs == clock.us + 5_000_000);
    assert(rows[4].state == JobState.available); // runAt in the past is due, not scheduled
    assert(rows[5].queue == "critical");

    // Best two of the default queue. The critical job is a better priority but a different queue.
    auto first = store.claimBatch("default", 2);
    assert(payloads(first) == [`{"label":"p50"}`, `{"label":"p50b"}`], payloads(first)[0]);
    assert(first[0].attempt == 1 && first[0].state == JobState.running);
    assert(first[0].id < first[1].id);

    auto rest = store.claimBatch("default", 10);
    assert(payloads(rest) == [`{"label":"p100"}`, `{"label":"low"}`]);
    assert(store.claimBatch("default", 10).length == 0); // running, or not due yet

    auto crit = store.claimBatch("critical", 10);
    assert(crit.length == 1 && crit[0].payload == `{"label":"hot"}` && crit[0].priority == 10);

    clock.us += 5_000_000;
    auto due = store.claimBatch("default", 10);
    assert(due.length == 1 && due[0].payload == `{"label":"later"}`);
    assert(due[0].attempt == 1);
}

unittest
{
    // An empty queue name claims every queue, still by priority then runAt then id.
    auto clock = new Clock;
    clock.us = 5_000;
    auto store = new TestJobStore(&clock.now);

    Task late;
    late.label = "late";
    Urgent hot;
    hot.label = "hot";
    Task plain;
    plain.label = "plain";

    enqueueAt(store, late, clock.us + 1_000, 1); // best priority, not due
    enqueue(store, hot, 10);
    enqueue(store, plain, 10); // same priority as hot, enqueued after, so a higher id

    auto batch = store.claimBatch("", 10);
    assert(payloads(batch) == [`{"label":"hot"}`, `{"label":"plain"}`], batch.length ? batch[0].payload : "empty");
    assert(store.jobs.length == 3);
    bool stillScheduled;
    foreach (r; store.jobs)
        if (r.payload == `{"label":"late"}`)
            stillScheduled = r.state == JobState.scheduled;
    assert(stillScheduled);
}
