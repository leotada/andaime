
/// The payload of {{Name}}: what is stored, nothing else.
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
