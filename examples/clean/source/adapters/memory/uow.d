/// The unit of work in memory: it takes a snapshot of every store it tracks before the work, and puts them back when
/// the work throws, so the memory adapters roll back like Postgres does.
module adapters.memory.uow 2025;

@safe:

import usecases.uow : UnitOfWork;

final class MemoryUnitOfWork : UnitOfWork
{
    private void delegate() @safe delegate() @safe[] snapshots;

    /// Rolls `store` back with the others: `store.snapshot()` returns a function that restores what it has now. Returns
    /// `store`, for `a.users = uow.track(new MemoryUserRepository);`.
    T track(T)(T store)
    {
        snapshots ~= &store.snapshot;
        return store;
    }

    void run(scope void delegate() @safe work)
    {
        void delegate() @safe[] restores;
        foreach (take; snapshots)
            restores ~= take();
        scope (failure)
            foreach_reverse (restore; restores)
                restore();
        work();
    }

    void readOnly(scope void delegate() @safe work)
    {
        run(work);
    }
}
