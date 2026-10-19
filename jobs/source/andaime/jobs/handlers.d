/// Jobs that receive their dependencies: the payload (`@Job` struct, what is stored) is apart from its handler (a class
/// built with the use cases it calls), and a composition root builds the handlers once per worker thread, as `buildApp`
/// builds the routes:
///
///     @Job("mail") struct SendWelcome { long userId; }          // the payload
///
///     final class SendWelcomeHandler
///     {
///         private WelcomeUser welcome;                          // a use case
///         this(WelcomeUser welcome) { this.welcome = welcome; }
///         void perform(const SendWelcome job, ref JobContext ctx) @safe { welcome.execute(job.userId); }
///     }
///
///     JobHandlers buildJobs()                                   // once per worker thread
///     {
///         auto handlers = new JobHandlers;
///         handlers.handle!SendWelcome(new SendWelcomeHandler(new WelcomeUser(currentAdapters().users)));
///         return handlers;
///     }
///
/// Give `buildJobs` to the runner (`WorkerHooks.handlers`, `TestJobStore.drainJobs!Jobs(handlers)`). At startup every job
/// of the list without its own `perform` must have a handler, and every handler must be for a job of the list. A struct
/// with its own `perform` keeps working without one.
module andaime.jobs.handlers 2025;

@safe:

import andaime.jobs.job : JobContext, hasOwnPerform, jobName, jobOffload, jobPayloadError;

/// One line saying why `H` cannot handle the payload `P`, or "".
template jobHandlerError(P, H)
{
    static if (jobPayloadError!P.length)
        enum string jobHandlerError = jobPayloadError!P;
    else static if (hasOwnPerform!P)
        enum string jobHandlerError = "andaime.jobs: job '" ~ jobName!P ~ "' has its own perform; register a handler "
            ~ "or keep perform, not both";
    else static if (jobOffload!P)
        enum string jobHandlerError = "andaime.jobs: job '" ~ jobName!P ~ "' is @Offload, but a handler's dependencies "
            ~ "belong to its worker thread; drop @Offload and call offload inside the handler for the heavy part";
    else static if (!__traits(compiles, (H h, ref const P p, ref JobContext c) @safe { h.perform(p, c); }))
        enum string jobHandlerError = "andaime.jobs: handler '" ~ H.stringof ~ "' for job '" ~ jobName!P
            ~ "' must define 'void perform(const " ~ P.stringof ~ " job, ref JobContext ctx) @safe'";
    else
        enum string jobHandlerError = "";
}

/// The handlers of one worker thread, one per payload type (see the module).
final class JobHandlers
{
    private Object[string] byName; // jobName!P -> HandlerBox!P

    /// Registers `handler` for the payload `P`. `handler` has `void perform(const P job, ref JobContext ctx) @safe`; it
    /// is kept for the life of the worker. Registering `P` twice throws.
    void handle(P, H)(H handler)
    {
        static if (jobHandlerError!(P, H).length)
            static assert(0, jobHandlerError!(P, H));
        else
        {
            enum name = jobName!P;
            if (name in byName)
                throw new Exception("andaime.jobs: job '" ~ name ~ "' has two handlers");
            auto box = new HandlerBox!P;
            box.call = (ref const P p, ref JobContext c) @safe { handler.perform(p, c); };
            byName[name] = box;
        }
    }

    /// True when a handler is registered for the job named `name`.
    bool has(string name) const nothrow
    {
        return (name in byName) !is null;
    }

    /// The names of the registered jobs.
    string[] names() const
    {
        return byName.keys;
    }

    /// The handler of `P`, or null.
    package HandlerBox!P boxOf(P)()
    {
        if (auto p = jobName!P in byName)
            return reinterpretBox!P(*p);
        return null;
    }
}

/// A handler with its payload type: what `runClaimed` calls once the payload is decoded.
package final class HandlerBox(P)
{
    void delegate(ref const P, ref JobContext) @safe call;
}

private HandlerBox!P reinterpretBox(P)(Object o) @trusted
{
    // @trusted: `byName[jobName!P]` is only ever set to a HandlerBox!P by `handle!P`
    return cast(HandlerBox!P) cast(void*) o;
}

/// Checks a worker's handlers against its job list, at startup: throws naming the first job of `Jobs` without its own
/// `perform` and without a handler, or the first handler for a job that is not in `Jobs`.
void checkHandlers(Jobs...)(const JobHandlers handlers)
{
    static foreach (J; Jobs)
        static if (!hasOwnPerform!J)
            if (handlers is null || !handlers.has(jobName!J))
                throw new Exception("andaime.jobs: no handler for job '" ~ jobName!J ~ "'; call handlers.handle!"
                    ~ J.stringof ~ "(...) in the jobs' build function");
    if (handlers is null)
        return;
    foreach (name; handlers.names)
    {
        bool known;
        static foreach (J; Jobs)
            known |= name == jobName!J;
        if (!known)
            throw new Exception("andaime.jobs: a handler is registered for job '" ~ name
                ~ "', which is not in the job list given to the runner");
    }
}
