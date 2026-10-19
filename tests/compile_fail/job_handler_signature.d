// FLAGS: -Ijobs/source
// EXPECT: andaime.jobs: handler 'MailHandler' for job 'job_handler_signature.SendMail' must define 'void perform(const SendMail job, ref JobContext ctx) @safe'
import andaime.jobs;
@safe:
@Job("mail") struct SendMail { string to; }
final class MailHandler { void perform(SendMail job) {} }
void main() { auto h = new JobHandlers; h.handle!SendMail(new MailHandler); }
