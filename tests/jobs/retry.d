/// A failure is retried with backoff, then discarded. JobDiscard skips the retry.
/// An Error is returned to the queue without spending the attempt, and it propagates.
module retry;

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

JobContext seen;
TestJobStore active;
int runs;

@Job("default")
struct Once
{
    string label;
    void perform(ref JobContext ctx)
    {
        runs++;
        seen = ctx;
        throw new Exception("fail");
    }
}

@Job("default")
@Offload
@Retry(3, BackoffStrategy.exponential)
struct Flaky
{
    string label;
    void perform(ref JobContext ctx)
    {
        runs++;
        seen = ctx;
        if (active !is null)
        {
            bool running;
            foreach (r; active.jobs)
                if (r.id == ctx.id)
                    running = r.state == JobState.running && r.attempt == ctx.attempt;
            assert(running, "claim marks the row running before perform");
        }
        throw new Exception("nope");
    }
}

@Job("mail")
@Retry(5, BackoffStrategy.exponential)
struct Drop
{
    string label;
    void perform(ref JobContext ctx)
    {
        runs++;
        throw new JobDiscard("drop me");
    }
}

int booms;
int boomAttempt;

@Job("default")
@Offload
@Retry(4, BackoffStrategy.exponential)
struct Boom
{
    int n;
    void perform(ref JobContext ctx)
    {
        booms++;
        boomAttempt = ctx.attempt;
        throw new Error("fiber poisoned");
    }
}

private JobRecord only(TestJobStore store)
{
    auto rows = store.jobs;
    assert(rows.length == 1);
    return rows[0];
}

unittest
{
    // No @Retry: the single failure is discarded. Nothing is scheduled.
    auto clock = new Clock;
    auto store = new TestJobStore(&clock.now);
    runs = 0;
    Once job;
    job.label = "once";
    auto id = enqueue(store, job).id;
    store.drainJobs!Once();
    assert(runs == 1);
    auto row = only(store);
    assert(row.state == JobState.discarded && row.attempt == 1 && row.lastError == "fail");
    assert(row.runAtUs == 0);
    assert(seen.id == id && seen.attempt == 1 && seen.maxAttempts == 1 && seen.queue == "default");
    store.drainJobs!Once();
    assert(runs == 1);
}

unittest
{
    auto clock = new Clock;
    auto store = new TestJobStore(&clock.now);
    active = store;
    scope (exit)
        active = null;
    runs = 0;

    Flaky job;
    job.label = "f";
    auto id = enqueue(store, job).id;

    store.drainJobs!Flaky();
    assert(runs == 1);
    auto row = only(store);
    assert(row.state == JobState.retryable && row.attempt == 1 && row.lastError == "nope");
    assert(row.runAtUs == 1_000_000); // 1 second * 2^^0
    assert(seen.id == id && seen.attempt == 1 && seen.maxAttempts == 3 && seen.queue == "default");

    store.drainJobs!Flaky();
    assert(runs == 1); // not due yet

    clock.us = 999_999;
    store.drainJobs!Flaky();
    assert(runs == 1);

    clock.us = 1_000_000;
    store.drainJobs!Flaky();
    assert(runs == 2 && seen.attempt == 2);
    row = only(store);
    assert(row.state == JobState.retryable && row.attempt == 2 && row.runAtUs == 1_000_000 + 2_000_000);

    clock.us = 2_999_999;
    store.drainJobs!Flaky();
    assert(runs == 2);

    clock.us = 3_000_000;
    store.drainJobs!Flaky();
    assert(runs == 3 && seen.attempt == 3);
    row = only(store);
    assert(row.state == JobState.discarded && row.attempt == 3 && row.lastError == "nope");
    store.drainJobs!Flaky();
    assert(runs == 3);
}

unittest
{
    auto clock = new Clock;
    auto store = new TestJobStore(&clock.now);
    runs = 0;
    Drop job;
    job.label = "d";
    enqueue(store, job);
    store.drainJobs!Drop();
    assert(runs == 1);
    auto row = only(store);
    assert(row.state == JobState.discarded && row.attempt == 1 && row.lastError == "drop me");
    assert(row.queue == "mail");
    store.drainJobs!Drop();
    assert(runs == 1);
}

// @system: this test catches Error to check the row afterwards. @safe code is not allowed to catch it.
// The runner itself does not catch Error; it only gives the attempt back and lets it propagate.
@system unittest
{
    auto clock = new Clock;
    clock.us = 50;
    auto store = new TestJobStore(&clock.now);
    booms = 0;
    Boom job;
    job.n = 1;
    enqueue(store, job);

    bool saw;
    try
        store.drainJobs!Boom();
    catch (Error e)
    {
        saw = e.msg == "fiber poisoned";
        if (!saw)
            throw e;
    }
    assert(saw);
    auto row = only(store);
    assert(row.state == JobState.retryable && row.attempt == 0 && row.runAtUs == 50);
    assert(booms == 1 && boomAttempt == 1);

    saw = false;
    try
        store.drainJobs!Boom();
    catch (Error e)
    {
        saw = e.msg == "fiber poisoned";
        if (!saw)
            throw e;
    }
    assert(saw);
    row = only(store);
    assert(row.state == JobState.retryable && row.attempt == 0);
    assert(booms == 2 && boomAttempt == 1);
}
