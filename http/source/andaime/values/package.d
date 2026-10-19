/// `andaime.values`: plain values with no I/O and no dependency on the web, engine or database layers, so a domain may
/// import them: `Optional`, `PatchField`, `JsonValue` (parse and serialize), `Uuid`. Randomness and the clock are effects,
/// not values: generating a UUID is `andaime.engine.random.uuid4`/`uuid7`, which a domain reaches through a port.
module andaime.values 2025;

public import andaime.values.optional;
public import andaime.values.patchfield;
public import andaime.values.jsonvalue;
public import andaime.values.uuid;
