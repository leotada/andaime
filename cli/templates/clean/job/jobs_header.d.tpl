/// The background jobs of {{feature}}. A job is an entry point, like a controller: its fields are the payload, and
/// `perform` hands them to a use case.
module adapters.jobs.{{feature}} 2025;

@safe:

import andaime.http.optional : Optional;
import andaime.jobs;
import core.time; // the periods of @Every
import adapters.jobs.provider : provided;
import usecases.{{feature}};
