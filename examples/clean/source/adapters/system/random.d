/// Identifiers and tokens from the system's secure random generator.
module adapters.system.random 2025;

@safe:

import andaime : uuid7, Uuid;
import andaime.engine.random : randomBytes;
import andaime.http.base64url : base64UrlEncode;
import usecases.system : IdGenerator, TokenGenerator;

/// Version 7 UUIDs: increasing on each thread.
final class Uuid7Ids : IdGenerator
{
    Uuid newId() => uuid7();
}

/// 32 random bytes (256 bits) in base64url: 43 characters.
final class RandomTokens : TokenGenerator
{
    string newToken()
    {
        ubyte[32] b;
        randomBytes(b[]);
        return base64UrlEncode(b[]);
    }
}
