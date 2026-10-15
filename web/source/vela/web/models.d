/// `Query!T` and `Form!T`: a struct bound from a query string or a form body, field by field, by name.
/// `Form!T` reads `application/x-www-form-urlencoded` or `multipart/form-data`. A field of type `UploadedFile` (or
/// `Optional!UploadedFile`, or `UploadedFile[]`) is a file part and the body must be multipart.
///
///     struct Filters { string q; @jsonKey("page_size") int pageSize = 20; Optional!Sort sort; string[] tag; }
///     Page list(Query!Filters f) { ... f.pageSize ... }
///
/// Rules:
///  - the external name of a field is its `@jsonKey`, else its name;
///  - a field is optional if it is an `Optional!X`, a list (`string[]`, `UploadedFile[]`), marked `@optional`, or has
///    an initializer that is not the type's default (`int pageSize = 20`); anything else is required (`missing`);
///  - a scalar takes the first value of its key, a list takes every value;
///  - urlencoded text is percent-decoded (`+` is a space); multipart text is raw bytes, not percent-decoded;
///  - fields are numbers, bool, enums, text, text types (`vela.http.texttype`), `Optional`/lists of those, or (on a
///    form) `UploadedFile`;
///  - `@minLength` / `@maxLength` on one `UploadedFile` count bytes; on a list they count items.
module vela.web.models;

@safe:

import vela.http.multipart : FormCoding, FormContentType, MultipartPart, classifyFormContentType, parseMultipart;
import vela.http.types : QueryValues;
import vela.http.utf8 : validUtf8;
import vela.web.context : Context;
import vela.web.convert : percentDecode, parseScalarText, parseErrorType, parseErrorMsg;
import vela.web.dto;
import vela.web.params : Optional, HttpError, isScalar, isScalarList;

/// A struct bound from the query string.
struct Query(T)
{
    T value;
    alias value this;
}

/// A struct bound from a form body (`application/x-www-form-urlencoded`, or `multipart/form-data` when it has files).
struct Form(T)
{
    T value;
    alias value this;
}

/// One file part of a multipart body. `filename` and `contentType` are copies (`contentType` is empty when the part
/// sent none). `bytes` is a view into the request buffer: copy it (`.idup`) to keep it past the request. `filename` is
/// the client's name, not a path.
struct UploadedFile
{
    string filename;
    string contentType;
    const(ubyte)[] bytes;
}

private enum string scalarFieldRule = "fields must be scalars (int, string, enum, bool...), "
    ~ "text types, Optional of those, or lists of scalars";
private enum string formFieldRule = "fields must be scalars (int, string, enum, bool...), "
    ~ "text types, Optional of those, lists of scalars, or UploadedFile";

enum isUploadedFile(T) = is(T == UploadedFile);
enum isFileField(T) = isUploadedFile!T || is(T == UploadedFile[]) || is(T == Optional!UploadedFile);

/// True when `Form!T` has a file field, so the body must be multipart.
template formHasFiles(T)
{
    enum formHasFiles = () {
        static if (!is(T == struct))
            return false;
        else
        {
            bool any;
            static foreach (i; 0 .. T.tupleof.length)
                static if (!hasUda!(T, i, jsonIgnore) && isFileField!(typeof(T.tupleof[i])))
                    any = true;
            return any;
        }
    }();
}

/// Why `T` cannot be a `Query!T` or `Form!T`: "" when it can. One line, for `handlerError`.
/// `asForm` allows `UploadedFile` fields, which a query model cannot hold.
string modelError(T, bool asForm = false)()
{
    static if (!is(T == struct))
        return "'" ~ T.stringof ~ "' is not a struct";
    else
    {
        string e;
        static foreach (i; 0 .. T.tupleof.length)
        {
            static if (!hasUda!(T, i, jsonIgnore))
            {{
                alias F = typeof(T.tupleof[i]);
                enum fname = __traits(identifier, T.tupleof[i]);
                static if (isFileField!F)
                {
                    static if (!asForm)
                    {
                        if (e.length == 0)
                            e = "field '" ~ fname ~ "' of " ~ T.stringof ~ " is " ~ F.stringof ~ "; " ~ scalarFieldRule;
                    }
                    else
                    {
                        static foreach (attr; __traits(getAttributes, T.tupleof[i]))
                            static if (is(typeof(attr) == inRange))
                                if (e.length == 0)
                                    e = "field '" ~ fname ~ "' of " ~ T.stringof
                                        ~ ": @inRange does not apply to UploadedFile";
                    }
                }
                else static if (!(isScalar!F || isScalarList!F || isOptionalScalar!F))
                {
                    if (e.length == 0)
                        e = "field '" ~ fname ~ "' of " ~ T.stringof ~ " is " ~ F.stringof ~ "; "
                            ~ (asForm ? formFieldRule : scalarFieldRule);
                }
            }}
        }
        return e;
    }
}

enum isOptionalScalar(F) = is(F == Optional!U, U) && isScalar!U;
enum isQueryModel(T) = is(T == Query!U, U);
enum isFormModel(T) = is(T == Form!U, U);

/// A scalar field is optional when it has a non-default initializer or `@optional` (lists and Optionals always are).
template modelFieldOptional(T, size_t i)
{
    alias F = typeof(T.tupleof[i]);
    enum modelFieldOptional = isScalarList!F || isOptionalScalar!F || isOptionalField!(T, i);
}

/// Binds `dest` from `source` (a query string or a form body). Errors go to `ctx.errors` with `location` ("query"/"body").
/// Returns false if any field failed.
bool bindModel(T)(Context ctx, string location, const(char)[] source, ref T dest)
{
    immutable before = ctx.errors.count + ctx.errors.dropped;
    FieldPath path;
    path.location = location;
    path.source = location == "query" ? ErrorSource.query : ErrorSource.form;
    static foreach (i; 0 .. T.tupleof.length)
    {
        static if (!hasUda!(T, i, jsonIgnore))
        {{
            alias F = typeof(T.tupleof[i]);
            enum name = jsonKeyOf!(T, i);
            immutable mark = path.pushKey(name);
            static if (isScalarList!F)
            {
                alias E = typeof(dest.tupleof[i][0]);
                size_t n;
                bool any;
                foreach (raw; QueryValues(source, name))
                {
                    any = true;
                    E e;
                    immutable m2 = path.pushIndex(n++);
                    if (readOne(path, ctx, raw, e))
                        dest.tupleof[i] ~= e;
                    path.pop(m2);
                }
                if (any)
                    validateField!(T, i)(dest.tupleof[i], ctx.errors, path);
            }
            else static if (isOptionalScalar!F)
            {
                alias U = typeof(dest.tupleof[i].get());
                foreach (raw; QueryValues(source, name))
                {
                    U e;
                    if (readOne(path, ctx, raw, e))
                    {
                        dest.tupleof[i] = F(e);
                        validateField!(T, i)(e, ctx.errors, path);
                    }
                    break; // the first value
                }
            }
            else
            {
                bool seen;
                foreach (raw; QueryValues(source, name))
                {
                    seen = true;
                    F e;
                    if (readOne(path, ctx, raw, e))
                    {
                        dest.tupleof[i] = e;
                        validateField!(T, i)(e, ctx.errors, path);
                    }
                    break;
                }
                static if (!isOptionalField!(T, i))
                    if (!seen)
                        ctx.errors.addPath(path, "missing", "Field required");
            }
            path.pop(mark);
        }}
    }
    return ctx.errors.count + ctx.errors.dropped == before;
}

/// A scalar field is optional when it has a non-default initializer or `@optional`.
template isOptionalField(T, size_t i)
{
    enum isOptionalField = hasUda!(T, i, optional) || () {
        alias F = typeof(T.tupleof[i]);
        static if (is(typeof(T.init.tupleof[i] != F.init)))
            return T.init.tupleof[i] != F.init;
        else
            return false;
    }();
}

private bool readOne(F)(ref const FieldPath path, Context ctx, const(char)[] raw, ref F dest)
{
    const(char)[] text;
    if (!percentDecode(raw, true, text))
    {
        ctx.errors.addPath(path, "percent_encoding", "invalid percent-encoding");
        return false;
    }
    static if (is(F == string) || is(F == const(char)[]))
    {
        if (!validUtf8(text))
        {
            ctx.errors.addPath(path, "string_unicode", "invalid UTF-8");
            return false;
        }
    }
    if (!parseScalarText(text, dest))
    {
        ctx.errors.addPath(path, parseErrorType!F, parseErrorMsg!F);
        return false;
    }
    return true;
}

private enum string urlOrMultipart = "expected Content-Type: application/x-www-form-urlencoded or multipart/form-data";
private enum string multipartOnly = "expected Content-Type: multipart/form-data";
private enum string badCharset = "unsupported charset in multipart body";

/// Binds a form body. Urlencoded text is percent-decoded. Multipart text is the raw part bytes. A form with a file
/// field accepts only `multipart/form-data`.
void bindFormBody(T)(Context ctx, ref T dest)
{
    FormContentType ct;
    string error;
    classifyFormContentType(ctx.request.header("content-type"), ct, error);
    if (error.length)
        throw new HttpError(400, error);
    static if (formHasFiles!T)
    {
        if (ct.coding != FormCoding.multipart)
            throw new HttpError(415, multipartOnly);
    }
    else if (ct.coding == FormCoding.urlEncoded)
    {
        bindModel(ctx, "body", cast(const(char)[]) ctx.request.body, dest);
        return;
    }
    else if (ct.coding != FormCoding.multipart)
        throw new HttpError(415, urlOrMultipart);

    MultipartPart[] parts;
    error = parseMultipart(ctx.request.body, ct.boundary, parts);
    if (error.length)
        throw new HttpError(400, error);
    bindMultipart(ctx, parts, dest);
}

private void bindMultipart(T)(Context ctx, MultipartPart[] parts, ref T dest)
{
    FieldPath path;
    path.location = "body";
    path.source = ErrorSource.form;
    static foreach (i; 0 .. T.tupleof.length)
    {
        static if (!hasUda!(T, i, jsonIgnore))
        {{
            alias F = typeof(dest.tupleof[i]);
            enum name = jsonKeyOf!(T, i);
            immutable mark = path.pushKey(name);
            static if (is(F == UploadedFile[]))
            {
                size_t n;
                bool any;
                foreach (ref part; parts)
                {
                    if (part.name != name)
                        continue;
                    any = true;
                    immutable m2 = path.pushIndex(n++);
                    dest.tupleof[i] ~= uploadOf(part);
                    path.pop(m2);
                }
                if (any)
                    validateField!(T, i)(dest.tupleof[i], ctx.errors, path);
            }
            else static if (is(F == Optional!UploadedFile))
            {
                foreach (ref part; parts)
                {
                    if (part.name != name)
                        continue;
                    auto file = uploadOf(part);
                    checkFileBounds!(T, i)(file.bytes, ctx, path);
                    dest.tupleof[i] = F(file);
                    break;
                }
            }
            else static if (is(F == UploadedFile))
            {
                bool seen;
                foreach (ref part; parts)
                {
                    if (part.name != name)
                        continue;
                    seen = true;
                    auto file = uploadOf(part);
                    checkFileBounds!(T, i)(file.bytes, ctx, path);
                    dest.tupleof[i] = file;
                    break;
                }
                static if (!isOptionalField!(T, i))
                    if (!seen)
                        ctx.errors.addPath(path, "missing", "Field required");
            }
            else static if (isScalarList!F)
            {
                alias E = typeof(dest.tupleof[i][0]);
                size_t n;
                bool any;
                foreach (ref part; parts)
                {
                    if (part.name != name)
                        continue;
                    any = true;
                    E e;
                    immutable m2 = path.pushIndex(n++);
                    if (readPartText(path, ctx, part, e))
                        dest.tupleof[i] ~= e;
                    path.pop(m2);
                }
                if (any)
                    validateField!(T, i)(dest.tupleof[i], ctx.errors, path);
            }
            else static if (isOptionalScalar!F)
            {
                alias U = typeof(dest.tupleof[i].get());
                foreach (ref part; parts)
                {
                    if (part.name != name)
                        continue;
                    U e;
                    if (readPartText(path, ctx, part, e))
                    {
                        dest.tupleof[i] = F(e);
                        validateField!(T, i)(e, ctx.errors, path);
                    }
                    break;
                }
            }
            else
            {
                bool seen;
                foreach (ref part; parts)
                {
                    if (part.name != name)
                        continue;
                    seen = true;
                    F e;
                    if (readPartText(path, ctx, part, e))
                    {
                        dest.tupleof[i] = e;
                        validateField!(T, i)(e, ctx.errors, path);
                    }
                    break;
                }
                static if (!isOptionalField!(T, i))
                    if (!seen)
                        ctx.errors.addPath(path, "missing", "Field required");
            }
            path.pop(mark);
        }}
    }
}

private UploadedFile uploadOf(ref MultipartPart part)
{
    UploadedFile file;
    file.filename = part.filename is null ? "" : part.filename;
    file.contentType = part.contentType is null ? "" : part.contentType;
    file.bytes = part.data;
    return file;
}

private void rejectCharset(ref MultipartPart part)
{
    if (part.charset.length && part.charset != "utf-8" && part.charset != "us-ascii")
        throw new HttpError(400, badCharset);
}

private bool readPartText(F)(ref const FieldPath path, Context ctx, ref MultipartPart part, ref F dest)
{
    rejectCharset(part);
    auto text = cast(const(char)[]) part.data;
    static if (is(F == string) || is(F == const(char)[]))
    {
        if (!validUtf8(text))
        {
            ctx.errors.addPath(path, "string_unicode", "invalid UTF-8");
            return false;
        }
    }
    if (!parseScalarText(text, dest))
    {
        ctx.errors.addPath(path, parseErrorType!F, parseErrorMsg!F);
        return false;
    }
    return true;
}

private void checkFileBounds(T, size_t i)(scope const(ubyte)[] bytes, Context ctx, ref const FieldPath path)
{
    static foreach (attr; __traits(getAttributes, T.tupleof[i]))
    {
        static if (is(typeof(attr) == minLength))
        {
            if (bytes.length < attr.value)
                ctx.errors.addPath(path, "bytes_too_short", "expected at least " ~ ctNum(attr.value) ~ " bytes");
        }
        else static if (is(typeof(attr) == maxLength))
        {
            if (bytes.length > attr.value)
                ctx.errors.addPath(path, "bytes_too_long", "expected at most " ~ ctNum(attr.value) ~ " bytes");
        }
    }
}
