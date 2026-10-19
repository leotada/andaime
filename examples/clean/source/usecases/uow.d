/// The transaction boundary of the use cases: the port. A use case that writes through two repositories (or writes and
/// schedules a job) runs that work in `uow.run`: it is stored together, or not at all when the work throws. The use case
/// decides where the boundary is; the adapter decides what a transaction is (`adapters/postgres/uow.d`,
/// `adapters/memory/uow.d`).
module usecases.uow 2025;

@safe:

interface UnitOfWork
{
    /// Runs `work` in one transaction; when it throws, nothing it wrote stays. Nested calls nest (a savepoint).
    void run(scope void delegate() @safe work);

    /// The same for reading: one consistent view of the data, and a write inside fails.
    void readOnly(scope void delegate() @safe work);
}

/// `uow.run` for work that returns a value: `auto company = inUnitOfWork(uow, () => companies.add(...));`.
T inUnitOfWork(T)(UnitOfWork uow, scope T delegate() @safe work)
{
    T result;
    uow.run(() { result = work(); });
    return result;
}
