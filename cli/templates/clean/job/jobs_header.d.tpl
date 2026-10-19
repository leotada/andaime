/// The background jobs of {{feature}}. Each one is a payload (what is stored) and a handler (an entry point, like a
/// controller) that hands the payload to a use case; `source/jobs.d` builds the handlers.
module adapters.jobs.{{feature}} 2025;

@safe:

import andaime.values.optional : Optional;
import andaime.jobs;
import core.time; // the periods of @Every
import usecases.{{feature}};
