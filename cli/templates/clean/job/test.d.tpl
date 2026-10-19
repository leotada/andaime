
unittest // {{Name}}Job carries its payload, and its handler runs {{Name}}
{
    auto handlers = new JobHandlers;
    handlers.handle!{{Name}}Job(new {{Name}}Handler(new {{Name}}(new Memory{{Entity}}Repository)));
    auto store = new TestJobStore;
    {{Name}}Job job;
{{#fields}}
    job.{{name}} = {{sample1}};
{{/fields}}
    enqueue(store, job);
    store.assertEnqueued!{{Name}}Job(`{{payload}}`);
    store.drainJobs!{{Name}}Job(handlers);
}
