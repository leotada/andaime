/// The jobs of {{feature}}, run through a test store, with their use cases over in-memory adapters.
module tests.{{feature}}_jobs 2025;

@safe:

import andaime;
import andaime.jobs;
import adapters.jobs.{{feature}};
import adapters.memory.{{feature}} : Memory{{Entity}}Repository;
import adapters.memory.uow : MemoryUnitOfWork;
import usecases.{{feature}};
