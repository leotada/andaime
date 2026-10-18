/// The use cases the jobs call. andaime:jobs builds a job from its JSON payload, so a job has no constructor to receive
/// them: `jobs.d` registers how to build each use case before serving, and every thread that runs jobs builds its own
/// on first use, with its own database pool and no locks.
module adapters.jobs.provider;

@safe:

/// `provided!SendWelcome.get()` is this thread's `SendWelcome`.
template provided(T) if (is(T == class))
{
    private __gshared T function() @safe factory; // written by `provide` before serving, then only read
    private T instance;                           // thread-local

    /// Registers how to build `T`. Call it on the main thread, before serving (tests may call it again: it also drops
    /// the calling thread's instance).
    void provide(T function() @safe make) @system
    {
        factory = make;
        instance = null;
    }

    /// This thread's `T`, built on first use.
    T get() @trusted // sound: `factory` is only written before any worker thread exists (or by a test's own thread)
    {
        if (instance is null)
        {
            assert(factory !is null, "provided!(" ~ T.stringof ~ ") has no factory: call its provide in jobs.d");
            instance = factory();
        }
        return instance;
    }
}
