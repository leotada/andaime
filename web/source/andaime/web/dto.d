/// DTO UDAs and the validation error accumulator (FastAPI format).
module andaime.web.dto 2025;

@safe:

import andaime.http.utf8 : codePoints;
import andaime.http.patchfield : isPatchField;
import andaime.http.naming : applyNaming, namingOf, naming, Naming, defaultNaming;
public import andaime.web.numtext : ctNum, numText;

/// Field name in the JSON when it differs from the D name: `@jsonKey("user_name") string userName;`
struct jsonKey { string name; }
/// Name of the struct's schema in the OpenAPI document: `@schemaName("UserOut") struct User { ... }`.
struct schemaName { string name; }
/// Optional field in the JSON (absent => keeps the initial value).
enum optional;
/// Field never read from or written to JSON.
enum jsonIgnore;
/// An empty `Optional` is left out of the JSON object instead of written as `null`. On a field, it applies to that field;
/// on a struct, to every `Optional` field of it. OpenAPI then drops `nullable` from the field (it is never null).
enum omitIfAbsent;
/// Minimum string/array length.
struct minLength { size_t value; }
/// Maximum string/array length.
struct maxLength { size_t value; }
/// Closed range for numbers: `@inRange(0, 150) int age;`
struct inRange { double min; double max; }

// The error accumulator lives in andaime:http (JsonValue reads with it); this module keeps its old names.
public import andaime.http.fielderrors;

/// true if an empty `Optional` member `i` of T is left out of its JSON object (`@omitIfAbsent` on the field or on T).
template omitsAbsent(T, size_t i)
{
    enum omitsAbsent = () {
        bool r;
        static foreach (attr; __traits(getAttributes, T.tupleof[i]))
            static if (is(attr == omitIfAbsent))
                r = true;
        static foreach (attr; __traits(getAttributes, T))
            static if (is(attr == omitIfAbsent))
                r = true;
        return r;
    }();
}

/// true if member `i` of T carries the UDA `A` (type or enum).
template hasUda(T, size_t i, alias A)
{
    enum hasUda = () {
        bool r;
        static foreach (attr; __traits(getAttributes, T.tupleof[i]))
            static if (is(attr == A) || is(typeof(attr) == A))
                r = true;
        return r;
    }();
}

/// JSON key of field `i` of T: its `@jsonKey`, else its name spelled with T's `@naming` (`andaime.http.naming`). Also
/// the name of the field in `Query!T`, `Form!T` and the OpenAPI document.
template jsonKeyOf(T, size_t i)
{
    // (the common case, no attribute and no policy, costs no CTFE: this runs for every field of every DTO)
    static if (__traits(getAttributes, T.tupleof[i]).length == 0)
    {
        static if (namingOf!T == Naming.asIs)
            enum jsonKeyOf = __traits(identifier, T.tupleof[i]);
        else
            enum jsonKeyOf = applyNaming(__traits(identifier, T.tupleof[i]), namingOf!T);
    }
    else
    {
        enum jsonKeyOf = () {
            string r = applyNaming(__traits(identifier, T.tupleof[i]), namingOf!T);
            static foreach (attr; __traits(getAttributes, T.tupleof[i]))
                static if (is(typeof(attr) == jsonKey))
                    r = attr.name;
            return r;
        }();
        static assert(!fieldHasNaming!(T, i), "andaime: @naming goes on the struct, not on field '"
            ~ __traits(identifier, T.tupleof[i]) ~ "' of " ~ T.stringof ~ " (use @jsonKey for one field)");
    }
}

private template fieldHasNaming(T, size_t i)
{
    enum fieldHasNaming = () {
        bool r;
        static foreach (attr; __traits(getAttributes, T.tupleof[i]))
            static if (is(typeof(attr) == naming))
                r = true;
        return r;
    }();
}

private enum string strShort(size_t n) = "expected at least " ~ ctNum(n) ~ " characters";
private enum string strLong(size_t n) = "expected at most " ~ ctNum(n) ~ " characters";
private enum string arrShort(size_t n) = "expected at least " ~ ctNum(n) ~ " items";
private enum string arrLong(size_t n) = "expected at most " ~ ctNum(n) ~ " items";
private enum string geMsg(double v) = "must be >= " ~ numText(v);
private enum string leMsg(double v) = "must be <= " ~ numText(v);

/// Applies the validation UDAs of field `i` to the already-decoded value. Strings are measured in code points (what
/// JSON Schema's minLength/maxLength mean and what the OpenAPI document promises), arrays in elements.
void validateField(T, size_t i, V)(ref const V value, ref FieldErrors errs, ref const FieldPath path)
{
    // a PatchField is checked only when it carries a value (absent and null pass)
    static if (isPatchField!V)
    {
        if (value.hasValue)
            validateField!(T, i)(value.value, errs, path);
    }
    else static foreach (attr; __traits(getAttributes, T.tupleof[i]))
    {
        static if (is(typeof(attr) == minLength))
        {
            static assert(__traits(compiles, value.length),
                "andaime: @minLength only applies to string or array (field '" ~ __traits(identifier, T.tupleof[i]) ~ "')");
            static if (is(V : const(char)[]))
            {
                if (codePoints(value) < attr.value)
                    errs.addPath(path, "string_too_short", strShort!(attr.value), FieldParams.ofLimit(attr.value));
            }
            else if (value.length < attr.value)
                errs.addPath(path, "too_short", arrShort!(attr.value), FieldParams.ofLimit(attr.value));
        }
        else static if (is(typeof(attr) == maxLength))
        {
            static assert(__traits(compiles, value.length),
                "andaime: @maxLength only applies to string or array (field '" ~ __traits(identifier, T.tupleof[i]) ~ "')");
            static if (is(V : const(char)[]))
            {
                if (codePoints(value) > attr.value)
                    errs.addPath(path, "string_too_long", strLong!(attr.value), FieldParams.ofLimit(attr.value));
            }
            else if (value.length > attr.value)
                errs.addPath(path, "too_long", arrLong!(attr.value), FieldParams.ofLimit(attr.value));
        }
        else static if (is(typeof(attr) == inRange))
        {
            static assert(__traits(isArithmetic, V),
                "andaime: @inRange only applies to numbers (field '" ~ __traits(identifier, T.tupleof[i]) ~ "')");
            if (value < attr.min)
                errs.addPath(path, "greater_than_equal", geMsg!(attr.min), FieldParams.ofBound(attr.min));
            else if (value > attr.max)
                errs.addPath(path, "less_than_equal", leMsg!(attr.max), FieldParams.ofBound(attr.max));
        }
    }
}

unittest
{
    @naming(Naming.snakeCase) struct S { string firstName; @jsonKey("ID") long userId; string body_; }
    static assert(jsonKeyOf!(S, 0) == "first_name" && jsonKeyOf!(S, 1) == "ID" && jsonKeyOf!(S, 2) == "body");
    struct Plain { string firstName; }
    static assert(jsonKeyOf!(Plain, 0) == applyNaming("firstName", defaultNaming)); // the project's default
    struct Misplaced { @naming(Naming.snakeCase) string firstName; }
    static assert(fieldHasNaming!(Misplaced, 0) && !__traits(compiles, jsonKeyOf!(Misplaced, 0)));
}

unittest
{
    FieldErrors errs;
    FieldPath p;
    p.pushKey("items");
    p.pushIndex(12);
    p.pushKey("a\"b\x01");
    errs.addPath(p, "missing", "Field required");
    errs.add("query", "limit", "missing", "Field required");
    errs.add("body", "", "json_invalid", "invalid JSON at byte 3");
    auto v = errs.view;
    assert(v.items.length == 3 && v.dropped == 0);
    assert(v.items[0].source == ErrorSource.jsonBody && v.items[1].source == ErrorSource.query);
    assert(v.items[0].path == [LocPart("items"), LocPart(null, 12, true), LocPart("a\"b\x01")]);
    assert(v.items[0].dotted == "items.12.a\"b\x01");
    assert(v.items[1].dotted == "limit" && v.items[2].path.length == 0 && v.items[2].dotted == "");
    assert(v.has(ErrorSource.query) && !v.has(ErrorSource.path));
}
