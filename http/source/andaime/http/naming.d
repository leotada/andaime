/// Wire names: how a D identifier (a struct field, an enum member) is spelled in JSON, a query string, a form, an OpenAPI
/// document and a database column.
///
///     @naming(Naming.snakeCase) struct TaskOut { long companyId; string firstName; }   // "company_id", "first_name"
///     @naming(Naming.kebabCase) enum TaskType { task, taskInstance }                   // "task", "task-instance"
///     enum Photo { none, @wireName("on_issue") onIssue }                               // "none", "on_issue"
///
/// A field's own `@jsonKey` (or, for a database row, `@column`) wins over the struct's `@naming`. A policy is not
/// inherited: a nested struct declares its own. A type without `@naming` uses the project's default, `defaultNaming`
/// (`Naming.asIs` unless a version flag such as `AndaimeNamingSnakeCase` picks another).
module andaime.http.naming 2025;

@safe:

/// How identifiers become wire names.
enum Naming
{
    asIs,           /// the D identifier, unchanged
    snakeCase,      /// `firstName` -> `first_name`
    kebabCase,      /// `firstName` -> `first-name`
    camelCase,      /// `first_name` -> `firstName`
    upperSnakeCase, /// `firstName` -> `FIRST_NAME`
}

/// The naming policy of a struct (its fields) or an enum (its members): `@naming(Naming.snakeCase) struct T { ... }`.
struct naming
{
    Naming value;
}

/// The wire name of one enum member, when the policy cannot spell it: `@wireName("task-instance") taskInstance`.
struct wireName
{
    string value;
}

/// `ident` spelled with policy `n`. Words split at `_`, at a lower-case letter or digit followed by an upper-case one
/// (`firstName`), and before the last capital of a run followed by a lower-case letter (`HTTPServer` -> `http`,
/// `server`). Digits stay with the word before them (`line2`). A trailing `_` (D's escape for a keyword: `body_`) is
/// dropped by every policy except `asIs`.
string applyNaming(string ident, Naming n) pure nothrow
{
    if (n == Naming.asIs)
        return ident;
    while (ident.length > 1 && ident[$ - 1] == '_')
        ident = ident[0 .. $ - 1];

    immutable char sep = n == Naming.kebabCase ? '-' : '_';
    string r;
    size_t word = 0; // index of the current word
    bool inWord = false;
    bool wordStart = true;
    foreach (i, c; ident)
    {
        if (c == '_')
        {
            if (inWord)
                word++;
            inWord = false;
            wordStart = true;
            continue;
        }
        if (inWord && isUpper(c))
        {
            immutable prev = ident[i - 1];
            immutable next = i + 1 < ident.length ? ident[i + 1] : '\0';
            if (isLower(prev) || isDigit(prev) || (isUpper(prev) && isLower(next)))
            {
                word++;
                wordStart = true;
            }
        }
        if (wordStart && word > 0 && n != Naming.camelCase)
            r ~= sep;
        final switch (n)
        {
        case Naming.asIs:
            assert(0);
        case Naming.snakeCase:
        case Naming.kebabCase:
            r ~= toLower(c);
            break;
        case Naming.upperSnakeCase:
            r ~= toUpper(c);
            break;
        case Naming.camelCase:
            r ~= wordStart && word > 0 ? toUpper(c) : toLower(c);
            break;
        }
        inWord = true;
        wordStart = false;
    }
    return r;
}

// The project's default policy, for every struct and enum without its own `@naming`: one version flag in dub.sdl
// (`versions "AndaimeNamingSnakeCase"`), so domain types need no andaime attribute. Fixed at compile time: it costs nothing
// at run time and JSON, query and form binding, OpenAPI and `rowsAs` all follow it.
version (AndaimeNamingSnakeCase) private enum int snakeFlag = 1; else private enum int snakeFlag = 0;
version (AndaimeNamingKebabCase) private enum int kebabFlag = 1; else private enum int kebabFlag = 0;
version (AndaimeNamingCamelCase) private enum int camelFlag = 1; else private enum int camelFlag = 0;
version (AndaimeNamingUpperSnakeCase) private enum int upperSnakeFlag = 1; else private enum int upperSnakeFlag = 0;
static assert(snakeFlag + kebabFlag + camelFlag + upperSnakeFlag <= 1, "andaime: more than one AndaimeNaming* version "
    ~ "is set; keep one (AndaimeNamingSnakeCase, AndaimeNamingKebabCase, AndaimeNamingCamelCase or AndaimeNamingUpperSnakeCase)");

/// The policy of a struct or enum that has no `@naming`: `Naming.asIs`, or the one a version flag selects
/// (`AndaimeNamingSnakeCase`, `AndaimeNamingKebabCase`, `AndaimeNamingCamelCase`, `AndaimeNamingUpperSnakeCase`).
enum Naming defaultNaming = snakeFlag ? Naming.snakeCase : kebabFlag ? Naming.kebabCase
    : camelFlag ? Naming.camelCase : upperSnakeFlag ? Naming.upperSnakeCase : Naming.asIs;

/// The `@naming` policy of `T`, or `defaultNaming`.
template namingOf(T)
{
    static if (__traits(getAttributes, T).length == 0)
        enum Naming namingOf = defaultNaming;
    else
        enum Naming namingOf = () {
            Naming r = defaultNaming;
            static foreach (a; __traits(getAttributes, T))
                static if (is(typeof(a) == naming))
                    r = a.value;
            return r;
        }();
}

/// The wire name of member `m` of enum `E`: its `@wireName`, else `m` spelled with `E`'s `@naming`.
template enumWireName(E, string m) if (is(E == enum))
{
    static if (!enumRenamed!E)
        enum string enumWireName = m;
    else
        enum string enumWireName = () {
            string r = applyNaming(m, namingOf!E);
            static foreach (a; __traits(getAttributes, __traits(getMember, E, m)))
                static if (is(typeof(a) == wireName))
                    r = a.value;
            return r;
        }();
}

/// Every wire name of `E`, in declaration order. Two members with the same wire name, an empty one, or one with a quote,
/// a backslash or a control character are a compile error (so a wire name never needs escaping).
template enumWireNames(E) if (is(E == enum))
{
    static assert(enumWireClash!E.length == 0, enumWireClash!E);
    enum string[] enumWireNames = uncheckedWireNames!E;
}

private template uncheckedWireNames(E)
{
    static if (!enumRenamed!E)
        enum string[] uncheckedWireNames = [__traits(allMembers, E)];
    else
        enum string[] uncheckedWireNames = () {
            string[] r;
            static foreach (m; __traits(allMembers, E))
                r ~= enumWireName!(E, m);
            return r;
        }();
}

/// True when `E` has a `@naming` or a member with an attribute; otherwise every wire name is the member's name (an
/// identifier: unique, never empty, nothing to escape), and the templates above take a path without CTFE.
private template enumRenamed(E)
{
    enum bool enumRenamed = () {
        bool r = namingOf!E != Naming.asIs;
        static foreach (m; __traits(allMembers, E))
            r |= __traits(getAttributes, __traits(getMember, E, m)).length > 0;
        return r;
    }();
}

private template enumWireClash(E)
{
    static if (!enumRenamed!E)
        enum string enumWireClash = "";
    else
        enum string enumWireClash = wireNamesError(E.stringof, [__traits(allMembers, E)], uncheckedWireNames!E);
}

/// The first problem with the wire names `wires` of the members `names` of enum `ename`, or "".
private string wireNamesError(string ename, const string[] names, const string[] wires) pure
{
    foreach (i; 0 .. wires.length)
    {
        if (wires[i].length == 0)
            return "andaime: enum " ~ ename ~ ": member '" ~ names[i] ~ "' has an empty wire name";
        foreach (char c; wires[i])
            if (c == '"' || c == '\\' || c < 0x20 || c == 0x7f)
                return "andaime: enum " ~ ename ~ ": the wire name of '" ~ names[i]
                    ~ "' has a quote, a backslash or a control character";
        foreach (j; 0 .. i)
            if (wires[i] == wires[j])
                return "andaime: enum " ~ ename ~ ": members '" ~ names[j] ~ "' and '" ~ names[i]
                    ~ "' have the same wire name '" ~ wires[i] ~ "' (give one a @wireName)";
    }
    return "";
}

/// Text -> enum, by wire name. False when `s` is no wire name of `E`.
bool parseEnumWire(E)(scope const(char)[] s, out E v) pure nothrow @nogc if (is(E == enum))
{
    static assert(enumWireClash!E.length == 0, enumWireClash!E);
    static foreach (m; __traits(allMembers, E))
        if (s == enumWireName!(E, m))
        {
            v = __traits(getMember, E, m);
            return true;
        }
    return false;
}

/// Enum -> its wire name, or null for a value that is no member (a cast).
string enumToWire(E)(E v) pure nothrow @nogc if (is(E == enum))
{
    static assert(enumWireClash!E.length == 0, enumWireClash!E);
    static foreach (m; __traits(allMembers, E))
        if (v == __traits(getMember, E, m))
            return enumWireName!(E, m);
    return null;
}

private bool isUpper(char c) pure nothrow @nogc => c >= 'A' && c <= 'Z';
private bool isLower(char c) pure nothrow @nogc => c >= 'a' && c <= 'z';
private bool isDigit(char c) pure nothrow @nogc => c >= '0' && c <= '9';
private char toLower(char c) pure nothrow @nogc => isUpper(c) ? cast(char)(c + 32) : c;
private char toUpper(char c) pure nothrow @nogc => isLower(c) ? cast(char)(c - 32) : c;

unittest
{
    static assert(applyNaming("firstName", Naming.snakeCase) == "first_name");
    static assert(applyNaming("firstName", Naming.asIs) == "firstName");
    static assert(applyNaming("id", Naming.snakeCase) == "id");
    static assert(applyNaming("userID", Naming.snakeCase) == "user_id");
    static assert(applyNaming("HTTPServer", Naming.snakeCase) == "http_server");
    static assert(applyNaming("parseHTTPRequest", Naming.snakeCase) == "parse_http_request");
    static assert(applyNaming("line2", Naming.snakeCase) == "line2");
    static assert(applyNaming("md5Hash", Naming.snakeCase) == "md5_hash");
    static assert(applyNaming("body_", Naming.snakeCase) == "body");
    static assert(applyNaming("taskInstance", Naming.kebabCase) == "task-instance");
    static assert(applyNaming("taskInstance", Naming.upperSnakeCase) == "TASK_INSTANCE");
    static assert(applyNaming("first_name", Naming.camelCase) == "firstName");
    static assert(applyNaming("FirstName", Naming.camelCase) == "firstName");
    static assert(applyNaming("userID", Naming.camelCase) == "userId");
    static assert(applyNaming("already_snake", Naming.snakeCase) == "already_snake");
    static assert(applyNaming("_private", Naming.snakeCase) == "private");
}

unittest
{
    @naming(Naming.kebabCase) enum TaskType { task, taskInstance, @wireName("wf") workflowInstance }
    static assert(enumWireNames!TaskType == ["task", "task-instance", "wf"]);
    TaskType t;
    assert(parseEnumWire("task-instance", t) && t == TaskType.taskInstance);
    assert(!parseEnumWire("taskInstance", t));
    assert(enumToWire(TaskType.workflowInstance) == "wf");
    assert(enumToWire(cast(TaskType) 42) is null);

    enum Plain { a, bC }
    static assert(enumWireNames!Plain == ["a", applyNaming("bC", defaultNaming)]); // the project's default

    enum Clash { a, @wireName("a") b }
    static assert(enumWireClash!Clash == "andaime: enum Clash: members 'a' and 'b' have the same wire name 'a' (give one a @wireName)");
}
