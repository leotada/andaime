# Reading the request

A handler declares what it needs as parameters; vela extracts, converts and validates each one before calling it. If anything
fails, the client gets a **422** listing every problem and the handler does not run ([validation.md](validation.md)).

## Where each parameter comes from

| In the signature | vela reads |
|------------------|------------|
| `long id` with `{id}` in the route | the path parameter |
| `int limit = 20` (not in the route) | the query string `?limit=`; the default makes it optional |
| `string[] tag`, `int[] ids` | a repeated query key (`?tag=a&tag=b`); absent = empty list |
| `JsonBody!T body_` | the JSON body, decoded into `T` |
| `Query!T f` | a struct filled from the query string, field by field |
| `Form!T f` | a struct filled from an `application/x-www-form-urlencoded` or `multipart/form-data` body |
| `Header!"Authorization" auth` | a header (case-insensitive name), copied into a `string` |
| `Cookie!"session" s` | a cookie, copied into a `string` |
| `Optional!X` | any of the above, present or not, without an error |
| `ClientIp ip` | the client's address (the real one behind a trusted proxy) |
| `Local!T` | a value a middleware stored for this request ([middleware.md](middleware.md)) |
| `Context ctx` | everything: the raw request and the response |

Scalars are `bool`, integers, floating point, `enum` (by member name, or its [wire name](#wire-names-naming-and-wirename)),
`string`, and your own
[text types](#your-own-types-uuids-dates-money). Parameter order does not matter.

## Path and query

```d
User getUser(long id) { ... }                                        // GET /users/{id}
User[] list(int limit = 20, int offset = 0, Order order = Order.asc)  // GET /users?limit=5&order=desc
Item[] byTags(string[] tag) { ... }                                   // GET /items?tag=a&tag=b
```

- A query parameter without a default is required: missing means a 422 with `type: "missing"`.
- A `bool` accepts `true`/`false` and `1`/`0`. An `enum` accepts its member names (`asc`, `desc`).
- Values are percent-decoded (`+` is a space in the query). In a list, an error names the element: `["query", "ids", 1]`.

## JSON body

```d
struct NewOrder
{
    @minLength(1) string customer;
    Line[] lines;                 // nested structs and arrays are fine
    Optional!string note;         // may be absent or null
    int[string] tags;             // an object with arbitrary keys
}

Order create(JsonBody!NewOrder body_)
{
    return save(body_.customer, body_.lines);   // the fields are reachable directly (alias this)
}
```

- The `Content-Type` is not checked; the body must be valid JSON for `T` (a struct, an array, a map `V[string]` or a scalar).
  An empty body is a 422 (`missing`). `GET` and `HEAD` routes cannot take a body (compile error); one body per handler.
- Unknown fields are ignored. A field without a default and not `Optional` (or `PatchField`, see
  [partial updates](#partial-updates-patchfield)) is required.
- `@jsonKey("page_size")` sets the external name (`@naming` on the struct sets all of them, see
  [wire names](#wire-names-naming-and-wirename)), `@jsonIgnore` skips a field. Validation attributes are in
  [validation.md](validation.md).
- An `enum` is its member name as a JSON string. A map keeps the last value of a repeated key; its output order is unspecified.
- Bodies are buffered whole, up to `limits.maxBodyBytes` (1 MiB by default; 413 above). HTTP/1.1 chunked uploads are accepted.

## Query and form models

When a handler has many query parameters, group them in a struct:

```d
struct Filters
{
    @minLength(2) string q;                                   // required
    @jsonKey("page_size") @inRange(1, 100) int pageSize = 20; // optional: it has an initializer
    Optional!Sort sort;                                       // optional
    string[] tag;                                             // ?tag=a&tag=b
}

Page search(Query!Filters f) { ... }      // GET /search?q=boots&page_size=50&tag=a&tag=b
string login(Form!Login f) { ... }        // POST, urlencoded or multipart text (415 otherwise)
```

A field is a scalar, a text type, an `Optional` of those or a list of them. It is optional when it is an `Optional`, a list,
marked `@optional`, or has an initializer other than the type's default. OpenAPI lists each query field as its own parameter.
`Query!T` cannot hold a file.

## Wire names: `@naming` and `@wireName`

An API in `snake_case` does not need a `@jsonKey` on every field. Put a policy on the struct:

```d
// check
import vela;

@naming(Naming.snakeCase)
struct TaskIn
{
    string firstName;                 // "first_name"
    long companyId;                   // "company_id"
    @jsonKey("assignee") long userId; // a field's @jsonKey wins
    TaskType type_;                   // "type": a trailing `_` (D's keyword escape) is dropped
}

@naming(Naming.kebabCase)
enum TaskType { task, taskInstance }  // "task", "task-instance"

enum Photo { none, @wireName("on_issue") onIssue } // one member renamed

string create(JsonBody!TaskIn t) => t.firstName;
string byType(TaskType kind, Photo photo = Photo.none) => "ok"; // GET /tasks/task-instance?photo=on_issue

void main()
{
    auto app = new App;
    app.post!("/tasks", create);
    app.get!("/tasks/{kind}", byType);
}
```

- The policies are `Naming.snakeCase`, `kebabCase`, `camelCase` (`first_name` -> `firstName`), `upperSnakeCase` and
  `asIs` (the default). Words split at `_` and at case changes; a run of capitals is one word (`userID` -> `user_id`,
  `HTTPServer` -> `http_server`).
- On a struct, the policy names its fields in JSON (both ways), `Query!T`, `Form!T` (the part names), the `loc` of a 422 and
  the OpenAPI document. It is not inherited: a nested struct declares its own. On a field it is a compile error; use
  `@jsonKey`.
- On an enum, the policy (or a member's `@wireName`) names its values everywhere a value goes in or out: JSON, path, query,
  form, headers, the 422 message (`expected one of: task, task-instance`), OpenAPI's `enum` list, logs and the Postgres
  driver ([database.md](database.md)). The D member name is no longer accepted. Two members with the same wire name are a
  compile error.

## File uploads

A file is an `UploadedFile` field on `Form!T`. The body must then be `multipart/form-data` (415 otherwise). A form with no
file fields accepts either urlencoded or multipart.

```d
// check
@safe:

import vela;

struct Profile
{
    @minLength(1) string name;
    @maxLength(512 * 1024) UploadedFile avatar; // required; maxLength is bytes
    @optional UploadedFile banner;              // absent keeps the initial value
    UploadedFile[] photos;                      // every part named "photos"; absent = empty
}

string save(Form!Profile f)
{
    if (f.banner.filename.length)
        return f.banner.filename;
    return f.name ~ ":" ~ f.avatar.filename;
}

void main()
{
    auto app = new App;
    app.post!("/profile", save);
}
```

- `filename` and `contentType` are copies. `contentType` is empty when the part sent none. `bytes` is a view into the
  request buffer, like `ctx.request.body`: copy it (`.idup`) to keep it ([safety.md](safety.md)). `filename` is the name
  the client sent (`filename*` in UTF-8 wins over `filename`), not a filesystem path.
- The part name is the field's `@jsonKey`, or the field name. Unknown parts are ignored. A scalar takes the first part; a
  list takes every part, in order. A part with no filename still fills an `UploadedFile` (`filename` is empty).
- Urlencoded text is percent-decoded (`+` is a space). Multipart text is the raw part bytes, not percent-decoded. A file
  part bound to a string field is those bytes, checked as UTF-8.
- `@minLength` / `@maxLength` on one `UploadedFile` count bytes (422 `bytes_too_short` / `bytes_too_long`). On
  `UploadedFile[]` they count files. `@inRange` does not apply to a file (compile error).
- The whole body, files included, is buffered up to `limits.maxBodyBytes` (1 MiB by default; 413 above). A multipart body
  is also limited to 128 parts, 8 KiB of headers per part, a name of 256 bytes and a filename of 1024. Over that, or any
  other broken framing, is 400. A text part whose charset is not `utf-8` or `us-ascii` is 400; a file part keeps its
  charset in `contentType` and is not decoded. Unbuffered request bodies are not implemented: raise `maxBodyBytes` for a
  larger upload.
- OpenAPI describes a file field as a string with `format: binary`. A form that has a file documents
  `multipart/form-data` only; a text-only form documents both content types.

## Headers and cookies

```d
string me(Header!"Authorization" auth, Cookie!"session" s) { ... }
string theme(Optional!(Cookie!"theme") t) => t.has ? t.get.value : "light";
string trace(Optional!(Header!"X-Trace-Id") id) => id.has ? id.get.value : "none";
```

`Header!"X"` and `Cookie!"x"` are copies you may keep after the request. To read without copying, use
`ctx.request.header("X")` and `ctx.cookie("x")`: those are views valid during the request (see [safety.md](safety.md)).
Setting cookies is in [responses.md](responses.md#cookies).

## `Optional`

`Optional!T` is "present or absent", for parameters, JSON fields and database columns alike:

```d
string sortBy(Optional!string by) => by.getOr("name");
```

`has`, `get` (asserts it is there: check `has` first), `getOr(fallback)`, `Optional!T.none`. In JSON, an empty one is written
as `null`. `Optional!(JsonBody!T)` makes the whole body optional.

## Partial updates: `PatchField`

In a PATCH body an absent field usually means "leave it alone" and `null` means "clear it". `Optional!T` cannot tell those
apart (both are empty); `PatchField!T` can:

```d
// check
import vela;

struct Profile { string name; string nickname; int age; }

struct ProfileUpdate
{
    @minLength(2) PatchField!string name;   // validated only when it has a value
    PatchField!string nickname;
    PatchField!int age;
}

Profile current = Profile("Ana", "aninha", 30);

Profile update(JsonBody!ProfileUpdate u)
{
    if (u.name.hasValue)
        current.name = u.name.value;
    if (u.nickname.isNull)
        current.nickname = null;               // "nickname": null -> clear it
    else if (u.nickname.hasValue)
        current.nickname = u.nickname.value;   // "nickname": "x"  -> set it
    current.age = u.age.valueOr(current.age);  // absent or null    -> keep it
    return current;
}

void main()
{
    serve(() {
        auto app = new App;
        app.patch!("/me", update);
        return app;
    });
}
```

- `isAbsent`, `isNull`, `hasValue`, `isPresent` (null or a value), `value` (asserts `hasValue`), `valueOr(fallback)`;
  `PatchField!T(v)`, `PatchField!T.null_`, `PatchField!T.absent` build one.
- It works in nested structs and arrays of structs. A `PatchField` field is never required, and its validation attributes
  apply to the value only (absent and `null` pass). A wrong value is a 422 with the field's `loc`, as usual.
- `writeJson` (a response) leaves an absent field out of its object and writes `null` for a null one. Outside an object
  (in an array, say) absent is written as `null`.
- OpenAPI: the field is not in `required` and is `nullable`.
- JSON bodies only: a form or a query string has no `null`, so `PatchField` in a `Form!T` or `Query!T`, or as a handler
  parameter, is a compile error (use `Optional!T` there).

## Any JSON value: `JsonValue`

When the shape is only known at run time (keys checked against a schema at run time, a different type per key),
`JsonValue` holds any JSON value: null, a boolean, an integer, a floating number, a string, an array, or an object whose
members keep their order. Use it as the body (`JsonBody!JsonValue`), as a DTO field, or as a map's value:

```d
// check
import vela;

immutable string[] known = ["dark_mode", "language"];

struct Settings { bool darkMode; string language; }
Settings current;

Settings update(JsonBody!(JsonValue[string]) body_)
{
    foreach (key, ref v; body_.value)
    {
        if (key == "dark_mode" && v.isBool)
            current.darkMode = v.asBool;
        else if (key == "language" && (v.isString || v.isNull))
            current.language = v.isNull ? null : v.asString;
        else
            throw new HttpError(400, "invalid setting: " ~ key);
    }
    return current;
}

void main()
{
    serve(() {
        auto app = new App;
        app.patch!("/settings", update);
        return app;
    });
}
```

- Kinds: `type`, `isNull`, `isBool`, `isInteger`, `isFloat`, `isNumber`, `isString`, `isArray`, `isObject`.
- Values: `asBool`, `asInteger`, `asFloat` (an integer converts), `asString`, `array`, `members` (key and value, in order),
  `length`. Used on the wrong kind they throw `JsonError` (a 500 unless you catch it), so check the kind first.
- Lookups: `v.get("key")` is a pointer, null when missing; `v["key"]` and `v[0]` throw `JsonError` when missing.
- Building: `JsonValue(null)`, `JsonValue(true)`, `JsonValue(42)`, `JsonValue(1.5)`, `JsonValue("s")`,
  `JsonValue([JsonValue(1), JsonValue("a")])`, `JsonValue.emptyObject`, `JsonValue.emptyArray`, `obj["key"] = value`,
  `arr.append(value)`. A handler may return one; `toString` gives its JSON text.
- A number is an `integer` when it has no fraction or exponent and fits a `long`, a `floating` otherwise. A floating number
  with an integral value is written with `.0`, so it reads back as floating. A repeated key keeps its first position and its
  last value.
- Limits: arrays and objects nested deeper than 64 levels are a 422 (`json_invalid`, "JSON nested deeper than 64 levels at
  byte N"); a number that overflows a `double`, or is longer than 63 characters, is a 422 too. The body itself is bounded by
  `limits.maxBodyBytes`. OpenAPI documents a `JsonValue` as any value (`{}`).

Outside a request (an upstream API's response, a file): `parseJson(text)` returns a `JsonValue` or throws `JsonError`;
`parseJson(text, value, error, limits)` returns false and an error line instead; `JsonLimits` sets `maxDepth` (64) and
`maxBytes` (16 MiB). `fromJson!T(text)` decodes into a DTO with the rules of a request body, and `toJson(value)` writes
any value as JSON text. See [http-client.md](http-client.md#reading-json).

## The client's address

```d
string whoAmI(ClientIp ip) => ip.toString;
```

Behind a load balancer or reverse proxy the TCP peer is the proxy. Tell vela which proxies to believe and it reads the real
client from `X-Forwarded-For`, walking from the right and stopping at the first address that is not a trusted proxy:

```d
ServerConfig cfg;
cfg.trustedProxies = ["10.0.0.0/8", "127.0.0.1/32"];   // CIDR strings; a bad one fails startup
cfg.forwardedHeader = "X-Forwarded-For";               // the default
```

(`app.trustProxies([...])` does the same for one App, for example in tests.) From any other peer the header is ignored,
because anyone can send it. `ctx.clientIp()` gives the same answer inside middleware. `accessLog()` logs it.

## Your own types (UUIDs, dates, money)

A struct that can read and write itself as text works wherever a string does: path, query, header, `Query!T`/`Form!T` fields,
JSON fields and database columns. There is nothing to register; the compiler checks the shape:

```d
struct Uuid
{
    ubyte[16] bytes;
    static bool fromString(scope const(char)[] text, out Uuid v) { ... }               // false = invalid
    void toString(scope void delegate(scope const(char)[]) @safe sink) const { ... }  // writes the text
    enum openApiFormat = "uuid";                                         // optional: the OpenAPI "format"
    enum invalidMessage = "expected a UUID like 123e4567-...";           // optional: the 422 message
}

Order getOrder(Uuid id) { ... }                           // a bad id is a 422 with type "value_error"
struct Order { Uuid id; Optional!Uuid parent; }           // JSON strings with "format": "uuid" in OpenAPI
```

Inside `fromString`/`toString` use any library you like (`std.datetime`, `std.uuid`).

## The raw request: `Context`

Take a `Context` parameter for anything the wrappers do not cover:

| `ctx.request.` | |
|----------------|--|
| `method`, `protocol` | `Method.GET`...; `Protocol.http1` or `Protocol.http2` |
| `path`, `query`, `target` | still percent-encoded; `target` is path + query as received |
| `header("Name")`, `headers` | first value of a header, or all of them |
| `queryValues("tag")`, `rawQueryParam("q", v)` | raw query values |
| `body` | the body bytes (`const(ubyte)[]`) |
| `peer` | the TCP peer (`ctx.clientIp()` for the real client) |

These slices are views into the connection's buffer: copy (`.idup`) what you keep after the request.
