# Validation and errors

## Validation attributes

Put them on the fields of a DTO (JSON body, `Query!T`, `Form!T`):

| Attribute | On | Meaning |
|-----------|----|---------|
| `@minLength(n)`, `@maxLength(n)` | strings, arrays, `UploadedFile` | length bounds; strings count characters (code points), arrays count items, one file counts bytes |
| `@inRange(min, max)` | numbers | inclusive bounds |
| `@optional` | any field | may be absent (the field keeps its initial value) |
| `@jsonKey("name")` | any field | the external name in JSON, query and form |
| `@jsonIgnore` | any field | not read from nor written to JSON |
| `@schemaName("Name")` | a struct | its name in the OpenAPI document |

```d
struct SignUp
{
    @minLength(2) @maxLength(60) string name;
    @minLength(3) string email;
    @inRange(13, 150) int age;
    @jsonKey("referral_code") Optional!string referral;
    @maxLength(5) string[] interests;
    @jsonIgnore bool verified;
}
```

Required or optional: a field is required unless it is an `Optional!T`, is marked `@optional`, or (in `Query!T`/`Form!T`) is a
list or has an initializer other than the type's default. Text must be valid UTF-8.

Rules the attributes cannot express go in the handler: throw `HttpError(422, "...")`, or a 409 for a conflict, and so on.

## The 422 response

Conversion and validation errors become one **422** in FastAPI's (Pydantic v2's) format, and the handler does not run:

```json
{"detail":[
  {"type":"string_too_short","loc":["body","name"],"msg":"expected at least 2 characters"},
  {"type":"int_parsing","loc":["query","limit"],"msg":"expected an integer between -2147483648 and 2147483647"},
  {"type":"missing","loc":["header","Authorization"],"msg":"Field required"}
]}
```

- `loc` says where: `path`, `query`, `header`, `cookie` or `body`, then field names and array indexes
  (`["body","items",1,"code"]`).
- `type` is a stable code for programs; `msg` is for people.
- At most 16 errors are listed; then a `too_many_errors` entry gives the count of the rest.

| `type` | When |
|--------|------|
| `missing` | a required value is absent (including an empty JSON body) |
| `int_parsing`, `float_parsing`, `bool_parsing` | not a number / boolean, or out of the type's range |
| `enum` | not one of the enum's member names |
| `string_type`, `list_type`, `model_type`, `dict_type` | wrong JSON type (expected a string, array, object, map) |
| `string_too_short`, `string_too_long` | `@minLength` / `@maxLength` on a string |
| `too_short`, `too_long` | `@minLength` / `@maxLength` on an array |
| `bytes_too_short`, `bytes_too_long` | `@minLength` / `@maxLength` on one `UploadedFile` |
| `greater_than_equal`, `less_than_equal` | outside `@inRange` |
| `value_error` | one of [your text types](requests.md#your-own-types-uuids-dates-money) refused the value |
| `json_invalid` | the body is not valid JSON |
| `string_unicode` | text that is not valid UTF-8 |
| `percent_encoding` | a bad `%xx` in the path or query |
| `too_many_errors` | more than 16 errors |

## Other errors

| Status | Cause |
|--------|-------|
| 400 | malformed HTTP |
| 404, 405 | no route; route exists for other methods ([routing.md](routing.md)) |
| 413 | body above `limits.maxBodyBytes` (1 MiB by default) |
| 414 | request target above `limits.maxTargetBytes` (4 KiB) |
| 415 | `Form!T` with a content type it does not accept (urlencoded or multipart for text; multipart only when a field is `UploadedFile`) |
| 431 | request head above `limits.maxHeadBytes` (8 KiB) |
| 500 | an uncaught exception, an invalid response header, a missing `Local!T` |
| 503 | the worker is at `maxInFlight`; sent with `Retry-After` |
| 504 | the handler did not start its response within `requestTimeoutMs` |

Your own errors: `throw new HttpError(status, "message")` gives `{"detail":"message"}` with that status. To change how errors
look, use `app.onError` ([middleware.md](middleware.md#error-handling)).

## Signature mistakes are compile errors

An invalid handler fails to compile with one line that says what to fix:

```
app.d(12): vela: handler 'list' in GET /users: parameter 'body_' is JsonBody, but GET has no body; use POST, PUT or PATCH
```

Among the rules: every `{param}` needs a parameter of that name, one body per handler, no body on GET, supported return
types only, `@status(204)` only without a body.
