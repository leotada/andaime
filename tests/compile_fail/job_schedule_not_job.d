// FLAGS: -Ijobs/source
// EXPECT: andaime.jobs: job 'job_schedule_not_job.Plain' is missing @Job("queue"); every job names its queue
import andaime.jobs;
import core.time : minutes;
@safe:
struct Plain
{
    void perform(ref JobContext ctx) {}
}
void main()
{
    JobSchedule s;
    s.every!Plain(5.minutes);
}
