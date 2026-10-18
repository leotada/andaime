// FLAGS: -Ijobs/source
// EXPECT: andaime.jobs: job 'job_system.SystemPerform' perform is @system; mark it @safe
import andaime.jobs;
@safe:
@Job("default")
struct SystemPerform
{
    void perform(ref JobContext ctx) @system {}
}
alias Jobs = JobSet!SystemPerform;
void main() {}
