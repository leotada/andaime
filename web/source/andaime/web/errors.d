/// One body format for every error andaime answers by itself: `App.errorBody` (see `ErrorInfo`), and a ready-made RFC
/// 9457 renderer, `problemDetails`.
module andaime.web.errors 2025;

@safe:

import andaime.http.fielderrors : ValidationErrors;
import andaime.http.naming : Naming, naming;
import andaime.http.types : statusText;
import andaime.values.optional : Optional;

/// What `App.errorBody`'s function receives: one error the app is about to answer.
struct ErrorInfo
{
    /// The status of the answer.
    int status;
    /// What went wrong, safe to show: an `HttpError`'s or a mapped exception's message, "not found", "method not
    /// allowed", the first validation error (`body.email: field required`), or "internal error" for an unexpected
    /// exception (whose message is only logged).
    string message;
    /// The exception behind it: a mapped exception as it was thrown (cast it to read its own fields, a `code` say), an
    /// `HttpError`, or the unexpected one behind a 500. Null for 404, 405 and validation errors.
    Exception exception;
    /// The validation errors of a 422 (empty otherwise). A view into the request: valid during the call only.
    ValidationErrors validation;
}

/// One line saying what is wrong with an `errorBody` function of type `F`, or "".
template errorBodyError(F)
{
    static if (__traits(isTemplate, F) || !is(F R == return))
        enum string errorBodyError = "andaime: errorBody takes a function (ref const ErrorInfo e) returning a struct, "
            ~ "with the parameter type declared: (ref const ErrorInfo e) => ApiError(e.message)";
    // (@system probes: a user's function may be @system, like every user callback)
    else static if (!__traits(compiles, (ref const ErrorInfo e) @system { F f; return f(e); }))
        enum string errorBodyError = "andaime: errorBody takes a function (ref const ErrorInfo e) returning a struct, not '"
            ~ F.stringof ~ "'";
    else static if (!is(R == struct))
        enum string errorBodyError = "andaime: errorBody: the function must return a struct (it is the JSON body of every "
            ~ "error), not '" ~ R.stringof ~ "'";
    else
        enum string errorBodyError = "";
}

/// One line saying what is wrong with `mapError!E(status, f)`'s `f` of type `F`, or "".
template mapBodyError(E, F)
{
    static if (__traits(isTemplate, F) || !is(F R == return))
        enum string mapBodyError = "andaime: mapError!" ~ E.stringof ~ " takes a function (" ~ E.stringof
            ~ " e) returning a struct, with the parameter type declared";
    else static if (!__traits(compiles, (E e) @system { F f; return f(e); }))
        enum string mapBodyError = "andaime: mapError!" ~ E.stringof ~ " takes a function (" ~ E.stringof
            ~ " e) returning a struct, not '" ~ F.stringof ~ "'";
    else static if (!is(R == struct))
        enum string mapBodyError = "andaime: mapError!" ~ E.stringof ~ ": the function must return a struct (the JSON "
            ~ "body), not '" ~ R.stringof ~ "'";
    else
        enum string mapBodyError = "";
}

/// The media type of RFC 9457 problem details.
enum string problemJson = "application/problem+json";

/// One invalid field in `ProblemDetails.errors`.
@naming(Naming.asIs)
struct ProblemField
{
    string location; /// "path", "query", "header", "cookie" or "body"
    string field;    /// the dotted path inside it (`items.1.code`); empty for the whole location
    string type;     /// machine-readable ("missing", "int_parsing")
    string message;
}

/// An RFC 9457 problem: `app.errorBody(&problemDetails, problemJson);`. A validation error carries an `errors` list
/// (an extension member, as the RFC allows).
@naming(Naming.asIs)
struct ProblemDetails
{
    string type = "about:blank";
    string title;
    int status;
    Optional!string detail;
    Optional!(ProblemField[]) errors;
}

/// `ErrorInfo` as `ProblemDetails`: `title` is the status's reason phrase, `detail` the message.
ProblemDetails problemDetails(ref const ErrorInfo e)
{
    ProblemDetails p;
    p.status = e.status;
    p.title = statusText(e.status);
    if (e.message.length)
        p.detail = Optional!string(e.message);
    if (e.validation.items.length)
    {
        ProblemField[] fs;
        foreach (ref f; e.validation.items)
            fs ~= ProblemField(f.location, f.dotted, f.type, f.message);
        p.errors = Optional!(ProblemField[])(fs);
    }
    return p;
}

/// The message of a 422 for `ErrorInfo`: the first error, `body.email: field required`.
string validationMessage(const ValidationErrors v)
{
    if (v.items.length == 0)
        return "validation error";
    auto e = v.items[0];
    auto where = e.dotted;
    return e.location ~ (where.length ? "." ~ where : "") ~ ": " ~ e.message;
}
