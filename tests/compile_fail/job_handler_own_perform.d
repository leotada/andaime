// FLAGS: -Ijobs/source
// EXPECT: andaime.jobs: job 'job_handler_own_perform.SendMail' has its own perform; register a handler or keep perform, not both
import andaime.jobs;
@safe:
@Job("mail") struct SendMail { string to; void perform(ref JobContext) {} }
final class MailHandler { void perform(const SendMail job, ref JobContext ctx) {} }
void main() { auto h = new JobHandlers; h.handle!SendMail(new MailHandler); }
