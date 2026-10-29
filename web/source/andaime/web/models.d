/// `Query!T` and `Form!T`: a struct bound from a query string or a form body, field by field, by name.
/// `Form!T` reads `application/x-www-form-urlencoded` or `multipart/form-data`. A field of type `UploadedFile` (or
/// `Optional!UploadedFile`, or `UploadedFile[]`) is a file part and the body must be multipart.
///
///     struct Filters { string q; @jsonKey("page_size") int pageSize = 20; Optional!Sort sort; string[] tag; }
///     Page list(Query!Filters f) { ... f.pageSize ... }
///
/// Rules:
///  - the external name of a field is its `@jsonKey`, else its name spelled with the struct's `@naming` (or the
///    project's default, `defaultNaming`);
///  - a field is optional if it is an `Optional!X`, a list (`string[]`, `UploadedFile[]`), marked `@optional`, or has
///    an initializer that is not the type's default (`int pageSize = 20`); anything else is required (`missing`);
///  - a scalar takes the first value of its key, a list takes every value;
///  - urlencoded text is percent-decoded (`+` is a space); multipart text is raw bytes, not percent-decoded;
///  - fields are numbers, bool, enums, text, text types (`andaime.http.texttype`), `Optional`/lists of those, or (on a
///    form) `UploadedFile`;
///  - `@minLength` / `@maxLength` on one `UploadedFile` count bytes; on a list they count items.
module andaime.web.models 2025;

@safe:

import andaime.http.multipart : FormCoding, FormContentType, MultipartPart, classifyFormContentType, parseMultipart,
    MultipartScanner, MultipartEvent;
import andaime.http.types : QueryValues;
import andaime.http.utf8 : validUtf8;
import andaime.web.context : Context;
import andaime.web.convert : percentDecode, parseScalarText, parseErrorType, parseErrorMsg, parseErrorParams;
import andaime.web.dto;
import andaime.web.params : Optional, HttpError, isScalar, isScalarList, isPatchField;
import andaime.web.uploads : SpooledFile, Spooler;

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
    ~ "text types, Optional of those, lists of scalars, UploadedFile or SpooledFile";

enum isUploadedFile(T) = is(T == UploadedFile);
/// A file field: `UploadedFile` or `SpooledFile`, alone, in a list, or `Optional`.
enum isFileField(T) = isOneFileField!(T, UploadedFile) || isOneFileField!(T, SpooledFile);
private enum isOneFileField(T, F) = is(T == F) || is(T == F[]) || is(T == Optional!F);
private enum isSpooledField(T) = isOneFileField!(T, SpooledFile);

/// True when `Form!T` has a `SpooledFile` field: its route reads the body as it arrives.
template formHasSpooled(T)
{
    enum formHasSpooled = () {
        bool any;
        static if (is(T == struct))
            static foreach (i; 0 .. T.tupleof.length)
                static if (!hasUda!(T, i, jsonIgnore) && isSpooledField!(typeof(T.tupleof[i])))
                    any = true;
        return any;
    }();
}

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
                static if (isPatchField!F)
                {
                    if (e.length == 0)
                        e = "field '" ~ fname ~ "' of " ~ T.stringof ~ " is " ~ F.stringof ~ "; PatchField is for JSON "
                            ~ "bodies (a " ~ (asForm ? "form" : "query string") ~ " has no null): use Optional!T";
                }
                else static if (isFileField!F)
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
                                        ~ ": @inRange does not apply to a file (" ~ F.stringof ~ ")";
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
        ctx.errors.addPath(path, parseErrorType!F, parseErrorMsg!F, parseErrorParams!F);
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
    SpooledFile[] spooled;
    static if (formHasSpooled!T)
    {
        if (ctx.request.bodyReader !is null)
        {
            readMultipartStream!T(ctx, ct.boundary, parts, spooled);
            return bindMultipart(ctx, parts, spooled, dest);
        }
    }
    error = parseMultipart(ctx.request.body, ct.boundary, parts);
    if (error.length)
        throw new HttpError(400, error);
    bindMultipart(ctx, parts, null, dest);
}

/// What happens to the content of a part while a body streams: dropped (no field takes it), kept in memory, or spooled.
private enum PartSink : ubyte { skip, keep, spool }

private PartSink partSinkFor(T)(scope const(char)[] name)
{
    static foreach (i; 0 .. T.tupleof.length)
        static if (!hasUda!(T, i, jsonIgnore))
            if (name == jsonKeyOf!(T, i))
                return isSpooledField!(typeof(T.tupleof[i])) ? PartSink.spool : PartSink.keep;
    return PartSink.skip;
}

/// Decodes a multipart body as it arrives, through a 64 KiB window: the parts of `SpooledFile` fields go to a `Spooler`
/// (memory, then a temporary file), the parts of `T`'s other fields are kept in memory, and the parts no field takes
/// are skipped. `spooled[k]` is the file of `parts[k]` when that part was spooled.
private void readMultipartStream(T)(Context ctx, string boundary, ref MultipartPart[] parts, ref SpooledFile[] spooled)
{
    auto scanner = MultipartScanner(boundary);
    auto window = new ubyte[64 << 10];
    size_t start, end;
    bool eof;
    PartSink sink;
    Spooler spooler;
    ubyte[] kept;
    for (;;)
    {
        size_t used;
        MultipartPart head;
        const(ubyte)[] data;
        immutable ev = scanner.next(window[start .. end], eof, used, head, data);
        final switch (ev)
        {
            case MultipartEvent.needMore:
                break;
            case MultipartEvent.part:
                sink = partSinkFor!T(head.name);
                parts ~= head;
                spooled ~= SpooledFile.init;
                if (sink == PartSink.spool)
                    spooler = Spooler(*ctx.bodyState.spool);
                break;
            case MultipartEvent.data:
                if (sink == PartSink.keep)
                    kept ~= data;
                else if (sink == PartSink.spool)
                    spooler.put(ctx, data);
                break;
            case MultipartEvent.partEnd:
                if (sink == PartSink.keep)
                    parts[$ - 1].data = kept;
                else if (sink == PartSink.spool)
                    spooled[$ - 1] = spooler.finish(head0(parts).filename, head0(parts).contentType);
                kept = null;
                sink = PartSink.skip;
                break;
            case MultipartEvent.done:
                // the epilogue (usually nothing): read and dropped, so the connection can serve the next request
                while (ctx.bodyUnread && ctx.readBodyInto(window) > 0)
                {
                }
                return;
            case MultipartEvent.error:
                throw new HttpError(400, scanner.error);
        }
        start += used;
        if (ev != MultipartEvent.needMore || used)
            continue;
        if (eof)
            throw new HttpError(400, "malformed multipart body");
        // move what is left to the front (a forward copy: the regions may overlap), then read more behind it
        foreach (k; 0 .. end - start)
            window[k] = window[start + k];
        end -= start;
        start = 0;
        immutable n = ctx.readBodyInto(window[end .. $]);
        if (n == 0)
            eof = true;
        end += n;
    }
}

/// The last part's names, as a `SpooledFile` keeps them ("" when the part sent none).
private MultipartPart head0(MultipartPart[] parts)
{
    auto p = parts[$ - 1];
    p.filename = p.filename is null ? "" : p.filename;
    p.contentType = p.contentType is null ? "" : p.contentType;
    return p;
}

private void bindMultipart(T)(Context ctx, MultipartPart[] parts, SpooledFile[] spooled, ref T dest)
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
            static if (isFileField!F && is(F == E[], E))
            {
                size_t n;
                bool any;
                foreach (k, ref part; parts)
                {
                    if (part.name != name)
                        continue;
                    any = true;
                    immutable m2 = path.pushIndex(n++);
                    dest.tupleof[i] ~= fileOf!E(part, spooled, k);
                    path.pop(m2);
                }
                if (any)
                    validateField!(T, i)(dest.tupleof[i], ctx.errors, path);
            }
            else static if (isFileField!F && is(F == Optional!E, E))
            {
                foreach (k, ref part; parts)
                {
                    if (part.name != name)
                        continue;
                    auto file = fileOf!E(part, spooled, k);
                    checkFileBounds!(T, i)(sizeOf(file), ctx, path);
                    dest.tupleof[i] = F(file);
                    break;
                }
            }
            else static if (isFileField!F)
            {
                bool seen;
                foreach (k, ref part; parts)
                {
                    if (part.name != name)
                        continue;
                    seen = true;
                    auto file = fileOf!F(part, spooled, k);
                    checkFileBounds!(T, i)(sizeOf(file), ctx, path);
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

/// The file of `parts[k]` as a field of type `E`: a part a streamed body spooled, or one in memory.
private E fileOf(E)(ref MultipartPart part, SpooledFile[] spooled, size_t k)
{
    static if (is(E == UploadedFile))
        return uploadOf(part);
    else
    {
        if (k < spooled.length && spooled[k] !is SpooledFile.init)
            return spooled[k];
        auto u = uploadOf(part);
        return SpooledFile(u.filename, u.contentType, u.bytes.length, u.bytes, null);
    }
}

private ulong sizeOf(ref const UploadedFile f) => f.bytes.length;
private ulong sizeOf(ref const SpooledFile f) => f.size;

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
        ctx.errors.addPath(path, parseErrorType!F, parseErrorMsg!F, parseErrorParams!F);
        return false;
    }
    return true;
}

private void checkFileBounds(T, size_t i)(ulong size, Context ctx, ref const FieldPath path)
{
    static foreach (attr; __traits(getAttributes, T.tupleof[i]))
    {
        static if (is(typeof(attr) == minLength))
        {
            if (size < attr.value)
                ctx.errors.addPath(path, "bytes_too_short", "expected at least " ~ ctNum(attr.value) ~ " bytes",
                    FieldParams.ofLimit(attr.value));
        }
        else static if (is(typeof(attr) == maxLength))
        {
            if (size > attr.value)
                ctx.errors.addPath(path, "bytes_too_long", "expected at most " ~ ctNum(attr.value) ~ " bytes",
                    FieldParams.ofLimit(attr.value));
        }
    }
}
