/// Jobs that receive their dependencies: a payload struct without `perform`, a handler class built with a use case, a
/// composition root per worker. A missing or unknown handler fails at startup; a struct with its own `perform` still runs.
module handlers_test 2025;

@safe:

import core.time : minutes;
import andaime.jobs;

// the use case a handler calls (in an application: usecases/)
final class WelcomeUser
{
    string[] sent;
    void execute(long userId) { sent ~= "welcome " ~ (userId == 7 ? "7" : "?"); }
}

@Job("mail")
struct SendWelcome { long userId; }                     // the payload: what is stored

final class SendWelcomeHandler
{
    private WelcomeUser welcome;
    this(WelcomeUser welcome) { this.welcome = welcome; }
    void perform(const SendWelcome job, ref JobContext ctx) { welcome.execute(job.userId); }
}

@Job("mail") @Every(5.minutes)
struct Digest { }                                       // a scheduled payload, also with a handler

final class DigestHandler
{
    int runs;
    void perform(const Digest, ref JobContext) { runs++; }
}

string[] plainRuns;

@Job("mail")
struct Plain                                            // the small-application style keeps working
{
    string note;
    void perform(ref JobContext) { plainRuns ~= note; }
}

@Job("other")
struct Unlisted { }

final class UnlistedHandler { void perform(const Unlisted, ref JobContext) {} }

alias AllJobs = AliasSeq!(SendWelcome, Digest, Plain);
template AliasSeq(T...) { alias AliasSeq = T; }

unittest
{
    auto welcome = new WelcomeUser;
    auto digest = new DigestHandler;
    JobHandlers buildJobs()
    {
        auto h = new JobHandlers;
        h.handle!SendWelcome(new SendWelcomeHandler(welcome));
        h.handle!Digest(digest);
        return h;
    }

    auto store = new TestJobStore;
    enqueue(store, SendWelcome(7));
    enqueue(store, Digest());
    enqueue(store, Plain("plain"));
    store.drainJobs!AllJobs(buildJobs());
    assert(welcome.sent == ["welcome 7"] && digest.runs == 1 && plainRuns == ["plain"]);
    foreach (r; store.jobs())
        assert(r.state == JobState.completed, r.name);

    // a job without perform and without a handler fails before anything runs
    auto partial = new JobHandlers;
    partial.handle!SendWelcome(new SendWelcomeHandler(welcome));
    bool threw;
    try
        store.drainJobs!AllJobs(partial);
    catch (Exception e)
        threw = e.msg == "andaime.jobs: no handler for job 'handlers_test.Digest'; call handlers.handle!Digest(...) in "
            ~ "the jobs' build function";
    assert(threw);
    threw = false;
    try
        checkHandlers!AllJobs(null);
    catch (Exception e)
        threw = true;
    assert(threw, "no handlers at all: the payload-only jobs are missing theirs");

    // a handler for a job the runner does not know
    auto extra = buildJobs();
    extra.handle!Unlisted(new UnlistedHandler);
    threw = false;
    try
        checkHandlers!AllJobs(extra);
    catch (Exception e)
        threw = e.msg == "andaime.jobs: a handler is registered for job 'handlers_test.Unlisted', which is not in the "
            ~ "job list given to the runner";
    assert(threw);

    // two handlers for one payload
    threw = false;
    try
        buildJobs().handle!SendWelcome(new SendWelcomeHandler(welcome));
    catch (Exception e)
        threw = e.msg == "andaime.jobs: job 'handlers_test.SendWelcome' has two handlers";
    assert(threw);

    // the runners refuse to start without handlers for payload-only jobs, and accept a build function
    auto startup = parseStartup(["app", "--role=all", "--queues=mail:1"]);
    threw = false;
    try
        cast(void) supervisorHook!AllJobs(store, startup);
    catch (Exception e)
        threw = true;
    assert(threw);
    WorkerHooks hooks;
    hooks.handlers = &buildJobs;
    assert(supervisorHook!AllJobs(store, startup, hooks) !is null);

    // the struct-only style needs nothing
    checkHandlers!Plain(null);
    store.drainJobs!Plain();
}
