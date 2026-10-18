// FLAGS: -Ijobs/source
// EXPECT: andaime.jobs: job 'job_no_perform.NoPerform' must define 'void perform(ref JobContext ctx) @safe'
import andaime.jobs;
@safe:
@Job("default")
struct NoPerform
{
    string to;
}
alias Jobs = JobSet!NoPerform;
void main() {}
