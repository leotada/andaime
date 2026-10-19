
/// The payload of {{Name}}: what is stored, nothing else. Options are UDAs of their own, next to `@Job`:
/// `@Retry(3, BackoffStrategy.exponential)`, `@UniqueJob(15.minutes)`, `@DropOnSuccess` (a payload with a secret).
@Job("{{queue}}")
{{#schedule}}
{{schedule}}
{{/schedule}}
struct {{Name}}Job
{
{{#fields}}
    {{type}} {{name}};
{{/fields}}
}

/// Runs {{Name}}Job: an entry point, like a controller. It gets its use case from the jobs' composition root
/// (`buildJobs` in `source/jobs.d`) and hands it the payload.
final class {{Name}}Handler
{
    private {{Name}} useCase;

    this({{Name}} useCase)
    {
        this.useCase = useCase;
    }

    void perform(const {{Name}}Job job, ref JobContext ctx) @safe
    {
        useCase.execute({{jobArgs}});
    }
}

/// `{{Name}}Scheduler` over the job store: the job is a row in the same database. Inside a `PgUnitOfWork` the enqueue
/// joins its transaction (the outbox: stored and woken only if the work commits); a `MemoryUnitOfWork` that tracks the
/// store takes it back on a rollback.
final class Queued{{Name}} : {{Name}}Scheduler
{
    private JobStore store;

    this(JobStore store)
    {
        this.store = store;
    }

    void schedule({{params}})
    {
        {{Name}}Job job;
{{#fields}}
        job.{{name}} = {{name}};
{{/fields}}
        enqueue(store, job);
    }
}
