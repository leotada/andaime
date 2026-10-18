
unittest // {{Name}}Job carries its payload and runs {{Name}}
{
    (() @trusted => provided!{{Name}}.provide(() => new {{Name}}(new Memory{{Entity}}Repository)))();
    auto store = new TestJobStore;
    {{Name}}Job job;
{{#fields}}
    job.{{name}} = {{sample1}};
{{/fields}}
    enqueue(store, job);
    store.assertEnqueued!{{Name}}Job(`{{payload}}`);
    store.drainJobs!{{Name}}Job();
}
