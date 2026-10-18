/// `JobTransaction` without a database: `TestJobStore.transaction()` publishes on commit and drops on rollback, so code
/// that enqueues "after commit" is tested the same way it runs on Postgres (`PgJobStore.within(tx)`).
module transaction;

@safe:

import core.time : minutes;
import andaime.jobs;

@Job("mail")
struct Welcome
{
    string email;
    void perform(ref JobContext ctx) {}
}

@Job("mail")
@UniqueJob(1.minutes)
struct Digest
{
    string email;
    void perform(ref JobContext ctx) {}
}

/// Application code: takes the interface, never a concrete store.
void signUp(JobTransaction tx, string email)
{
    enqueue(tx, Welcome(email));
    enqueue(tx, Digest(email));
}

unittest
{
    auto store = new TestJobStore;

    // committed: the jobs reach the store, in order, with their real ids
    auto tx = store.transaction();
    signUp(tx, "ana@x.com");
    assert(tx.pending.length == 2 && store.jobs().length == 0, "nothing is visible before the commit");
    auto results = tx.commit();
    assert(results.length == 2 && results[0].inserted && results[0].id > 0);
    store.assertEnqueued!Welcome("ana@x.com");
    store.assertEnqueued!Digest("ana@x.com");

    // rolled back: nothing
    tx = store.transaction();
    signUp(tx, "bia@x.com");
    tx.rollback();
    assert(store.jobs().length == 2);

    // unique windows apply at the commit, as on Postgres
    tx = store.transaction();
    enqueue(tx, Digest("ana@x.com"));
    results = tx.commit();
    assert(!results[0].inserted && store.jobs().length == 2);

    // a finished transaction refuses more work
    bool threw;
    try
        enqueue(tx, Welcome("late@x.com"));
    catch (JobStoreError e)
        threw = e.msg == "andaime.jobs: enqueue on a transaction that was already committed or rolled back";
    assert(threw);
    threw = false;
    try
        tx.commit();
    catch (JobStoreError e)
        threw = true;
    assert(threw);
}
