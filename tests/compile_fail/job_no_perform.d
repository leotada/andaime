// FLAGS: -Ijobs/source
// EXPECT: andaime.jobs: job 'job_no_perform.NoPerform' must define 'void perform(ref JobContext ctx) @safe', or be drained with its handlers
import andaime.jobs;
@safe:
@Job("default")
struct NoPerform
{
    string to;
}
void main() { auto store = new TestJobStore; store.drainJobs!NoPerform(); }
