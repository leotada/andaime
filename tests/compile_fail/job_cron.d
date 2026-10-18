// FLAGS: -Ijobs/source
// EXPECT: andaime.jobs: job 'job_cron.BadCron' has an invalid @Cron: expected 5 fields (minute hour day-of-month month day-of-week)
import andaime.jobs;
@safe:
@Job("default")
@Cron("1 2 3")
struct BadCron
{
    void perform(ref JobContext ctx) {}
}
alias Jobs = JobSet!BadCron;
void main() {}
