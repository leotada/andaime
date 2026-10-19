/// The OpenAPI document as a snapshot: the HTTP contract, in `tests/openapi.json`, in review. A change to a handler's
/// signature, a DTO or a status changes the document, this test fails, and the diff of the file shows what the clients of
/// the API will see. The same file feeds the frontend's types (`npx openapi-typescript tests/openapi.json -o api.d.ts`).
///
///     UPDATE_OPENAPI=1 dub test      accept the change: rewrites tests/openapi.json (commit it)
///     andaime openapi                prints the same document
module tests.openapi 2025;

@safe:

import app : buildAppWith, memoryAdapters;
import std.file : exists, readText, write;
import std.path : buildPath, dirName;
import std.process : environment;

/// Next to this file, wherever the test is compiled from.
enum snapshot = buildPath(dirName(__FILE_FULL_PATH__), "openapi.json");

unittest // the app's OpenAPI document is the one in tests/openapi.json
{
    auto now = buildAppWith(memoryAdapters()).openApiDocument(true) ~ "\n";
    immutable update = environment.get("UPDATE_OPENAPI", "");
    if (update.length && update != "0")
    {
        write(snapshot, now);
        return;
    }
    if (!exists(snapshot))
    {
        // a new project has no snapshot yet: the first run makes it, except in CI where nobody would commit it
        assert(environment.get("CI", "").length == 0, "tests/openapi.json is missing: run `UPDATE_OPENAPI=1 dub test` and commit it");
        write(snapshot, now);
        return;
    }
    assert(now == readText(snapshot), "the API contract changed: tests/openapi.json is out of date. If that is intended, run "
        ~ "`UPDATE_OPENAPI=1 dub test` and commit the new file");
}
