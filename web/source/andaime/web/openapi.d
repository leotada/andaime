/// `openapi.json` generated from the handler signatures.
///
/// The same introspection that generates the dispatch (parameter names and types,
/// DTOs, return type) describes the API: the HTTP contract is not written twice.
///
///     app.serveOpenApi(OpenApiInfo("My API", "1.0.0"));   // GET /openapi.json and /docs
///
/// Details:
///  - `{param}` in the route -> path parameter; scalar outside the route -> query
///    (required, unless it has a default value or is Optional);
///  - `Header!"X"` -> header; `JsonBody!T` -> requestBody with T's schema;
///  - `Context` and `Local!T` do not appear (they do not come from the client);
///  - structs become `components/schemas`; `@minLength`, `@maxLength`, `@inRange`,
///    `@jsonKey`, `@naming`, `@optional` and `@jsonIgnore` are honored; enums list their wire names;
///  - `@summary("text")` on the handler fills in the operation summary.
module andaime.web.openapi 2025;

@safe:

import andaime.http.types : Method, methodName, statusText;
import andaime.web.params;
import andaime.web.context : Context;
import andaime.web.dto : schemaName, jsonKeyOf, optional, jsonIgnore, minLength, maxLength, inRange, hasUda;
import andaime.http.naming : enumWireNames;
import andaime.web.numtext : itoa, numText, ctNum;
import andaime.web.handler_traits : parseRoute, indexOfName;
import andaime.web.stream : Stream, EventStream, produces;
import andaime.web.models : isQueryModel, isFormModel, formHasFiles, modelFieldOptional, UploadedFile;
import andaime.http.texttype : isTextType, textTypeFormat;
import andaime.web.jsonvalue : Json, JsonValue;

/// One-line operation text: `@summary("Fetch a user") UserResponse getUser(long id)`.
struct summary { string text; }

struct OpenApiInfo
{
    string title = "API";
    string version_ = "0.1.0";
    string description;
    /// JSON path; "" = not served.
    string jsonPath = "/openapi.json";
    /// Interactive page path (Swagger UI via CDN); "" = not served.
    string docsPath = "/docs";
    /// Where the page loads Swagger UI from (a directory URL holding `swagger-ui.css` and `swagger-ui-bundle.js`).
    /// The default is a pinned jsDelivr release, loaded with Subresource Integrity; set it to self-host (then no
    /// integrity check is added, because the files are yours).
    string swaggerUiBase = defaultSwaggerUiBase;
}

/// jsDelivr's copy of swagger-ui-dist, pinned. The integrity hashes below belong to exactly these two files. To update:
///   curl -sL <base>/swagger-ui.css | openssl dgst -sha384 -binary | openssl base64 -A     (same for the bundle .js)
enum defaultSwaggerUiBase = "https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14";
private enum swaggerCssIntegrity = "sha384-wxLW6kwyHktdDGr6Pv1zgm/VGJh99lfUbzSn6HNHBENZlCN7W602k9VkGdxuFvPn";
private enum swaggerJsIntegrity = "sha384-wmyclcVGX/WhUkdkATwhaK1X1JtiNrr2EoYJ+diV3vj4v6OC5yCeSu+yW13SYJep";

/// Named schemas (`components/schemas`) accumulated during generation.
struct Components
{
    string[string] schemas;      // name -> JSON
    bool[string] building;       // avoids infinite recursion on self-referencing types
    string[string] ownerOfName;  // schema name -> the type that owns it (T.mangleof)
    string[string] nameOfType;   // T.mangleof -> its schema name
    bool[string] operationIds;   // operationIds already used in this document
    ValidationDoc validation;    // how the operation being described answers validation failures
    string delegate(ref Components) @safe errorSchema; // `App.errorBody`'s body (the `HTTPError` component); null: detail
    string errorMediaType;       // its media type; null: application/json

    /// Reserves the names andaime itself defines, so a user struct called `HTTPError` gets another name.
    void reserveBuiltins() @safe
    {
        ownerOfName["HTTPValidationError"] = "andaime";
        ownerOfName["HTTPError"] = "andaime";
    }

    /// The schema name for the type with mangled name `key`: `preferred` if free, else `fallback` (the sanitized fully
    /// qualified name), else `fallback_2`, `fallback_3`... The same type always gets the same name.
    string nameFor(string preferred, string key, string fallback) @safe
    {
        if (auto n = key in nameOfType)
            return *n;
        string name = preferred;
        if (name in ownerOfName)
            name = fallback;
        string candidate = name;
        for (int i = 2; candidate in ownerOfName; i++)
            candidate = name ~ "_" ~ itoa(i);
        ownerOfName[candidate] = key;
        nameOfType[key] = candidate;
        return candidate;
    }
}

alias OpDescribe = string delegate(ref Components comps, string pattern) @safe;

// ------------------------------------------------------------ minimal JSON

string q(scope const(char)[] s) pure @safe
{
    string o = "\"";
    foreach (char c; s)
    {
        switch (c)
        {
            case '"': o ~= `\"`; break;
            case '\\': o ~= `\\`; break;
            case '\n': o ~= `\n`; break;
            case '\r': o ~= `\r`; break;
            case '\t': o ~= `\t`; break;
            default:
                if (c < ' ')
                {
                    o ~= `\u00`;
                    o ~= "0123456789abcdef"[c >> 4];
                    o ~= "0123456789abcdef"[c & 15];
                }
                else
                    o ~= c;
        }
    }
    return o ~ "\"";
}

// ------------------------------------------------------------ type schemas

/// JSON schema (inline or `$ref`) of type T.
string schemaOf(T)(ref Components comps) @safe
{
    static if (is(T == JsonValue))
        return `{}`; // any JSON value
    else static if (is(T == bool))
        return `{"type":"boolean"}`;
    else static if (is(T == enum))
    {
        string vals;
        static foreach (w; enumWireNames!T)
            vals ~= (vals.length ? "," : "") ~ q(w);
        return `{"type":"string","enum":[` ~ vals ~ `]}`;
    }
    else static if (__traits(isIntegral, T) && !isCharType!T)
    {
        static if (T.sizeof == 8)
            enum fmt = `"int64"`;
        else
            enum fmt = `"int32"`;
        static if (__traits(isUnsigned, T))
            return `{"type":"integer","format":` ~ fmt ~ `,"minimum":0}`;
        else
            return `{"type":"integer","format":` ~ fmt ~ `}`;
    }
    else static if (__traits(isFloating, T))
        return `{"type":"number"}`;
    else static if (is(T : const(char)[]))
        return `{"type":"string"}`;
    else static if (is(T == Optional!U, U))
        return schemaOf!U(comps);
    else static if (is(T == PatchField!U, U))
        return schemaOf!U(comps);
    else static if (is(T == JsonBody!U, U))
        return schemaOf!U(comps);
    else static if (is(T == WithStatus!U, U))
        return schemaOf!U(comps);
    else static if (is(T == Json!U, U))
        return schemaOf!U(comps); // (before the text-type branch: JSON, not a string)
    else static if (isTextType!T)
    {
        enum fmt = textTypeFormat!T;
        static if (fmt.length)
            return `{"type":"string","format":` ~ q(fmt) ~ `}`;
        else
            return `{"type":"string"}`;
    }
    else static if (is(T == UploadedFile))
        return `{"type":"string","format":"binary"}`;
    else static if (is(T == Stream))
        return `{"type":"string","format":"binary"}`;
    else static if (is(T == EventStream))
        return `{"type":"string"}`;
    else static if (is(T == V[K], V, K) && is(K == string))
        return `{"type":"object","additionalProperties":` ~ schemaOf!V(comps) ~ `}`;
    else static if (is(T == U[], U) || is(T == U[n], U, size_t n))
        return `{"type":"array","items":` ~ schemaOf!U(comps) ~ `}`;
    else static if (is(T == struct))
    {
        string name = comps.nameFor(schemaBaseName!T, T.mangleof, schemaFallbackName!T); // (not `immutable`: `remove` below)
        if (name !in comps.schemas && name !in comps.building)
        {
            comps.building[name] = true;
            comps.schemas[name] = structSchema!T(comps);
            comps.building.remove(name);
        }
        return `{"$ref":"#/components/schemas/` ~ name ~ `"}`;
    }
    else
        return `{}`;
}

/// Characters OpenAPI allows in a component name are `[A-Za-z0-9._-]`; every run of anything else becomes one `_`.
private string sanitizeName(string s) pure @safe
{
    string r;
    bool pendingUnderscore;
    foreach (char c; s)
    {
        immutable ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-'
            || c == '_';
        if (c == '_' || !ok)
            pendingUnderscore = r.length > 0; // runs of `_` and of disallowed characters collapse into one
        else
        {
            if (pendingUnderscore)
                r ~= '_';
            pendingUnderscore = false;
            r ~= c;
        }
    }
    return r;
}

/// Readable schema name: `@schemaName("X")`, else the struct's name; for a template instance the template's name, `_`
/// and its arguments' names (`Page!(User)` -> `Page_User`).
private template schemaBaseName(T)
{
    enum schemaBaseName = () {
        string given;
        static foreach (a; __traits(getAttributes, T))
            static if (is(typeof(a) == schemaName))
                given = a.name;
        if (given.length)
            return given;
        enum text = T.stringof;
        foreach (i, c; text)
            if (c == '!')
            {
                auto r = sanitizeName(__traits(identifier, T) ~ "_" ~ text[i + 1 .. $]);
                return r.length ? r : __traits(identifier, T);
            }
        return __traits(identifier, T);
    }();
}

/// Name used when the readable one belongs to another type: the sanitized fully qualified name (`app.models.User`; for a
/// template instance its module and name, then its arguments: `app.models.Page_User`).
private template schemaFallbackName(T)
{
    enum schemaFallbackName = () {
        enum fqn = __traits(fullyQualifiedName, T);
        enum text = T.stringof;
        foreach (i, c; fqn)
            if (c == '!')
                foreach (j, d; text)
                    if (d == '!')
                        return sanitizeName(fqn[0 .. i] ~ "_" ~ text[j + 1 .. $]);
        return sanitizeName(fqn);
    }();
}

private string structSchema(T)(ref Components comps) @safe
{
    string props, req;
    static foreach (i; 0 .. T.tupleof.length)
    {
        static if (!hasUda!(T, i, jsonIgnore))
        {{
            alias F0 = typeof(T.tupleof[i]);
            static if (is(F0 == PatchField!P, P))
                alias F = P; // the attributes describe the value
            else
                alias F = F0;
            enum key = jsonKeyOf!(T, i);
            string sch = schemaOf!F(comps);
            string extra;
            static foreach (attr; __traits(getAttributes, T.tupleof[i]))
            {
                static if (is(typeof(attr) == minLength))
                {
                    static if (is(F == UploadedFile) || is(F == Optional!UploadedFile))
                        extra ~= `,"minLength":` ~ itoa(attr.value);
                    else
                        extra ~= `,"` ~ (is(F : const(char)[]) ? "minLength" : "minItems") ~ `":` ~ itoa(attr.value);
                }
                else static if (is(typeof(attr) == maxLength))
                {
                    static if (is(F == UploadedFile) || is(F == Optional!UploadedFile))
                        extra ~= `,"maxLength":` ~ itoa(attr.value);
                    else
                        extra ~= `,"` ~ (is(F : const(char)[]) ? "maxLength" : "maxItems") ~ `":` ~ itoa(attr.value);
                }
                else static if (is(typeof(attr) == inRange))
                    extra ~= `,"minimum":` ~ numText(attr.min) ~ `,"maximum":` ~ numText(attr.max);
            }
            static if (is(F == Optional!U, U) || isPatchField!F0)
                extra ~= `,"nullable":true`;
            if (extra.length)
            {
                // injects the constraints into the schema object (if it is a $ref, wraps it in allOf)
                if (sch.length > 8 && sch[0 .. 7] == `{"$ref"`)
                    sch = `{"allOf":[` ~ sch ~ `]` ~ extra ~ `}`;
                else if (sch == `{}`)
                    sch = `{` ~ extra[1 .. $] ~ `}`; // any value (JsonValue): no comma before the first member
                else
                    sch = sch[0 .. $ - 1] ~ extra ~ `}`;
            }
            props ~= (props.length ? "," : "") ~ q(key) ~ ":" ~ sch;
            static if (!hasUda!(T, i, optional) && !isOptional!F && !isPatchField!F0 && !is(F == UploadedFile[]))
                req ~= (req.length ? "," : "") ~ q(key);
        }}
    }
    return `{"type":"object","properties":{` ~ props ~ `}` ~ (req.length ? `,"required":[` ~ req ~ `]` : "") ~ `}`;
}

// ------------------------------------------------------------ description of an operation

/// Generates the OpenAPI operation object for handler `fn` registered at `method path`.
string describeOperation(Method method, string path, alias fn)(ref Components comps, string pattern) @safe
{
    static if (is(typeof(fn) P == __parameters))
    {
        enum info = parseRoute(path);
        string params, bodySchema;
        string bodyMedia = "application/json";
        bool formBoth; /// text-only form: urlencoded and multipart
        bool bodyRequired;
        bool canFail;

        static foreach (i; 0 .. P.length)
        {{
            alias T = P[i];
            enum pname = __traits(identifier, P[i .. i + 1]);
            enum ri = indexOfName(info.params, pname);

            static if (ri >= 0)
            {
                params ~= (params.length ? "," : "") ~ `{"name":` ~ q(pname) ~ `,"in":"path","required":true,"schema":`
                    ~ schemaOf!T(comps) ~ `}`;
                canFail = true;
            }
            else static if (is(T == Context) || isLocal!T || isClientIp!T)
            {
            }
            else static if (isQueryModel!T)
            {
                // each field is a query parameter of its own
                alias M = typeof(T.value);
                static foreach (k; 0 .. M.tupleof.length)
                {
                    static if (!hasUda!(M, k, jsonIgnore))
                    {
                        params ~= (params.length ? "," : "") ~ `{"name":` ~ q(jsonKeyOf!(M, k)) ~ `,"in":"query","required":`
                            ~ (modelFieldOptional!(M, k) ? "false" : "true")
                            ~ (isScalarList!(typeof(M.tupleof[k])) ? `,"style":"form","explode":true` : "")
                            ~ `,"schema":` ~ schemaOf!(typeof(M.tupleof[k]))(comps) ~ `}`;
                    }
                }
                canFail = true;
            }
            else static if (isFormModel!T)
            {
                bodySchema = schemaOf!(typeof(T.value))(comps);
                static if (formHasFiles!(typeof(T.value)))
                    bodyMedia = "multipart/form-data";
                else
                    formBoth = true;
                bodyRequired = true;
                canFail = true;
            }
            else static if (is(T == JsonBody!U, U))
            {
                bodySchema = schemaOf!U(comps);
                bodyRequired = true;
                canFail = true;
            }
            else static if (is(T == Cookie!c, string c))
            {
                params ~= (params.length ? "," : "") ~ `{"name":` ~ q(c) ~ `,"in":"cookie","required":true,"schema":{"type":"string"}}`;
                canFail = true;
            }
            else static if (is(T == Header!n, string n))
            {
                params ~= (params.length ? "," : "") ~ `{"name":` ~ q(n) ~ `,"in":"header","required":true,"schema":{"type":"string"}}`;
                canFail = true;
            }
            else static if (is(T == Optional!U, U))
            {
                static if (is(U == Cookie!c, string c))
                    params ~= (params.length ? "," : "") ~ `{"name":` ~ q(c) ~ `,"in":"cookie","required":false,"schema":{"type":"string"}}`;
                else static if (is(U == Header!n, string n))
                    params ~= (params.length ? "," : "") ~ `{"name":` ~ q(n) ~ `,"in":"header","required":false,"schema":{"type":"string"}}`;
                else static if (is(U == JsonBody!V, V))
                {
                    bodySchema = schemaOf!V(comps);
                    bodyRequired = false;
                    canFail = true;
                }
                else
                {
                    params ~= (params.length ? "," : "") ~ `{"name":` ~ q(pname) ~ `,"in":"query","required":false,"schema":`
                        ~ schemaOf!U(comps) ~ `}`;
                    canFail = true;
                }
            }
            else static if (isScalarList!T)
            {
                // repeated keys: ?tag=a&tag=b
                params ~= (params.length ? "," : "") ~ `{"name":` ~ q(pname) ~ `,"in":"query","required":false,"style":"form","explode":true,"schema":`
                    ~ schemaOf!T(comps) ~ `}`;
                canFail = true;
            }
            else // scalar outside the route => query
            {
                enum hasDefault = is(typeof(((P[i .. i + 1] __a) => __a[0])()));
                params ~= (params.length ? "," : "") ~ `{"name":` ~ q(pname) ~ `,"in":"query","required":`
                    ~ (hasDefault ? "false" : "true") ~ `,"schema":` ~ schemaOf!T(comps) ~ `}`;
                canFail = true;
            }
        }}

        string id = opId!fn;
        if (id in comps.operationIds) // two handlers with the same name (different controllers): the spec wants unique ids
            id = id ~ "_" ~ methodName(method) ~ "_" ~ sanitizeName(pattern);
        comps.operationIds[id] = true;
        string o = `{"operationId":` ~ q(id);
        static foreach (attr; __traits(getAttributes, fn))
            static if (is(typeof(attr) == summary))
                o ~= `,"summary":` ~ q(attr.text);
        if (params.length)
            o ~= `,"parameters":[` ~ params ~ `]`;
        if (bodySchema.length)
        {
            o ~= `,"requestBody":{"required":` ~ (bodyRequired ? "true" : "false") ~ `,"content":{`;
            if (formBoth)
                o ~= `"application/x-www-form-urlencoded":{"schema":` ~ bodySchema
                    ~ `},"multipart/form-data":{"schema":` ~ bodySchema ~ `}}}`;
            else
                o ~= q(bodyMedia) ~ `:{"schema":` ~ bodySchema ~ `}}}`;
        }

        // responses
        string resp;
        string[] declared; // status codes given by @responds
        static if (is(typeof(fn) R == return))
        {
            enum st = successStatus!fn;
            static if (is(R == void))
            {
                enum code = st ? st : 204;
                resp = `"` ~ ctNum(code) ~ `":{"description":` ~ q(statusDescription(code)) ~ `}`;
            }
            else static if (is(R : const(char)[]))
            {
                enum code = st ? st : 200;
                resp = `"` ~ ctNum(code) ~ `":{"description":` ~ q(statusDescription(code))
                    ~ `,"content":{"text/plain":{"schema":{"type":"string"}}}}`;
            }
            else static if (is(R == Response))
            {
                enum code = st ? st : 200;
                resp = `"` ~ ctNum(code) ~ `":{"description":` ~ q(statusDescription(code)) ~ `}`;
            }
            else static if (isWithStatus!R && st == 0)
                // the handler picks the status at run time: a range key (OpenAPI 3.0 allows "2XX")
                resp = `"2XX":{"description":"Success","content":{` ~ q(mediaOf!(fn, R)) ~ `:{"schema":` ~ schemaOf!R(comps) ~ `}}}`;
            else
            {
                enum code = st ? st : 200;
                resp = `"` ~ ctNum(code) ~ `":{"description":` ~ q(statusDescription(code))
                    ~ `,"content":{` ~ q(mediaOf!(fn, R)) ~ `:{"schema":` ~ schemaOf!R(comps) ~ `}}}`;
            }
        }
        static foreach (a; __traits(getAttributes, fn))
            static if (is(typeof(a) == responds))
            {
                ensureHttpError(comps);
                resp ~= (resp.length ? "," : "") ~ `"` ~ ctNum(a.code) ~ `":{"description":` ~ q(a.description)
                    ~ `,"content":{` ~ q(comps.errorMediaType.length ? comps.errorMediaType : "application/json")
                    ~ `:{"schema":{"$ref":"#/components/schemas/HTTPError"}}}}`;
                declared ~= ctNum(a.code);
            }
        if (canFail)
        {
            string key;
            auto entry = validationEntry(comps, key);
            bool taken;
            foreach (d; declared)
                taken |= d == key;
            if (!taken)
                resp ~= (resp.length ? "," : "") ~ q(key) ~ ":" ~ entry;
        }
        o ~= `,"responses":{` ~ resp ~ `}}`;
        return o;
    }
    else
        return `{}`;
}

/// Media type of a handler's success body: JSON, except for streamed responses (`@produces("text/csv")` overrides it).
private template mediaOf(alias fn, R)
{
    enum mediaOf = () {
        string m = "application/json";
        static if (is(R == Stream) || is(R == WithStatus!Stream))
            m = "application/octet-stream";
        else static if (is(R == EventStream) || is(R == WithStatus!EventStream))
            m = "text/event-stream";
        static foreach (a; __traits(getAttributes, fn))
            static if (is(typeof(a) == produces))
                m = a.mediaType;
        return m;
    }();
}

private template opId(alias fn)
{
    static if (__traits(compiles, __traits(identifier, fn)))
        enum opId = __traits(identifier, fn);
    else
        enum opId = "handler";
}

/// Reason phrase as the response description ("Created"); "Success" for codes without one.
private string statusDescription(int code) pure @safe
{
    auto t = statusText(code);
    return t == "Unknown" ? "Success" : t;
}

/// The `HTTPError` component: `{"detail": "..."}`, or the body of `App.errorBody` when it is set.
private void ensureHttpError(ref Components comps) @safe
{
    if ("HTTPError" in comps.schemas)
        return;
    comps.schemas["HTTPError"] = comps.errorSchema is null
        ? `{"type":"object","properties":{"detail":{"type":"string"}},"required":["detail"]}`
        : comps.errorSchema(comps);
}

private void ensureValidationError(ref Components comps) @safe
{
    if ("HTTPValidationError" !in comps.schemas)
        comps.schemas["HTTPValidationError"] = `{"type":"object","properties":{"detail":{"type":"array","items":`
            ~ `{"type":"object","properties":{"type":{"type":"string"},`
            ~ `"loc":{"type":"array","items":{"anyOf":[{"type":"string"},{"type":"integer"}]}},"msg":{"type":"string"}},`
            ~ `"required":["type","loc","msg"]}}}}`;
}

/// How a route documents its validation failures: the default 422, or what `App.onValidationError` declared.
struct ValidationDoc
{
    bool custom;        /// a custom handler answers them
    int status;         /// its declared status; 0: not declared (documented as "4XX", without a body schema)
    string description;
    string delegate(ref Components) @safe schema; /// the body's schema; null: none declared
    string mediaType;   /// the body's media type; null: application/json
}

/// The responses entry for a route that can fail validation, and its key ("422", "400", "4XX").
private string validationEntry(ref Components comps, out string key) @safe
{
    auto v = comps.validation;
    if (!v.custom)
    {
        ensureValidationError(comps);
        key = "422";
        return `{"description":"Validation error","content":{"application/json":`
            ~ `{"schema":{"$ref":"#/components/schemas/HTTPValidationError"}}}}`;
    }
    key = v.status ? itoa(v.status) : "4XX";
    auto desc = v.description.length ? v.description : "Validation error";
    if (v.schema is null)
        return `{"description":` ~ q(desc) ~ `}`;
    return `{"description":` ~ q(desc) ~ `,"content":{` ~ q(v.mediaType.length ? v.mediaType : "application/json")
        ~ `:{"schema":` ~ v.schema(comps) ~ `}}}`;
}

// ------------------------------------------------------------ document

struct OpRecord
{
    Method method;
    string pattern;     // as registered (includes the group prefix)
    OpDescribe describe; // null for routes without introspection (static files...)
    ValidationDoc validation; // filled when the app freezes
    string handler;     // what `App.routeTable` shows: a qualified name, `file:line` of a lambda, or a label
}

/// `{*rest}` -> `{rest}` (OpenAPI does not know the asterisk).
private string openApiPath(string pattern) pure @safe
{
    string o;
    foreach (i, c; pattern)
        if (!(c == '*' && i > 0 && pattern[i - 1] == '{'))
            o ~= c;
    return o;
}

string buildOpenApi(const(OpRecord)[] ops, OpenApiInfo info, string delegate(ref Components) @safe errorSchema = null,
    string errorMediaType = null) @safe
{
    Components comps;
    comps.reserveBuiltins();
    comps.errorSchema = errorSchema;
    comps.errorMediaType = errorMediaType;
    // group by path preserving registration order
    string[] order;
    string[string] byPath;
    foreach (ref op; ops)
    {
        if (op.describe is null)
            continue;
        auto p = openApiPath(op.pattern);
        string verb;
        final switch (op.method)
        {
            case Method.GET: verb = "get"; break;
            case Method.HEAD: verb = "head"; break;
            case Method.POST: verb = "post"; break;
            case Method.PUT: verb = "put"; break;
            case Method.PATCH: verb = "patch"; break;
            case Method.DELETE: verb = "delete"; break;
            case Method.OPTIONS: verb = "options"; break;
            case Method.unknown: continue;
        }
        comps.validation = op.validation;
        auto body_ = q(verb) ~ ":" ~ op.describe(comps, op.pattern);
        if (auto cur = p in byPath)
            *cur ~= "," ~ body_;
        else
        {
            order ~= p;
            byPath[p] = body_;
        }
    }

    string paths;
    foreach (p; order)
        paths ~= (paths.length ? "," : "") ~ q(p) ~ ":{" ~ byPath[p] ~ "}";
    string schemas;
    foreach (name; sortedKeys(comps.schemas))
        schemas ~= (schemas.length ? "," : "") ~ q(name) ~ ":" ~ comps.schemas[name];

    string o = `{"openapi":"3.0.3","info":{"title":` ~ q(info.title) ~ `,"version":` ~ q(info.version_);
    if (info.description.length)
        o ~= `,"description":` ~ q(info.description);
    o ~= `},"paths":{` ~ paths ~ `},"components":{"schemas":{` ~ schemas ~ `}}}`;
    return o;
}

private string[] sortedKeys(string[string] aa) @safe
{
    string[] k = aa.keys;
    // insertion sort: few schemas and avoids importing std.algorithm
    foreach (i; 1 .. k.length)
        for (size_t j = i; j > 0 && k[j - 1] > k[j]; j--)
        {
            auto t = k[j];
            k[j] = k[j - 1];
            k[j - 1] = t;
        }
    return k;
}

/// Interactive page (Swagger UI loaded by the user's browser). The title is HTML-escaped.
string docsHtml(string jsonPath, string title, string swaggerUiBase = defaultSwaggerUiBase) @safe
{
    // integrity only for the pinned CDN files; a self-hosted copy has other bytes
    immutable pinned = swaggerUiBase == defaultSwaggerUiBase;
    return `<!doctype html><html><head><meta charset="utf-8"><title>` ~ htmlEscape(title)
        ~ ` — docs</title><meta name="viewport" content="width=device-width, initial-scale=1">`
        ~ `<link rel="stylesheet" href="` ~ htmlEscape(swaggerUiBase) ~ `/swagger-ui.css"`
        ~ (pinned ? ` integrity="` ~ swaggerCssIntegrity ~ `" crossorigin="anonymous"` : "") ~ `></head>`
        ~ `<body><div id="ui"></div><script src="` ~ htmlEscape(swaggerUiBase) ~ `/swagger-ui-bundle.js"`
        ~ (pinned ? ` integrity="` ~ swaggerJsIntegrity ~ `" crossorigin="anonymous"` : "") ~ `></script>`
        ~ `<script>SwaggerUIBundle({url:` ~ scriptString(jsonPath) ~ `,dom_id:"#ui"})</script></body></html>`;
}

private string htmlEscape(scope const(char)[] s) pure @safe
{
    string r;
    foreach (char c; s)
        switch (c)
        {
            case '&': r ~= "&amp;"; break;
            case '<': r ~= "&lt;"; break;
            case '>': r ~= "&gt;"; break;
            case '"': r ~= "&quot;"; break;
            case '\'': r ~= "&#39;"; break;
            default: r ~= c;
        }
    return r;
}

/// A JSON string that is also safe inside an inline <script> (no `</script>` or `<!--` can end the element).
private string scriptString(scope const(char)[] s) pure @safe
{
    string r;
    foreach (char c; q(s))
        r ~= c == '<' ? `\u003c` : (c == '>' ? `\u003e` : (c == '&' ? `\u0026` : [c].idup));
    return r;
}
