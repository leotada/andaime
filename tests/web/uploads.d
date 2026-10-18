/// Multipart form bodies: text parts and `UploadedFile` fields on `Form!T`.
module uploads_test 2025;

@safe:

import andaime;
import andaime.web.testing;
import std.conv : to;
import std.json : parseJSON;

struct Profile
{
    @minLength(1) string name;
    @maxLength(4) UploadedFile avatar;
    @optional UploadedFile banner;
    @jsonKey("pic") UploadedFile[] photos;
}

struct Note
{
    string text;
    int n;
    string[] tag;
}

struct Sized
{
    @minLength(2) @maxLength(4) UploadedFile file;
}

struct Extra
{
    string title;
    Optional!UploadedFile extra;
}

struct Blob
{
    UploadedFile file;
}

string save(Form!Profile f)
{
    string photos;
    foreach (p; f.photos)
        photos ~= p.filename ~ ",";
    return f.name ~ "|" ~ f.avatar.filename ~ "|" ~ f.avatar.contentType ~ "|" ~ f.avatar.bytes.length.to!string ~ "|"
        ~ f.banner.filename ~ "|" ~ photos;
}

string note(Form!Note f)
{
    string tags;
    foreach (t; f.tag)
        tags ~= t ~ ",";
    return f.text ~ "/" ~ f.n.to!string ~ "/" ~ tags;
}

string sized(Form!Sized f) => f.file.bytes.length.to!string;
string extra(Form!Extra f) => f.title ~ ":" ~ (f.extra.has ? f.extra.get.filename : "-");
string blob(Form!Blob f)
{
    if (f.file.bytes == cast(const(ubyte)[]) "a\0b")
        return "yes";
    if (f.file.bytes == cast(const(ubyte)[]) "xx--z\r\n--zX")
        return "tricky";
    return "no:" ~ f.file.bytes.length.to!string;
}

App build()
{
    auto app = new App;
    app.post!("/profile", save);
    app.post!("/note", note);
    app.post!("/sized", sized);
    app.post!("/extra", extra);
    app.post!("/blob", blob);
    app.serveOpenApi(OpenApiInfo("Up", "1"));
    return app;
}

private string field(string name, string body, string filename = null, string type = null)
{
    string head = "Content-Disposition: form-data; name=\"" ~ name ~ "\"";
    if (filename !is null)
        head ~= "; filename=\"" ~ filename ~ "\"";
    head ~= "\r\n";
    if (type !is null)
        head ~= "Content-Type: " ~ type ~ "\r\n";
    return head ~ "\r\n" ~ body;
}

private string form(string[] parts...)
{
    string b;
    foreach (p; parts)
        b ~= "--z\r\n" ~ p ~ "\r\n";
    return b ~ "--z--\r\n";
}

private HeaderField[] mp() => [hdr("Content-Type", "multipart/form-data; boundary=z")];

unittest
{
    auto c = TestClient(build());
    auto r = c.post("/profile", form(
        field("name", "ana"),
        field("avatar", "png!", "a.png", "image/png"),
        field("pic", "one", "p1.png", "image/png"),
        field("pic", "two", "p2.png")), mp());
    assert(r.status == 200, r.body);
    assert(r.body == "ana|a.png|image/png|4||p1.png,p2.png,", r.body);

    // the first part wins; a missing optional file stays empty; @jsonKey selects the part name
    r = c.post("/profile", form(
        field("name", "bea"),
        field("avatar", "ab", "first.png", "image/png"),
        field("avatar", "cd", "second.png", "image/png"),
        field("banner", "zz", "ban.png", "image/jpeg")), mp());
    assert(r.body == "bea|first.png|image/png|2|ban.png|", r.body);

    r = c.post("/profile", form(field("avatar", "ab", "a.png")), mp());
    assert(r.status == 422, r.body);
    assert(r.body == `{"detail":[{"type":"missing","loc":["body","name"],"msg":"Field required"}]}`, r.body);

    r = c.post("/profile", form(field("name", "ana")), mp());
    assert(r.status == 422 && r.body == `{"detail":[{"type":"missing","loc":["body","avatar"],"msg":"Field required"}]}`, r.body);

    r = c.post("/profile", form(field("name", "ana"), field("avatar", "12345", "big.bin")), mp());
    assert(r.status == 422, r.body);
    assert(r.body == `{"detail":[{"type":"bytes_too_long","loc":["body","avatar"],"msg":"expected at most 4 bytes"}]}`, r.body);

    r = c.post("/sized", form(field("file", "x", "a.bin")), mp());
    assert(r.body == `{"detail":[{"type":"bytes_too_short","loc":["body","file"],"msg":"expected at least 2 bytes"}]}`, r.body);
    assert(c.post("/sized", form(field("file", "abcd", "a.bin")), mp()).body == "4");
    r = c.post("/sized", form(field("file", "ab", "a.bin"), field("file", "wxyz", "b.bin")), mp());
    assert(r.body == "2", "a single file field keeps the first part");

    r = c.post("/profile", form(field("name", ""), field("avatar", "ab", "a.png")), mp());
    assert(r.status == 422 && r.body == `{"detail":[{"type":"string_too_short","loc":["body","name"],"msg":"expected at least 1 characters"}]}`, r.body);

    r = c.post("/extra", form(field("title", "t")), mp());
    assert(r.body == "t:-");
    r = c.post("/extra", form(field("title", "t"), field("extra", "zz", "e.txt", "text/plain")), mp());
    assert(r.body == "t:e.txt");

    assert(c.post("/blob", form(field("file", "a\0b", "b.bin", "application/octet-stream")), mp()).body == "yes");

    // text-only forms accept multipart without percent-decoding, and still accept urlencoded
    r = c.post("/note", form(field("text", "a%20b+c"), field("n", "3"), field("tag", "x"), field("tag", "y")), mp());
    assert(r.body == "a%20b+c/3/x,y,", r.body);
    r = c.post("/note", "text=a%20b+c&n=3&tag=x", hdr("Content-Type", "application/x-www-form-urlencoded"));
    assert(r.body == "a b c/3/x,", r.body);

    r = c.post("/note", form(field("text", "ok"), field("n", "no")), mp());
    assert(r.status == 422 && r.body == `{"detail":[{"type":"int_parsing","loc":["body","n"],"msg":"expected an integer between -2147483648 and 2147483647"}]}`, r.body);

    auto latin = "--z\r\nContent-Disposition: form-data; name=\"text\"\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\n"
        ~ "caf\xE9\r\n--z\r\nContent-Disposition: form-data; name=\"n\"\r\n\r\n1\r\n--z--\r\n";
    r = c.post("/note", latin, mp());
    assert(r.status == 400 && r.body == `{"detail":"unsupported charset in multipart body"}`, r.body);
    auto utf = "--z\r\nContent-Disposition: form-data; name=\"text\"\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n"
        ~ "ok\r\n--z\r\nContent-Disposition: form-data; name=\"n\"\r\n\r\n1\r\n--z--\r\n";
    assert(c.post("/note", utf, mp()).body == "ok/1/");
    auto ascii = "--z\r\nContent-Disposition: form-data; name=\"text\"\r\nContent-Type: text/plain; charset=us-ascii\r\n\r\n"
        ~ "\xFF\r\n--z\r\nContent-Disposition: form-data; name=\"n\"\r\n\r\n1\r\n--z--\r\n";
    r = c.post("/note", ascii, mp());
    assert(r.status == 422 && r.body == `{"detail":[{"type":"string_unicode","loc":["body","text"],"msg":"invalid UTF-8"}]}`, r.body);
    auto fileCharset = "--z\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n"
        ~ "Content-Type: text/plain; charset=iso-8859-1\r\n\r\nhi\r\n--z--\r\n";
    assert(c.post("/blob", fileCharset, mp()).body == "no:2");

    r = c.post("/blob", "file=x", hdr("Content-Type", "application/x-www-form-urlencoded"));
    assert(r.status == 415 && r.body == `{"detail":"expected Content-Type: multipart/form-data"}`, r.body);
    r = c.post("/blob", "{}", hdr("Content-Type", "application/json"));
    assert(r.status == 415 && r.body == `{"detail":"expected Content-Type: multipart/form-data"}`, r.body);
    r = c.post("/blob", "--z\r\nContent-Disposition: form-data; name=\"file\"\r\n\r\nhi", mp());
    assert(r.status == 400 && r.body == `{"detail":"malformed multipart body"}`, r.body);
    r = c.post("/blob", "--z--\r\n", hdr("Content-Type", "multipart/form-data"));
    assert(r.status == 400 && r.body == `{"detail":"multipart body has no boundary"}`, r.body);
    r = c.post("/blob", "--z--\r\n", hdr("Content-Type", "multipart/form-data; boundary=\"a b\""));
    assert(r.status == 400 && r.body == `{"detail":"invalid multipart boundary"}`, r.body);

    string many;
    foreach (i; 0 .. 129)
        many ~= "--z\r\nContent-Disposition: form-data; name=\"file\"; filename=\"f\"\r\n\r\nx\r\n";
    many ~= "--z--\r\n";
    r = c.post("/blob", many, mp());
    assert(r.status == 400 && r.body == `{"detail":"multipart body has too many parts"}`, r.body);

    // embedded delimiter-like bytes stay in the file
    auto tricky = "--z\r\nContent-Disposition: form-data; name=\"file\"; filename=\"t.bin\"\r\n"
        ~ "Content-Type: application/octet-stream\r\n\r\nxx--z\r\n--zX\r\n--z--\r\n";
    r = c.post("/blob", tricky, mp());
    assert(r.status == 200 && r.body == "tricky", r.body);
}

@system unittest
{
    auto c = TestClient(build());
    auto doc = parseJSON(c.get("/openapi.json").body);
    auto profile = doc["paths"]["/profile"]["post"]["requestBody"];
    assert(profile["required"].boolean);
    auto media = profile["content"];
    assert("multipart/form-data" in media.object);
    assert("application/x-www-form-urlencoded" !in media.object);
    auto sch = doc["components"]["schemas"]["Profile"];
    assert(sch["properties"]["avatar"]["type"].str == "string");
    assert(sch["properties"]["avatar"]["format"].str == "binary");
    assert(sch["properties"]["avatar"]["maxLength"].integer == 4);
    assert(sch["properties"]["pic"]["type"].str == "array");
    assert(sch["properties"]["pic"]["items"]["format"].str == "binary");
    bool[string] required;
    foreach (name; sch["required"].array)
        required[name.str] = true;
    assert(required == ["name": true, "avatar": true], required.to!string);

    auto noteBody = doc["paths"]["/note"]["post"]["requestBody"]["content"];
    assert("application/x-www-form-urlencoded" in noteBody.object);
    assert("multipart/form-data" in noteBody.object);
}
