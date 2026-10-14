// FLAGS: -Ijobs/source
// EXPECT: vela.jobs: job 'job_system.SystemPerform' perform is @system; mark it @safe
import vela.jobs;
@safe:
@Job("default")
struct SystemPerform
{
    void perform(ref JobContext ctx) @system {}
}
alias Jobs = JobSet!SystemPerform;
void main() {}
