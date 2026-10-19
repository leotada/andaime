/// The effects a use case may need from the system: the time, new identifiers, unguessable tokens. They are ports, not
/// calls, so a test gives fixed ones (`tests/fakes.d`) and the result does not depend on when or where it runs.
/// `adapters/system/` implements them.
module usecases.system 2025;

@safe:

import andaime.values.timestamp : Timestamp;
import andaime.values.uuid : Uuid;

/// The current time.
interface Clock
{
    Timestamp now();
}

/// New identifiers: time-ordered UUIDs (version 7), good primary keys.
interface IdGenerator
{
    Uuid newId();
}

/// Unguessable tokens for links and codes (an invitation, a password reset), URL-safe.
interface TokenGenerator
{
    string newToken();
}
