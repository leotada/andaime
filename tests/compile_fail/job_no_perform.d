// FLAGS: -Ijobs/source
// EXPECT: vela.jobs: job 'job_no_perform.NoPerform' must define 'void perform(ref JobContext ctx) @safe'
import vela.jobs;
@safe:
@Job("default")
struct NoPerform
{
    string to;
}
alias Jobs = JobSet!NoPerform;
void main() {}
