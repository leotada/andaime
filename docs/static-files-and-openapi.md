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
- Schema names are the struct names. Two structs with the same name in different modules get different names (the second uses
  its module path); template instances become `Page_User`; `@schemaName("UserOut")` picks a name.
- [Text types](requests.md#your-own-types-uuids-dates-money) are strings, with `format` from their `openApiFormat`.

`OpenApiInfo` fields: `title`, `version_`, `description`, `jsonPath` (`"/openapi.json"`; `""` = not served), `docsPath`
(`"/docs"`; `""` = no Swagger UI page), `swaggerUiBase`. `/docs` loads Swagger UI from a pinned jsDelivr release with
Subresource Integrity; set `swaggerUiBase` to a URL of your own copy to self-host it.
