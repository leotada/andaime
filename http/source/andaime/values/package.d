/// `andaime.values`: plain values with no I/O and no dependency on the web, engine or database layers, so a domain may
/// import them: `Optional`, `PatchField`, `JsonValue` (parse and serialize), `Uuid`, `Timestamp` and `CalendarDate`.
/// Randomness and the clock are effects, not values: generating a UUID is `andaime.engine.random.uuid4`/`uuid7`, and
/// "now" is a port of the application; a domain reaches both through a port.
module andaime.values 2025;

public import andaime.values.optional;
public import andaime.values.patchfield;
public import andaime.values.jsonvalue;
public import andaime.values.uuid;
public import andaime.values.timestamp;
public import andaime.values.calendardate;
public import andaime.values.copy;
