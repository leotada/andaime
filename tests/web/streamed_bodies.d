/// Large request bodies read as they arrive: `BodyStream`, `SpooledFile`, and the routes that still get them whole.
/// `TestClient` hands a body above `bufferBodyBytes` over through `Request.bodyReader`, in small pieces, as the engine does.
module streamed_bodies_test 2025;

@safe:

import andaime;
import andaime.web.testing;
import std.conv : to;
import std.file : exists, mkdirRecurse, read, rmdirRecurse, tempDir, dirEntries, SpanMode;
import std.path : buildPath;

struct Upload
{
    Optional!string folder;
    SpooledFile[] files;
}

struct Capped
{
    @maxLength(500_000) SpooledFile file;
}

string capped(Form!Capped form) => form.file.size.to!string;

struct One
{
    SpooledFile file;
    string note;
}

struct Payload
{
    string text;
}

/// What the middleware saw: the length of `request.body` and whether the body was still unread.
string seenByMiddleware;

void watch(Context ctx, Next next)
{
    seenByMiddleware = ctx.request.body.length.to!string ~ "/" ~ (ctx.request.bodyReader !is null ? "stream" : "buffered");
    next();
}

ulong checksum(scope const(ubyte)[] b)
{
    ulong s;
    foreach (i, x; b)
        s += x * (i % 7 + 1);
    return s;
}

/// Reads the body in 1000-byte pieces: its length and checksum.
string consume(BodyStream body)
{
    ubyte[1000] buf;
    ubyte[] all;
    size_t n;
    immutable before = body.unread;
    while ((n = body.read(buf[])) > 0)
        all ~= buf[0 .. n];
    return before.to!string ~ ":" ~ all.length.to!string ~ ":" ~ checksum(all).to!string ~ ":" ~ body.unread.to!string;
}

string firstBytes(BodyStream body)
{
    ubyte[3] buf;
    return (cast(const(char)[]) buf[0 .. body.read(buf[])]).idup;
}

string json(JsonBody!Payload p) => p.text.length.to!string;

string raw(Context ctx) => ctx.request.body.length.to!string;

string describe(const SpooledFile f) @trusted
{
    auto b = f.bytes;
    return f.filename ~ "," ~ f.size.to!string ~ "," ~ (f.onDisk ? "disk" : "memory") ~ ","
        ~ (f.onDisk ? (exists(f.path) ? "exists" : "gone") : "-") ~ "," ~ checksum(b).to!string;
}

string upload(Form!Upload form)
{
    string r = form.folder.has ? form.folder.get : "-";
    foreach (ref f; form.files)
        r ~= "|" ~ describe(f);
    return r;
}

string[] pathsSeen;

string keepPath(Form!One form) @trusted
{
    pathsSeen ~= form.file.path;
    return form.note ~ ":" ~ describe(form.file);
}

string moveTo;

string move(Form!One form)
{
    form.file.moveTo(moveTo);
    return form.file.size.to!string;
}

string readInPieces(Form!One form)
{
    auto r = form.file.open();
    ubyte[777] buf;
    ubyte[] all;
    size_t n;
    while ((n = r.read(buf[])) > 0)
        all ~= buf[0 .. n];
    return all.length.to!string ~ ":" ~ checksum(all).to!string;
}

/// Forwards the upload with the HTTP client (to a FakeHttpClient), from the spooled file, and checks what arrived.
string forward(Form!One form)
{
    auto fake = new FakeHttpClient;
    fake.expect("PUT", "https://bucket.example.com/f").respond(200);
    fake.install();
    scope (exit)
        fake.uninstall();
    httpClient().put("https://bucket.example.com/f", form.file.bodySource());
    auto sent = fake.requests[0].body_;
    return (form.file.onDisk ? "disk:" : "memory:") ~ sent.length.to!string ~ ":" ~ checksum(sent).to!string;
}

final class Files
{
    @Post("/files") string send(Form!Upload form) => upload(form);
}

App build(string spoolDir)
{
    auto app = new App;
    app.use(&watch);
    app.spoolUploads(SpoolConfig(64 << 10, spoolDir));
    app.post!("/consume", consume);
    app.post!("/first", firstBytes);
    app.post!("/json", json);
    app.post!("/raw", raw);
    app.post!("/upload", upload);
    app.post!("/keep", keepPath);
    app.post!("/move", move);
    app.post!("/pieces", readInPieces);
    app.post!("/forward", forward);
    app.post!("/capped", capped);
    app.group("/c").mount(new Files);
    return app;
}

private string bigText(size_t n)
{
    auto b = new char[n];
    foreach (i, ref ch; b)
        ch = cast(char) ('a' + (i * 7 + i / 3) % 26);
    return (() @trusted => cast(string) b)();
}

private string field(string name, string body, string filename = null)
{
    string head = "Content-Disposition: form-data; name=\"" ~ name ~ "\"";
    if (filename !is null)
        head ~= "; filename=\"" ~ filename ~ "\"";
    return head ~ "\r\n\r\n" ~ body;
}

private string form(string[] parts...)
{
    string b;
    foreach (p; parts)
        b ~= "--zzBoundary\r\n" ~ p ~ "\r\n";
    return b ~ "--zzBoundary--\r\n";
}

private HeaderField[] mp() => [hdr("Content-Type", "multipart/form-data; boundary=zzBoundary")];

@system unittest
{
    immutable dir = buildPath(tempDir, "andaime-streamed-bodies-test");
    if (exists(dir))
        rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    size_t leftovers() => dirEntries(dir, SpanMode.shallow).walkLength;

    auto c = TestClient(build(dir));
    immutable big = bigText(600_000); // above bufferBodyBytes (256 KiB): streamed
    immutable sum = checksum(cast(const(ubyte)[]) big).to!string;

    // A route that streams gets the body unread, even past the middleware; the reader sees every byte.
    auto r = c.post("/consume", big);
    assert(r.status == 200 && r.body == "600000:600000:" ~ sum ~ ":0", r.body);
    assert(seenByMiddleware == "0/stream", seenByMiddleware);
    // A small body is buffered, and a BodyStream reads it just the same.
    r = c.post("/consume", "hello");
    assert(r.body == "5:5:" ~ checksum(cast(const(ubyte)[]) "hello").to!string ~ ":0", r.body);
    assert(seenByMiddleware == "5/buffered");
    // A handler may stop early (the server then closes the connection after the response).
    assert(c.post("/first", big).body == big[0 .. 3]);

    // Every other route gets a large body whole, before the middleware: nothing changes for them.
    r = c.post("/json", `{"text":"` ~ big ~ `"}`, hdr("Content-Type", "application/json"));
    assert(r.status == 200 && r.body == "600000", r.body);
    assert(seenByMiddleware == "600011/buffered", seenByMiddleware);
    assert(c.post("/raw", big).body == "600000");

    // SpooledFile: a small part stays in memory, a large one goes to a temporary file that is removed afterwards; the
    // text field after the files is there all the same.
    immutable small = "tiny file";
    r = c.post("/upload", form(field("files", small, "s.txt"), field("files", big, "b.bin"), field("ignored", big),
        field("folder", "docs")), mp());
    assert(r.status == 200, r.body);
    assert(r.body == "docs|s.txt,9,memory,-," ~ checksum(cast(const(ubyte)[]) small).to!string
        ~ "|b.bin,600000,disk,exists," ~ sum, r.body);
    assert(leftovers == 0, "the temporary files outlived the request");

    r = c.post("/keep", form(field("note", "n"), field("file", big, "k.bin")), mp());
    assert(r.body == "n:k.bin,600000,disk,exists," ~ sum, r.body);
    assert(pathsSeen.length == 1 && !exists(pathsSeen[0]) && leftovers == 0);

    // moveTo takes the file: it is a rename in the same directory, and the request does not remove it.
    moveTo = buildPath(dir, "kept.bin");
    r = c.post("/move", form(field("note", "n"), field("file", big, "m.bin")), mp());
    assert(r.body == "600000", r.body);
    assert(exists(moveTo) && checksum(cast(const(ubyte)[]) read(moveTo)).to!string == sum);
    assert(leftovers == 1);
    // ... and writes a file that stayed in memory.
    immutable smallBody = form(field("note", "n"), field("file", small, "m.txt"));
    assert(c.post("/move", smallBody, mp()).body == "9");
    assert(cast(string) read(moveTo) == small);

    assert(c.post("/pieces", form(field("file", big, "p.bin"), field("note", "x")), mp()).body == "600000:" ~ sum);
    auto fwd = c.post("/forward", form(field("note", "n"), field("file", big, "f.bin")), mp());
    assert(fwd.body == "disk:600000:" ~ sum, fwd.status.to!string ~ " " ~ fwd.body);
    assert(c.post("/forward", form(field("note", "n"), field("file", "tiny", "f.bin")), mp()).body
        == "memory:4:" ~ checksum(cast(const(ubyte)[]) "tiny").to!string);

    // limits and errors go through the same rules as a buffered form
    r = c.post("/capped", form(field("file", big, "huge.bin")), mp());
    assert(r.status == 422 && r.body == `{"detail":[{"type":"bytes_too_long","loc":["body","file"],"msg":"expected at most 500000 bytes"}]}`, r.body);
    r = c.post("/keep", form(field("note", "n"), field("other", big)), mp());
    assert(r.status == 422 && r.body == `{"detail":[{"type":"missing","loc":["body","file"],"msg":"Field required"}]}`, r.body);
    r = c.post("/keep", "--zzBoundary\r\n" ~ field("file", big, "k.bin"), mp());
    assert(r.status == 400 && r.body == `{"detail":"malformed multipart body"}`, r.body);
    assert(leftovers == 1, "a failed request leaves its temporary files behind");
    r = c.post("/keep", big, hdr("Content-Type", "application/octet-stream"));
    assert(r.status == 415, r.body);

    // a controller method that takes a SpooledFile form streams too
    r = c.post("/c/files", form(field("files", big, "c.bin")), mp());
    assert(r.status == 200 && r.body == "-|c.bin,600000,disk,exists," ~ sum, r.body);
    assert(seenByMiddleware == "0/stream", seenByMiddleware);

    // HTTP/2 bodies are always buffered: the same form binds from memory
    c.http2 = true;
    r = c.post("/upload", form(field("files", big, "h2.bin")), mp());
    assert(r.body == "-|h2.bin,600000,memory,-," ~ sum, r.body);
}

private size_t walkLength(R)(R r) @system
{
    size_t n;
    foreach (_; r)
        n++;
    return n;
}
