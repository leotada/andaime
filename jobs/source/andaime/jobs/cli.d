/// Process startup flags: `--role` and `--queues`.
///
/// `args[0]` is the program name and is ignored. The only flags are `--role=api|worker|all`
/// (default `api`) and `--queues=name:concurrency,...` (default `default:5`). `--role api` and
/// `--queues name:concurrency` (the value in the next argument) are the same flags. Anything else
/// throws. An application that has its own flags strips them before calling `parseStartup`, or
/// passes only these.
module andaime.jobs.cli;

@safe:

// =====================================================================
// What main asked for
// =====================================================================

/// Which process this binary is. `api` enqueues only. `worker` consumes only. `all` does both,
/// and the consumer runs on worker 0.
enum ProcessRole
{
    api,
    worker,
    all,
}

/// One queue the worker claims from, and how many fibers claim it at once.
/// The count is for the whole process: it is not multiplied by the number of cores.
struct QueueLimit
{
    string queue;
    int concurrency;
}

/// Parsed `--role` and `--queues`. `queues` has at least one entry.
struct Startup
{
    ProcessRole role = ProcessRole.api;
    QueueLimit[] queues;
}

package string roleText(ProcessRole role) pure nothrow @safe
{
    final switch (role)
    {
        case ProcessRole.api: return "api";
        case ProcessRole.worker: return "worker";
        case ProcessRole.all: return "all";
    }
}

/// Reads `--role` and `--queues` from `args`. `args[0]` is the program name.
/// Throws `Exception` whose message starts with `andaime.jobs:` on an unknown flag, a missing value,
/// a bad role, or a bad queue spec.
Startup parseStartup(string[] args) pure @safe
{
    Startup startup;
    startup.role = ProcessRole.api;
    bool sawRole = false;
    bool sawQueues = false;
    size_t i = args.length == 0 ? 0 : 1;
    while (i < args.length)
    {
        string tok = args[i];
        if (tok.length == 0 || tok[0] != '-')
            throw new Exception("andaime.jobs: unexpected argument '" ~ tok ~ "'");
        if (tok.length < 2 || tok[1] != '-')
            throw new Exception("andaime.jobs: unknown flag '" ~ tok ~ "'");

        string name = tok;
        string inlineValue;
        bool hasInline = false;
        foreach (k, char c; tok)
        {
            if (c == '=')
            {
                name = tok[0 .. k];
                inlineValue = tok[k + 1 .. $];
                hasInline = true;
                break;
            }
        }

        if (name == "--role")
        {
            if (sawRole)
                throw new Exception("andaime.jobs: --role given twice");
            string value = inlineValue;
            if (!hasInline)
            {
                if (i + 1 >= args.length || args[i + 1].length == 0 || args[i + 1][0] == '-')
                    throw new Exception("andaime.jobs: --role needs a value (api, worker or all)");
                i++;
                value = args[i];
            }
            startup.role = parseRole(value);
            sawRole = true;
        }
        else if (name == "--queues")
        {
            if (sawQueues)
                throw new Exception("andaime.jobs: --queues given twice");
            string value = inlineValue;
            if (!hasInline)
            {
                if (i + 1 >= args.length || args[i + 1].length == 0 || args[i + 1][0] == '-')
                    throw new Exception(
                        "andaime.jobs: --queues needs a value (name:concurrency, for example default:5)");
                i++;
                value = args[i];
            }
            startup.queues = parseQueues(value);
            sawQueues = true;
        }
        else
            throw new Exception("andaime.jobs: unknown flag '" ~ name ~ "'");
        i++;
    }
    if (!sawQueues)
        startup.queues = [QueueLimit("default", 5)];
    return startup;
}

private ProcessRole parseRole(string value) pure @safe
{
    if (value == "api")
        return ProcessRole.api;
    if (value == "worker")
        return ProcessRole.worker;
    if (value == "all")
        return ProcessRole.all;
    throw new Exception("andaime.jobs: --role must be api, worker or all, not '" ~ value ~ "'");
}

private QueueLimit[] parseQueues(string spec) pure @safe
{
    if (spec.length == 0)
        throw new Exception(
            "andaime.jobs: --queues needs a queue spec (name:concurrency, for example default:5)");
    QueueLimit[] found;
    size_t i = 0;
    while (i < spec.length)
    {
        size_t end = i;
        while (end < spec.length && spec[end] != ',')
            end++;
        if (end == i)
            throw new Exception("andaime.jobs: --queues has an empty entry");
        addQueue(found, spec[i .. end]);
        if (end == spec.length)
            break;
        i = end + 1;
        if (i == spec.length)
            throw new Exception("andaime.jobs: --queues has an empty entry");
    }
    return found;
}

private void addQueue(ref QueueLimit[] found, string part) pure @safe
{
    size_t colon = 0;
    int colons = 0;
    foreach (k, char c; part)
    {
        if (c == ':')
        {
            colon = k;
            colons++;
        }
    }
    if (colons != 1 || colon == 0)
        throw new Exception("andaime.jobs: --queues entry '" ~ part ~ "' is not name:concurrency");
    string name = part[0 .. colon];
    string num = part[colon + 1 .. $];
    foreach (char c; name)
    {
        if (c <= ' ')
            throw new Exception("andaime.jobs: --queues entry '" ~ part ~ "' is not name:concurrency");
    }
    int conc = parsePositiveInt(num);
    foreach (q; found)
    {
        if (q.queue == name)
            throw new Exception("andaime.jobs: --queues lists '" ~ name ~ "' twice");
    }
    found ~= QueueLimit(name, conc);
}

private int parsePositiveInt(string s) pure @safe
{
    if (s.length == 0)
        throw new Exception("andaime.jobs: --queues concurrency '" ~ s ~ "' is not a positive integer");
    int n = 0;
    foreach (char c; s)
    {
        if (c < '0' || c > '9')
            throw new Exception("andaime.jobs: --queues concurrency '" ~ s ~ "' is not a positive integer");
        immutable d = c - '0';
        if (n > (int.max - d) / 10)
            throw new Exception("andaime.jobs: --queues concurrency '" ~ s ~ "' is not a positive integer");
        n = n * 10 + d;
    }
    if (n < 1)
        throw new Exception("andaime.jobs: --queues concurrency '" ~ s ~ "' is not a positive integer");
    return n;
}

// =====================================================================
// Tests
// =====================================================================

version (unittest)
{
    private bool hasText(string s, string part) pure nothrow @safe
    {
        if (part.length > s.length)
            return false;
        if (part.length == 0)
            return true;
        foreach (size_t i; 0 .. s.length - part.length + 1)
            if (s[i .. i + part.length] == part)
                return true;
        return false;
    }

    private string fails(void delegate() @safe dg)
    {
        try
            dg();
        catch (Exception e)
        {
            assert(e.msg.length >= 10 && e.msg[0 .. 10] == "andaime.jobs:", e.msg);
            return e.msg;
        }
        assert(0, "expected andaime.jobs: exception");
    }
}

unittest
{
    auto bare = parseStartup(["prog"]);
    assert(bare.role == ProcessRole.api);
    assert(bare.queues.length == 1);
    assert(bare.queues[0] == QueueLimit("default", 5));
    assert(parseStartup(null).role == ProcessRole.api);
    assert(parseStartup([]).queues[0].concurrency == 5);

    // args[0] is the program name even when it looks like a flag.
    assert(parseStartup(["--role=worker"]).role == ProcessRole.api);

    auto worker = parseStartup(["prog", "--role=worker", "--queues=critical:10,default:5"]);
    assert(worker.role == ProcessRole.worker);
    assert(worker.queues.length == 2);
    assert(worker.queues[0] == QueueLimit("critical", 10));
    assert(worker.queues[1] == QueueLimit("default", 5));

    auto swapped = parseStartup(["prog", "--queues=only:1", "--role=all"]);
    assert(swapped.role == ProcessRole.all);
    assert(swapped.queues.length == 1);
    assert(swapped.queues[0] == QueueLimit("only", 1));

    auto spaced = parseStartup(["prog", "--role", "worker", "--queues", "critical:10,default:3"]);
    assert(spaced.role == ProcessRole.worker);
    assert(spaced.queues[0] == QueueLimit("critical", 10));
    assert(spaced.queues[1] == QueueLimit("default", 3));

    auto mixed = parseStartup(["prog", "--role=api", "--queues", "bulk:12"]);
    assert(mixed.role == ProcessRole.api);
    assert(mixed.queues.length == 1 && mixed.queues[0] == QueueLimit("bulk", 12));

    assert(parseStartup(["prog", "--queues=a:05"]).queues[0].concurrency == 5);
    assert(roleText(ProcessRole.worker) == "worker");
}

unittest
{
    string msg;

    msg = fails(() { parseStartup(["prog", "--role=nope"]); });
    assert(hasText(msg, "api, worker or all"), msg);

    msg = fails(() { parseStartup(["prog", "--role="]); });
    assert(hasText(msg, "not ''"), msg);

    msg = fails(() { parseStartup(["prog", "--role"]); });
    assert(hasText(msg, "needs a value"), msg);

    msg = fails(() { parseStartup(["prog", "--role", "--queues=default:1"]); });
    assert(hasText(msg, "needs a value"), msg);

    msg = fails(() { parseStartup(["prog", "--role=api", "--role=worker"]); });
    assert(hasText(msg, "given twice"), msg);

    msg = fails(() { parseStartup(["prog", "--queues="]); });
    assert(hasText(msg, "queue spec"), msg);

    msg = fails(() { parseStartup(["prog", "--queues"]); });
    assert(hasText(msg, "needs a value"), msg);

    msg = fails(() { parseStartup(["prog", "--queues=default"]); });
    assert(hasText(msg, "not name:concurrency"), msg);

    msg = fails(() { parseStartup(["prog", "--queues=:5"]); });
    assert(hasText(msg, "not name:concurrency"), msg);

    msg = fails(() { parseStartup(["prog", "--queues=default:0"]); });
    assert(hasText(msg, "not a positive integer"), msg);

    msg = fails(() { parseStartup(["prog", "--queues=default:-1"]); });
    assert(hasText(msg, "not a positive integer"), msg);

    msg = fails(() { parseStartup(["prog", "--queues=default:x"]); });
    assert(hasText(msg, "not a positive integer"), msg);

    msg = fails(() { parseStartup(["prog", "--queues=default:2147483648"]); });
    assert(hasText(msg, "not a positive integer"), msg);

    msg = fails(() { parseStartup(["prog", "--queues=a:1,"]); });
    assert(hasText(msg, "empty entry"), msg);

    msg = fails(() { parseStartup(["prog", "--queues=a:1,,b:2"]); });
    assert(hasText(msg, "empty entry"), msg);

    msg = fails(() { parseStartup(["prog", "--queues=a:1,a:2"]); });
    assert(hasText(msg, "lists 'a' twice"), msg);

    msg = fails(() { parseStartup(["prog", "--queues=a:1,b:c:2"]); });
    assert(hasText(msg, "not name:concurrency"), msg);

    msg = fails(() { parseStartup(["prog", "--help"]); });
    assert(hasText(msg, "unknown flag '--help'"), msg);

    msg = fails(() { parseStartup(["prog", "--role=api", "--bogus=1"]); });
    assert(hasText(msg, "unknown flag '--bogus'"), msg);

    msg = fails(() { parseStartup(["prog", "-v"]); });
    assert(hasText(msg, "unknown flag '-v'"), msg);

    msg = fails(() { parseStartup(["prog", "extra"]); });
    assert(hasText(msg, "unexpected argument 'extra'"), msg);

    msg = fails(() { parseStartup(["prog", "--queues=has space:1"]); });
    assert(hasText(msg, "not name:concurrency"), msg);
}
