
/// Runs {{Name}} later, in the background: the port. Called inside a unit of work, the job is stored with the
/// transaction, or not at all (`adapters/jobs/{{feature}}.d`).
interface {{Name}}Scheduler
{
    void schedule({{params}});
}
