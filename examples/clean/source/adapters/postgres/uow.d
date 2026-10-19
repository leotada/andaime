/// The unit of work over this worker's pool. `db.transaction` is ambient: while `work` runs, every repository built over
/// `db` (and the job store, which uses the same conninfo) runs its statements on that transaction's connection, so the
/// repositories need no connection passed in. Work sent to `offload` does not see it.
module adapters.postgres.uow 2025;

@safe:

import andaime.db : PgConn, PgPool, TxMode;
import usecases.uow : UnitOfWork;

final class PgUnitOfWork : UnitOfWork
{
    private PgPool db;

    this(PgPool db)
    {
        this.db = db;
    }

    void run(scope void delegate() @safe work)
    {
        db.transaction((PgConn _) { work(); });
    }

    void readOnly(scope void delegate() @safe work)
    {
        db.transaction((PgConn _) { work(); }, TxMode.readOnly);
    }
}
