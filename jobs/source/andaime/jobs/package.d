/// Background jobs: the compile-time contract, in-memory queues, cron, and `--role` / `--queues`.
module andaime.jobs 2025;

@safe:

public import andaime.jobs.job;
public import andaime.jobs.cron;
public import andaime.jobs.backend;
public import andaime.jobs.cli;
public import andaime.jobs.worker;
