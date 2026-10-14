/// Background jobs: the compile-time contract, in-memory queues, cron, and `--role` / `--queues`.
module vela.jobs;

@safe:

public import vela.jobs.job;
public import vela.jobs.cron;
public import vela.jobs.backend;
public import vela.jobs.cli;
public import vela.jobs.worker;
