// FLAGS: -Ijobs/source
// EXPECT: andaime.jobs: job 'job_pointer.WithPointer' field 'userId' has type 'int*' which is not serializable to JSON. Use bool, numbers, string, enum, arrays, string-keyed maps, structs or Optional!T.
import andaime.jobs;
@safe:
@Job("default")
struct WithPointer
{
    int* userId;
    void perform(ref JobContext ctx) {}
}
alias Jobs = JobSet!WithPointer;
void main() {}
