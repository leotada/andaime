# Static files and OpenAPI

## Static files

```d
app.serveStatic("/assets", "public");     // GET /assets/css/site.css -> public/css/site.css
app.serveStatic("", "site");              // the site root: GET / -> site/index.html
api.serveStatic("/files", "uploads");     // on a group: /api/files/...
```

- A weak `ETag` and `Last-Modified`; `If-None-Match` gets a 304 when the client already has the file. `Cache-Control` comes from
  the config.
- A folder serves its `index.html`.
- The content type comes from the file extension.
- Path traversal is refused with a 404: `..`, `\`, NUL, hidden segments (`.env`, `.git`) and symbolic links that lead out of
  the folder.
- Files above 256 KiB are streamed in 64 KiB pieces, each read on the thread pool, so a large download neither blocks the
  worker nor grows memory.
- The folder must exist when the app is built (otherwise `serveStatic` throws).

```d
StaticConfig sc;
sc.cacheControl = "public, max-age=86400";   // default: one hour
sc.index = "";                               // no folder index
sc.maxFileBytes = 100 << 20;                 // above it: 413 (default 1 GiB)
sc.offloadAbove = 256 << 10;                 // files larger than this are streamed
sc.chunkBytes = 64 << 10;
app.serveStatic("/downloads", "files", sc);
```

`Range` requests (resuming downloads, video seeking) are not supported yet.

## OpenAPI and Swagger UI

```d
app.serveOpenApi(OpenApiInfo("My API", "1.0.0", "What this API does"));
```

serves the OpenAPI 3.0.3 document at `/openapi.json` and Swagger UI at `/docs`. The document is built at compile time from the
**same signatures** that generate the dispatch: routes, path/query/header/cookie parameters, request bodies and their schemas,
validation attributes, response types and statuses. There is no second description to keep in sync. Every route of the app is
included, also those registered after `serveOpenApi`.

Refine it with attributes on the handler:

```d
@summary("Create a user")
@status(201)
@responds(409, "e-mail already registered")
@responds(404, "team not found")
User createUser(JsonBody!NewUser body_) { ... }        // documents 201, 404, 409 and 422

@produces("text/csv")
Stream export_() { ... }                               // the media type of a streamed body
```

- 422 is documented automatically for handlers with parameters, with the error format of [validation.md](validation.md).
  With a custom `onValidationError`, the status and schema it declares are documented instead (a generic `4XX` when it
  declares none; see [validation.md](validation.md#your-own-validation-response)). With `app.errorBody`, the 422 and the
  `@responds` errors use its body struct as their schema, and its content type
  ([validation.md](validation.md#one-body-format-for-every-error-errorbody)).
- Schema names are the struct names. Two structs with the same name in different modules get different names (the second uses
  its module path); template instances become `Page_User`; `@schemaName("UserOut")` picks a name.
- An `Optional` field of a body is `nullable`, unless it is `@omitIfAbsent` ([responses.md](responses.md)): then the
  key may be missing but never `null`. A `@strict` body ([requests.md](requests.md)) has `additionalProperties: false`.
- A group's middleware that names a security scheme (`group.use(mw, security)`) adds `security` to the operations it runs
  on, and `OpenApiInfo.securitySchemes` (`bearerScheme()`, `apiKeyScheme(...)`) fills `components.securitySchemes`
  ([middleware.md](middleware.md#a-middleware-for-some-routes-of-a-group)).
- [Text types](requests.md#your-own-types-uuids-dates-money) are strings, with `format` from their `openApiFormat` (`uuid`, `date-time` for a `Timestamp`, `date` for a `CalendarDate`).

## The document as a file, for a typed frontend

A frontend typed from the API needs the document in a file, and a project wants every change to its contract to show in a
code review. The app does not have to run for that:

```sh
andaime openapi > openapi.json          # builds the app once and prints the document (indented), serving nothing
```

or, from a test or a script, `app.openApiDocument()` (`openApiDocument(true)` indents it, one member per line, which makes
a readable diff). It is the document `GET /openapi.json` answers, byte for byte, and also exists for an app that never
called `serveOpenApi`. The order is stable: paths in registration order, schemas by name.

**The frontend side.** Generate the TypeScript types from the file and call the API through them:

```sh
npx openapi-typescript openapi.json -o src/api/schema.d.ts
```

```ts
import createClient from "openapi-fetch";
import type { paths } from "./schema";

const api = createClient<paths>({ baseUrl: "/api/v1" });
const { data, error } = await api.GET("/users/{id}", { params: { path: { id: 7 } } });
// data: the handler's return type; error: the 422 or the errorBody you declared; both checked by tsc
```

A `Timestamp` is a `string` with `format: date-time` and a `Uuid` a `string` with `format: uuid`. Rename a field in a DTO and
`tsc` points at every use in the frontend.

**A snapshot test.** The clean template (`andaime new`) comes with `tests/openapi.json` and `tests/openapi.d`, which
compares the document with the file:

```d
unittest
{
    auto now = buildAppWith(memoryAdapters()).openApiDocument(true) ~ "\n";
    assert(now == readText("tests/openapi.json"), "the API contract changed: run `UPDATE_OPENAPI=1 dub test`");
}
```

Changing a handler's signature, a DTO or a status fails `dub test` until the file is updated, and the update is a diff in
the pull request that the frontend's reviewer reads: `UPDATE_OPENAPI=1 dub test` (or `andaime openapi > tests/openapi.json`)
rewrites it. The first run of a new project creates the file; in CI (`CI` set) a missing file is an error. Outside the
template, write the same test around your own `buildApp`.

`OpenApiInfo` fields: `title`, `version_`, `description`, `jsonPath` (`"/openapi.json"`; `""` = not served), `docsPath`
(`"/docs"`; `""` = no Swagger UI page), `swaggerUiBase`. `/docs` loads Swagger UI from a pinned jsDelivr release with
Subresource Integrity; set `swaggerUiBase` to a URL of your own copy to self-host it.
