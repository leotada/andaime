/// Every job UDA in the form the docs recommend. `tools/check.sh` also runs D-Scanner over this file: libdparse, the
/// parser under D-Scanner, dfmt, DCD and serve-d, must accept every option (no named argument inside a UDA).
module job_udas_syntax 2025;

@safe:

import core.time : hours, minutes;
import andaime.jobs;

@Job("mail") @DropOnSuccess @Retry(3, BackoffStrategy.exponential) @UniqueJob(1.hours) @Offload
struct SendCode
{
    string code;
    void perform(ref JobContext) {}
}

@Job("reports") @Every(5.minutes)
struct Refresh
{
    void perform(ref JobContext) {}
}

@Job("reports") @Cron("15 6 * * *")
struct Daily
{
    void perform(ref JobContext) {}
}

unittest
{
    static assert(jobError!SendCode == "" && jobError!Refresh == "" && jobError!Daily == "");
    static assert(jobQueue!SendCode == "mail" && jobDropOnSuccess!SendCode && jobMaxAttempts!SendCode == 3);
    static assert(jobUniquePeriod!SendCode == 1.hours && jobOffload!SendCode);
    static assert(jobEveryPeriod!Refresh == 5.minutes && jobCronExpr!Daily == "15 6 * * *");
    static assert(!jobDropOnSuccess!Refresh);
}
