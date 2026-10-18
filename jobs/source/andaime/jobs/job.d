/// The job contract: UDAs, `perform`, and a JSON payload. One `jobError` line, asserted by `JobSet`.
module andaime.jobs.job 2025;

@safe:

import core.time : Duration;
version (unittest)
    import core.time : minutes, seconds;
import andaime.http.buffer : ByteBuffer;
import andaime.http.texttype : isTextType;
import andaime.jobs.cron : cronError;
public import andaime.web.dto : FieldErrors;
import andaime.web.dto : jsonIgnore;
import andaime.web.json : decodeJson, writeJson;
import andaime.web.params : Optional, isCharType;

// =====================================================================
// UDAs
// =====================================================================

/// How long a failed attempt waits. `exponential` is `min(6 hours, 1 second * 2^^(attempt - 1))`, no jitter.
/// `JobContext.attempt` is 1-based. Without `@Retry` the single failure is discarded and this value is unused.
enum BackoffStrategy
{
    exponential,
}

/// Queue name. Required on the job struct. The stable job name is `jobName` (`fullyQualifiedName`), not this string.
struct Job
{
    string queue;
}

/// Attempts, counting the first run. `maxAttempts` must be >= 1.
/// Without this UDA the job runs once and a failure is discarded.
struct Retry
{
    int maxAttempts;
    BackoffStrategy backoff;
}

/// At most one enqueue of the same payload per window of `period` (must be positive).
/// The store owns the key (an FNV of the canonical JSON) and the window slot.
/// Inserting again in that window does nothing.
struct UniqueJob
{
    Duration period;
}

/// Run `perform` through `offload`. Outside a fiber the pool runs the work inline.
enum Offload;

/// Five-field cron expression. `cronError` checks the shape; the scheduler computes the next slot.
struct Cron
{
    string expr;
}

/// Enqueue on a multiple of `period` (must be positive). The scheduler owns the slot.
struct Every
{
    Duration period;
}

/// What `perform` knows about this run. The runner fills it. `attempt` is 1-based.
struct JobContext
{
    long id;
    int attempt;
    int maxAttempts;
    string queue;
}

// =====================================================================
// Reading the UDAs
// =====================================================================

/// Stable name stored with the payload. Two structs with the same identifier in different modules do not collide.
enum string jobName(T) = __traits(fullyQualifiedName, T);

private struct JobAttrs
{
    string queue;
    int maxAttempts = 1;
    BackoffStrategy backoff = BackoffStrategy.exponential;
    Duration uniquePeriod;
    Duration everyPeriod;
    string cronExpr;
    bool offload;
}

private template jobAttrs(T)
{
    static if (!is(T == struct))
        enum JobAttrs jobAttrs = JobAttrs.init;
    else
        enum JobAttrs jobAttrs = () {
            JobAttrs m;
            static foreach (a; __traits(getAttributes, T))
            {
                static if (is(typeof(a) == Job))
                    m.queue = a.queue;
                else static if (is(typeof(a) == Retry))
                {
                    m.maxAttempts = a.maxAttempts;
                    m.backoff = a.backoff;
                }
                else static if (is(typeof(a) == UniqueJob))
                    m.uniquePeriod = a.period;
                else static if (is(typeof(a) == Every))
                    m.everyPeriod = a.period;
                else static if (is(typeof(a) == Cron))
                    m.cronExpr = a.expr;
                else static if (is(a == Offload) || is(typeof(a) == Offload))
                    m.offload = true;
            }
            return m;
        }();
}

/// Queue from `@Job`, or `""` when the UDA is missing. Meaningful once `jobError!T` is empty.
enum string jobQueue(T) = jobAttrs!T.queue;

/// `maxAttempts` from `@Retry`, or 1 when the job has no `@Retry`.
enum int jobMaxAttempts(T) = jobAttrs!T.maxAttempts;

/// Backoff from `@Retry`, or `exponential` when the job has no `@Retry` (then unused).
enum BackoffStrategy jobBackoff(T) = jobAttrs!T.backoff;

/// `@UniqueJob` period, or `Duration.zero` when the job is not unique.
enum Duration jobUniquePeriod(T) = jobAttrs!T.uniquePeriod;

/// `@Every` period, or `Duration.zero` when the job has no `@Every`.
enum Duration jobEveryPeriod(T) = jobAttrs!T.everyPeriod;

/// `@Cron` expression, or `""` when the job has no `@Cron`.
enum string jobCronExpr(T) = jobAttrs!T.cronExpr;

/// True when the job struct carries `@Offload`.
enum bool jobOffload(T) = jobAttrs!T.offload;

// =====================================================================
// JSON shape (the same set `writeJson` accepts)
// =====================================================================

private string jobMsg(string fqn, string rest) pure @safe
{
    return "andaime.jobs: job '" ~ fqn ~ "' " ~ rest;
}

private template typeSeen(T, Seen...)
{
    enum bool typeSeen = () {
        bool r = false;
        static foreach (S; Seen)
            static if (is(T == S))
                r = true;
        return r;
    }();
}

/// `bool`, numbers (not `char`), `string` / `const(char)[]` / `char[n]`, or `enum`.
private enum bool isJsonLeaf(T) = is(T == bool) || is(T == enum)
    || (__traits(isIntegral, T) && !isCharType!T)
    || __traits(isFloating, T)
    || is(T : const(char)[]);

private template fieldHas(T, size_t i, alias A)
{
    enum bool fieldHas = () {
        static foreach (attr; __traits(getAttributes, T.tupleof[i]))
            static if (is(attr == A) || is(typeof(attr) == A))
                return true;
        return false;
    }();
}

private template jsonBad(T, string path)
{
    static if (path.length)
        enum string jsonBad = "field '" ~ path ~ "' has type '" ~ T.stringof ~ "'";
    else
        enum string jsonBad = "type '" ~ T.stringof ~ "'";
}

// Each `is(T == ...)` lives in its own template. On DMD 2.109 the aliases it introduces leak out of a
// `static if` and collide with the next test in the same template (`V` / `U` declared twice).
private struct NoJsonInner;

private template isRejectedRef(T)
{
    static if (is(T == class) || is(T == interface) || is(T == delegate) || is(T == function))
        enum bool isRejectedRef = true;
    else static if (is(T == P*, P))
        enum bool isRejectedRef = true;
    else
        enum bool isRejectedRef = false;
}

private template optionalInner(T)
{
    static if (is(T == Optional!U, U))
        alias optionalInner = U;
    else
        alias optionalInner = NoJsonInner;
}

private template stringMapValue(T)
{
    static if (is(T == V[K], V, K))
    {
        static if (is(K == string))
            alias stringMapValue = V;
        else
            alias stringMapValue = NoJsonInner;
    }
    else
        alias stringMapValue = NoJsonInner;
}

private template dynamicArrayElement(T)
{
    static if (is(T == E[], E))
        alias dynamicArrayElement = E;
    else
        alias dynamicArrayElement = NoJsonInner;
}

private template staticArrayElement(T)
{
    static if (is(T == E[n], E, size_t n))
        alias staticArrayElement = E;
    else
        alias staticArrayElement = NoJsonInner;
}

private template isNonStringMap(T)
{
    static if (is(T == V[K], V, K))
        enum bool isNonStringMap = !is(K == string);
    else
        enum bool isNonStringMap = false;
}

/// `""` when `writeJson` accepts `T`. Otherwise `field 'a.b' has type 'X'` for the first bad field.
private template jsonProblemOf(T, string path, Seen...)
{
    static if (typeSeen!(T, Seen))
        enum string jsonProblemOf = "";
    else static if (isRejectedRef!T)
        enum string jsonProblemOf = jsonBad!(T, path);
    else static if (isJsonLeaf!T)
        enum string jsonProblemOf = "";
    else static if (!is(optionalInner!T == NoJsonInner))
        enum string jsonProblemOf = jsonProblemOf!(optionalInner!T, path, Seen);
    else static if (!is(stringMapValue!T == NoJsonInner))
        enum string jsonProblemOf = jsonProblemOf!(stringMapValue!T, path, Seen);
    else static if (!is(dynamicArrayElement!T == NoJsonInner))
        enum string jsonProblemOf = jsonProblemOf!(dynamicArrayElement!T, path, Seen);
    else static if (!is(staticArrayElement!T == NoJsonInner))
        enum string jsonProblemOf = jsonProblemOf!(staticArrayElement!T, path, Seen);
    else static if (isNonStringMap!T)
        enum string jsonProblemOf = jsonBad!(T, path);
    else static if (isTextType!T)
        enum string jsonProblemOf = "";
    else static if (is(T == struct))
        enum string jsonProblemOf = jsonStructProblem!(T, path, Seen);
    else
        enum string jsonProblemOf = jsonBad!(T, path);
}

private template jsonStructProblem(T, string path, Seen...)
{
    enum string jsonStructProblem = () {
        static foreach (i; 0 .. T.tupleof.length)
        {{
            static if (!fieldHas!(T, i, jsonIgnore))
            {
                enum fname = __traits(identifier, T.tupleof[i]);
                enum npath = path.length == 0 ? fname : path ~ "." ~ fname;
                enum sub = jsonProblemOf!(typeof(T.tupleof[i]), npath, T, Seen);
                static if (sub.length)
                    return sub;
            }
        }}
        return "";
    }();
}

private enum string jsonNotSerializable = " which is not serializable to JSON. "
    ~ "Use bool, numbers, string, enum, arrays, string-keyed maps, structs or Optional!T.";

// =====================================================================
// perform
// =====================================================================

/// `@safe` or `@trusted`. `@system` is rejected with or without `-version=AndaimeStrictSafe`.
private template isCallableFromSafe(alias fn)
{
    enum bool isCallableFromSafe = () {
        bool r = false;
        static foreach (a; __traits(getFunctionAttributes, fn))
            if (a == "@safe" || a == "@trusted")
                r = true;
        return r;
    }();
}

private template paramHasRef(alias fn)
{
    enum bool paramHasRef = () {
        bool r = false;
        static foreach (s; __traits(getParameterStorageClasses, fn, 0))
            if (s == "ref")
                r = true;
        return r;
    }();
}

/// Non-static `void perform(ref JobContext)`.
private template isPerformMethod(alias fn)
{
    static if (is(typeof(fn) P == __parameters) && is(typeof(fn) R == return))
    {
        static if (P.length == 1)
        {
            static if (is(P[0] == JobContext) && is(R == void) && !__traits(isStaticFunction, fn))
                enum bool isPerformMethod = paramHasRef!fn;
            else
                enum bool isPerformMethod = false;
        }
        else
            enum bool isPerformMethod = false;
    }
    else
        enum bool isPerformMethod = false;
}

// =====================================================================
// jobError
// =====================================================================

private string invalidCron(string fqn, string ce) pure @safe
{
    enum head = "andaime.jobs: invalid @Cron: ";
    if (ce.length >= head.length && ce[0 .. head.length] == head)
        return jobMsg(fqn, "has an invalid @Cron: " ~ ce[head.length .. $]);
    return jobMsg(fqn, "has an invalid @Cron");
}

/// Why `T` cannot be a job, or `""`. One line, always starting with `andaime.jobs:`.
/// `@system perform` is rejected even when `-version=AndaimeStrictSafe` is off. `@trusted` is accepted.
template jobError(T)
{
    static if (!is(T == struct))
        enum string jobError = jobMsg(jobName!T, "must be a struct");
    else
        enum string jobError = jobStructError!T;
}

private template jobStructError(T)
if (is(T == struct))
{
    enum string jobStructError = () {
        enum fqn = jobName!T;

        int nJob = 0;
        string queue;
        static foreach (a; __traits(getAttributes, T))
        {
            static if (is(typeof(a) == Job))
            {
                nJob++;
                queue = a.queue;
            }
        }
        if (nJob == 0)
            return jobMsg(fqn, "is missing @Job(\"queue\"); every job names its queue");
        if (nJob > 1)
            return jobMsg(fqn, "has more than one @Job; a job has one queue");
        if (queue.length == 0)
            return jobMsg(fqn, "has an empty @Job queue name");

        enum prob = jsonProblemOf!(T, "");
        static if (prob.length)
            return jobMsg(fqn, prob ~ jsonNotSerializable);

        bool found = false;
        bool systemFn = false;
        static if (__traits(hasMember, T, "perform"))
        {
            static if (__traits(compiles, __traits(getOverloads, T, "perform")))
            {
                static foreach (fn; __traits(getOverloads, T, "perform"))
                {{
                    static if (isPerformMethod!fn)
                    {
                        found = true;
                        static if (!isCallableFromSafe!fn)
                            systemFn = true;
                    }
                }}
            }
        }
        if (!found)
            return jobMsg(fqn, "must define 'void perform(ref JobContext ctx) @safe'");
        if (systemFn)
            return jobMsg(fqn, "perform is @system; mark it @safe");

        int nRetry = 0;
        int nUnique = 0;
        int nEvery = 0;
        int nCron = 0;
        static foreach (a; __traits(getAttributes, T))
        {
            static if (is(typeof(a) == Retry))
            {
                nRetry++;
                if (a.maxAttempts < 1)
                    return jobMsg(fqn, "@Retry maxAttempts must be >= 1");
            }
            else static if (is(typeof(a) == UniqueJob))
            {
                nUnique++;
                if (a.period <= Duration.zero)
                    return jobMsg(fqn, "@UniqueJob period must be positive");
            }
            else static if (is(typeof(a) == Every))
            {
                nEvery++;
                if (a.period <= Duration.zero)
                    return jobMsg(fqn, "@Every period must be positive");
            }
            else static if (is(typeof(a) == Cron))
            {
                nCron++;
                string ce = cronError(a.expr);
                if (ce.length)
                    return invalidCron(fqn, ce);
            }
        }
        if (nRetry > 1)
            return jobMsg(fqn, "has more than one @Retry");
        if (nUnique > 1)
            return jobMsg(fqn, "has more than one @UniqueJob");
        if (nEvery > 1)
            return jobMsg(fqn, "has more than one @Every");
        if (nCron > 1)
            return jobMsg(fqn, "has more than one @Cron");
        return "";
    }();
}

private template jobSetProblem(Jobs...)
{
    enum string jobSetProblem = () {
        static foreach (J; Jobs)
        {{
            enum one = jobError!J;
            static if (one.length)
                return one;
        }}
        return "";
    }();
}

/// The jobs a program can run. Instantiating it static-asserts `jobError` for each one, so a bad payload
/// or `perform` is a single compiler error. `encode` / `decode` are the JSON payload (`writeJson` into a
/// `ByteBuffer`, then `decodeJson`).
struct JobSet(Jobs...)
{
    /// One static assert, so a bad job is a single compiler error (tests/compile_fail).
    private enum string problem = jobSetProblem!Jobs;
    static if (problem.length)
        static assert(0, problem);

    /// The job structs, in the order they were given.
    alias jobs = Jobs;

    private enum bool holds(J) = () {
        static foreach (A; Jobs)
            static if (is(A == J))
                return true;
        return false;
    }();

    /// `jobName!J` for a job in this set.
    template name(J)
    {
        static if (!holds!J)
            static assert(0, jobMsg(jobName!J, "is not in this JobSet"));
        else
            enum string name = jobName!J;
    }

    /// JSON object of `job`'s fields. Writes through `writeJson` into a `ByteBuffer` and copies the bytes out.
    static string encode(J)(ref const J job)
    {
        static if (!holds!J)
            static assert(0, jobMsg(jobName!J, "is not in this JobSet"));
        else
        {
            ByteBuffer buf;
            writeJson(buf, job);
            return buf.data.idup;
        }
    }

    /// Inverse of `encode`. False when `json` does not match `J`; `errs` gains the details, as `decodeJson` does.
    /// The caller clears `errs` before a reuse. `@jsonIgnore` fields are left as they stand on `job`.
    static bool decode(J)(const(char)[] json, ref J job, ref FieldErrors errs)
    {
        static if (!holds!J)
            static assert(0, jobMsg(jobName!J, "is not in this JobSet"));
        else
            return decodeJson(json, job, errs);
    }
}

// =====================================================================
// Unittest
// =====================================================================

version (unittest)
{
    private struct OkText
    {
        bool on;

        static bool fromString(scope const(char)[] text, out OkText v)
        {
            if (text != "ok")
                return false;
            v.on = true;
            return true;
        }

        void toString(scope void delegate(scope const(char)[]) @safe sink) const
        {
            sink("ok");
        }
    }

    private enum Kind { welcome, reset }

    private struct Address
    {
        string city;
    }

    @Job("mail")
    @Retry(5, BackoffStrategy.exponential)
    @Offload
    private struct SendMail
    {
        string to;
        int n;
        bool html;
        Kind kind;
        Optional!string name;
        int[] tags;
        Address ship;
        OkText tag;
        @jsonIgnore int secret = 7;
        void perform(ref JobContext ctx) {}
    }

    @Job("default")
    @Cron("*/5 * * * *")
    @Every(30.seconds)
    @UniqueJob(1.minutes)
    private struct Scheduled
    {
        void perform(ref JobContext ctx) @trusted {}
    }

    @Job("default")
    private struct PointerSample
    {
        int* userId;
        void perform(ref JobContext ctx) {}
    }

    @Job("default")
    private struct SystemSample
    {
        void perform(ref JobContext ctx) @system {}
    }

    @Job("default")
    private struct MissingSample
    {
        string to;
    }

    @Job("default")
    @Cron("1 2 3")
    private struct CronSample
    {
        void perform(ref JobContext ctx) {}
    }

    @Job("default")
    private struct DelegateSample
    {
        void delegate() hook;
        void perform(ref JobContext ctx) {}
    }

    @Job("default")
    private struct ClassSample
    {
        Object item;
        void perform(ref JobContext ctx) {}
    }

    private interface I
    {
        void ping();
    }

    @Job("default")
    private struct InterfaceSample
    {
        I item;
        void perform(ref JobContext ctx) {}
    }

    @Job("default")
    private struct MapKeySample
    {
        int[int] ids;
        void perform(ref JobContext ctx) {}
    }

    private struct Leaf
    {
        int* p;
    }

    @Job("default")
    private struct NestedPtr
    {
        Leaf[] items;
        void perform(ref JobContext ctx) {}
    }

    @Job("default")
    private struct OptPtr
    {
        Optional!(int*) bad;
        void perform(ref JobContext ctx) {}
    }

    @Job("default")
    private struct HiddenPtr
    {
        string name;
        @jsonIgnore int* raw;
        void perform(ref JobContext ctx) {}
    }

    @Job("default")
    private struct Numbers
    {
        byte b;
        short s;
        long l;
        float f;
        double d;
        int[string] scores;
        void perform(ref JobContext ctx) {}
    }

    @Job("default")
    private struct FixedSample
    {
        int[2] pair;
        char[4] code;
        void perform(ref JobContext ctx) {}
    }

    private struct Bare
    {
        void perform(ref JobContext ctx) {}
    }

    @Job("")
    private struct EmptyQueue
    {
        void perform(ref JobContext ctx) {}
    }

    @Job("q")
    @Job("r")
    private struct TwoQueues
    {
        void perform(ref JobContext ctx) {}
    }

    @Job("q")
    @Retry(0, BackoffStrategy.exponential)
    private struct ZeroRetry
    {
        void perform(ref JobContext ctx) {}
    }

    @Job("q")
    @UniqueJob(Duration.zero)
    private struct ZeroWindow
    {
        void perform(ref JobContext ctx) {}
    }

    @Job("q")
    @Every((-1).seconds)
    private struct NegativeEvery
    {
        void perform(ref JobContext ctx) {}
    }
}

unittest
{
    static assert(jobError!int == "andaime.jobs: job 'int' must be a struct");
    static assert(jobError!Bare == jobMsg(jobName!Bare, "is missing @Job(\"queue\"); every job names its queue"));
    static assert(jobError!EmptyQueue == jobMsg(jobName!EmptyQueue, "has an empty @Job queue name"));
    static assert(jobError!TwoQueues == jobMsg(jobName!TwoQueues, "has more than one @Job; a job has one queue"));
    static assert(jobError!ZeroRetry == jobMsg(jobName!ZeroRetry, "@Retry maxAttempts must be >= 1"));
    static assert(jobError!ZeroWindow == jobMsg(jobName!ZeroWindow, "@UniqueJob period must be positive"));
    static assert(jobError!NegativeEvery == jobMsg(jobName!NegativeEvery, "@Every period must be positive"));

    static assert(jobError!PointerSample == jobMsg(jobName!PointerSample,
        "field 'userId' has type 'int*'" ~ jsonNotSerializable));
    static assert(jobError!SystemSample == jobMsg(jobName!SystemSample, "perform is @system; mark it @safe"));
    static assert(jobError!MissingSample == jobMsg(jobName!MissingSample,
        "must define 'void perform(ref JobContext ctx) @safe'"));
    static assert(jobError!CronSample == jobMsg(jobName!CronSample,
        "has an invalid @Cron: expected 5 fields (minute hour day-of-month month day-of-week)"));
    static assert(jobError!DelegateSample == jobMsg(jobName!DelegateSample,
        "field 'hook' has type '" ~ typeof(DelegateSample.hook).stringof ~ "'" ~ jsonNotSerializable));
    static assert(jobError!ClassSample == jobMsg(jobName!ClassSample,
        "field 'item' has type 'Object'" ~ jsonNotSerializable));
    static assert(jobError!InterfaceSample == jobMsg(jobName!InterfaceSample,
        "field 'item' has type 'I'" ~ jsonNotSerializable));
    static assert(jobError!MapKeySample == jobMsg(jobName!MapKeySample,
        "field 'ids' has type 'int[int]'" ~ jsonNotSerializable));
    static assert(jobError!NestedPtr == jobMsg(jobName!NestedPtr,
        "field 'items.p' has type 'int*'" ~ jsonNotSerializable));
    static assert(jobError!OptPtr == jobMsg(jobName!OptPtr,
        "field 'bad' has type 'int*'" ~ jsonNotSerializable));

    static assert(jobError!SendMail == "");
    static assert(jobError!Scheduled == "");
    static assert(jobError!HiddenPtr == "");
    static assert(jobError!Numbers == "");
    static assert(jobError!FixedSample == "");

    static assert(jobQueue!SendMail == "mail");
    static assert(jobMaxAttempts!SendMail == 5);
    static assert(jobBackoff!SendMail == BackoffStrategy.exponential);
    static assert(jobOffload!SendMail);
    static assert(jobCronExpr!SendMail == "");
    static assert(jobEveryPeriod!SendMail == Duration.zero);
    static assert(jobUniquePeriod!SendMail == Duration.zero);
    static assert(jobName!SendMail == __traits(fullyQualifiedName, SendMail));

    static assert(jobQueue!Scheduled == "default");
    static assert(jobMaxAttempts!Scheduled == 1);
    static assert(!jobOffload!Scheduled);
    static assert(jobCronExpr!Scheduled == "*/5 * * * *");
    static assert(jobEveryPeriod!Scheduled == 30.seconds);
    static assert(jobUniquePeriod!Scheduled == 1.minutes);

    alias Mails = JobSet!SendMail;
    static assert(Mails.name!SendMail == jobName!SendMail);
    static assert(Mails.jobs.length == 1);
    alias None = JobSet!();
    static assert(None.jobs.length == 0);

    SendMail m;
    m.to = "a@b.c";
    m.n = 2;
    m.html = true;
    m.kind = Kind.welcome;
    m.name = Optional!string("Ana");
    m.tags = [1, 2];
    m.ship.city = "Recife";
    m.tag.on = true;
    m.secret = 9;
    string js = Mails.encode(m);
    assert(js == `{"to":"a@b.c","n":2,"html":true,"kind":"welcome","name":"Ana","tags":[1,2],"ship":{"city":"Recife"},"tag":"ok"}`, js);

    FieldErrors errs;
    SendMail back;
    assert(Mails.decode(js, back, errs), js);
    assert(back.to == "a@b.c" && back.n == 2 && back.html && back.kind == Kind.welcome);
    assert(back.name.has && back.name.get == "Ana");
    assert(back.tags == [1, 2] && back.ship.city == "Recife" && back.tag.on);
    assert(back.secret == 7);

    errs.clear();
    SendMail broken;
    assert(!Mails.decode(`{"to":`, broken, errs));
    assert(errs.any);

    HiddenPtr h;
    h.name = "n";
    assert(JobSet!HiddenPtr.encode(h) == `{"name":"n"}`);

    Numbers num;
    num.b = -1;
    num.s = 2;
    num.l = 3;
    num.f = 0.5f;
    num.d = 0.5;
    num.scores["a"] = 4;
    string njs = JobSet!Numbers.encode(num);
    assert(njs == `{"b":-1,"s":2,"l":3,"f":0.5,"d":0.5,"scores":{"a":4}}`, njs);
    Numbers numBack;
    errs.clear();
    assert(JobSet!Numbers.decode(njs, numBack, errs), njs);
    assert(numBack.b == -1 && numBack.s == 2 && numBack.l == 3);
    assert(numBack.f == 0.5f && numBack.d == 0.5);
    assert(numBack.scores["a"] == 4);

    // writeJson emits a static array as JSON and a char[n] as a string. decodeJson does not read those back.
    FixedSample fixed;
    fixed.pair = [8, 9];
    fixed.code = "abcd";
    assert(JobSet!FixedSample.encode(fixed) == `{"pair":[8,9],"code":"abcd"}`);
}
