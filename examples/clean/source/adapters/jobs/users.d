/// The background jobs of users. A job is an entry point, like a controller: its fields are the payload, and
/// `perform` hands them to a use case.
module adapters.jobs.users;

@safe:

import andaime.http.optional : Optional;
import andaime.jobs;
import core.time; // the periods of @Every
import adapters.jobs.provider : provided;
import usecases.users;

@Job("default")
struct SendWelcomeJob
{
    long userId;

    void perform(ref JobContext ctx) @safe
    {
        provided!SendWelcome.get().execute(userId);
    }
}
