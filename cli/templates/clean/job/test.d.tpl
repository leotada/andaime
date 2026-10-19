
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

unittest // Queued{{Name}} schedules within the unit of work: a rollback takes the job back
{
    auto uow = new MemoryUnitOfWork;
    auto store = uow.track(new TestJobStore);
    auto scheduler = new Queued{{Name}}(store);
    try
        uow.run(() { scheduler.schedule({{sampleArgs}}); throw new Exception("the use case failed"); });
    catch (Exception)
    {
    }
    assert(store.jobs().length == 0);
    uow.run(() { scheduler.schedule({{sampleArgs}}); });
    store.assertEnqueued!{{Name}}Job(`{{payload}}`);
}
