/// drainJobs runs due jobs and leaves the rest. assertEnqueued checks name, queue and payload.
module drain 2025;

@safe:

import core.exception : AssertError;
import andaime.jobs;

final class Clock
{
    long us;
    long now() @safe nothrow
    {
        return us;
    }
}

string[] trace;

@Job("mail")
struct Send
{
    string to;
    int n;
    void perform(ref JobContext ctx)
    {
        trace ~= to;
    }
}

@Job("mail")
@Offload
struct Heavy
{
    string work;
    void perform(ref JobContext ctx)
    {
        trace ~= work;
    }
}

@Job("later")
struct Soon
{
    string when;
    void perform(ref JobContext ctx)
    {
        trace ~= when;
    }
}

private bool has(string s, string part)
{
    if (part.length > s.length)
        return false;
    foreach (size_t i; 0 .. s.length - part.length + 1)
        if (s[i .. i + part.length] == part)
            return true;
    return false;
}

unittest
{
    auto clock = new Clock;
    clock.us = 10_000;
    auto store = new TestJobStore(&clock.now);
    trace = null;

    Send mail;
    mail.to = "a@b.c";
    mail.n = 2;
    Heavy cpu;
    cpu.work = "cpu";
    Soon wait;
    wait.when = "wait";

    enqueue(store, mail, 50);
    enqueue(store, cpu, 10);
    enqueueAt(store, wait, clock.us + 1_000_000, 10);

    store.assertEnqueued!Send("a@b.c");
    store.assertEnqueued!Send(`"n":2`);
    store.assertEnqueued!Heavy("cpu");

    store.drainJobs!(Send, Heavy, Soon)();
    assert(trace == ["cpu", "a@b.c"]);
    bool waiting;
    foreach (r; store.jobs)
    {
        if (r.name == jobName!Soon)
            waiting = r.state == JobState.scheduled;
        else
            assert(r.state == JobState.completed);
    }
    assert(waiting);

    clock.us += 1_000_000;
    store.drainJobs!(Send, Heavy, Soon)();
    assert(trace == ["cpu", "a@b.c", "wait"]);
}

// @system: AssertError is an Error, and @safe code cannot catch it. This checks the failure names the job.
@system unittest
{
    auto clock = new Clock;
    auto store = new TestJobStore(&clock.now);
    Send mail;
    mail.to = "a@b.c";
    mail.n = 2;
    Soon wait;
    wait.when = "wait";
    enqueue(store, mail);
    enqueue(store, wait);

    bool missed;
    try
        store.assertEnqueued!Send("nobody");
    catch (AssertError e)
        missed = has(e.msg, "nobody") && has(e.msg, "mail") && has(e.msg, jobName!Send);
    assert(missed);

    // The substring is on a different job and queue, so the name and queue check rejects it.
    missed = false;
    try
        store.assertEnqueued!Send("wait");
    catch (AssertError e)
        missed = has(e.msg, jobName!Send);
    assert(missed);

    missed = false;
    try
        store.assertEnqueued!Soon("a@b.c");
    catch (AssertError e)
        missed = has(e.msg, "later") && has(e.msg, jobName!Soon);
    assert(missed);
}

unittest
{
    auto clock = new Clock;
    auto store = new TestJobStore(&clock.now);

    JobSpec bad;
    bad.queue = jobQueue!Send;
    bad.name = jobName!Send;
    bad.payload = "{";
    bad.maxAttempts = 3;
    auto id = store.enqueue(bad).id;
    store.drainJobs!Send();
    bool found;
    foreach (r; store.jobs)
    {
        if (r.id != id)
            continue;
        found = r.state == JobState.discarded && r.attempt == 1 && has(r.lastError, "does not match");
    }
    assert(found);

    JobSpec unknown;
    unknown.queue = "mail";
    unknown.name = "no.such.Job";
    unknown.payload = "{}";
    auto uid = store.enqueue(unknown).id;
    store.drainJobs!Send();
    found = false;
    foreach (r; store.jobs)
    {
        if (r.id != uid)
            continue;
        found = r.state == JobState.discarded && has(r.lastError, "unknown job");
    }
    assert(found);
}
