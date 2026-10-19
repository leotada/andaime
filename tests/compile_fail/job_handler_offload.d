// FLAGS: -Ijobs/source
// EXPECT: andaime.jobs: job 'job_handler_offload.Resize' is @Offload, but a handler's dependencies belong to its worker thread
import andaime.jobs;
@safe:
@Job("img") @Offload struct Resize { long id; }
final class ResizeHandler { void perform(const Resize job, ref JobContext ctx) {} }
void main() { auto h = new JobHandlers; h.handle!Resize(new ResizeHandler); }
