/// TestClient's helpers: multipart bodies, JSON requests and `json!T` responses, and the cookie jar (paths, replacement,
/// deletion by Max-Age and by Expires, merged with a Cookie header of the test's own).
module test_client;

@safe:

import vela;
import vela.web.testing;

struct Upload { @minLength(2) string title; UploadedFile photo; Optional!UploadedFile extra; }
struct NewUser { @minLength(2) string name; int age; }
struct User { long id; string name; int age; }

string upload(Form!Upload f)
{
    return f.title ~ "|" ~ f.photo.filename ~ "|" ~ f.photo.contentType ~ "|" ~ cast(string) f.photo.bytes.idup
        ~ "|" ~ (f.extra.has ? f.extra.get.filename : "-");
}

@status(201) User create(JsonBody!NewUser u) => User(1, u.name, u.age);
User update(long id, JsonBody!NewUser u) => User(id, u.name, u.age);

void login(Context ctx)
{
    setCookie(ctx, "session", "s1");
    CookieOptions admin;
    admin.path = "/admin";
    setCookie(ctx, "admin", "a1", admin);
    ctx.text("in");
}

void logout(Context ctx)
{
    deleteCookie(ctx, "session");
    ctx.text("out");
}

void expire(Context ctx)
{
    CookieOptions o;
    o.expires = Optional!long(1); // 1970: already in the past
    setCookie(ctx, "admin", "", o.withPath("/admin"));
    ctx.text("expired");
}

CookieOptions withPath(CookieOptions o, string p)
{
    o.path = p;
    return o;
}

void rotate(Context ctx)
{
    setCookie(ctx, "session", "s2");
    ctx.text("rotated");
}

string echoCookies(Context ctx) => ctx.request.header("Cookie").idup;

App build()
{
    auto app = new App;
    app.post!("/upload", upload);
    app.put!("/upload", upload);
    app.post!("/users", create);
    app.patch!("/users/{id}", update);
    app.get!("/login", login);
    app.get!("/logout", logout);
    app.get!("/admin/expire", expire);
    app.get!("/rotate", rotate);
    app.get!("/echo", echoCookies);
    app.get!("/admin/echo", echoCookies);
    return app;
}

unittest
{
    auto c = TestClient(build());

    // multipart: text fields and files, binary-safe, with a boundary that appears in no part
    ubyte[] bytes = [0, 1, 2, 0xff, '\r', '\n'];
    auto r = c.postMultipart("/upload", [["title", "Trip --vela-test-boundary-7MA4YWxkTrZu0gW"]],
        [TestFile("photo", "a.jpg", "image/jpeg", bytes)]);
    assert(r.status == 200, r.body);
    assert(r.body == "Trip --vela-test-boundary-7MA4YWxkTrZu0gW|a.jpg|image/jpeg|" ~ cast(string) bytes.idup ~ "|-", r.body);
    r = c.putMultipart("/upload", [["title", "Two"]], [TestFile("photo", "p.png", "image/png", [1]),
        TestFile("extra", "e.txt", "text/plain", cast(const(ubyte)[]) "x")]);
    assert(r.status == 200 && r.body[$ - 5 .. $] == "e.txt", r.body);
    r = c.postMultipart("/upload", [["title", "x"]]);
    assert(r.status == 422 && r.json["detail"].length == 2, r.body); // title too short, photo missing

    // JSON in and out
    r = c.postJson("/users", NewUser("Ana", 31));
    assert(r.status == 201 && r.json!User == User(1, "Ana", 31));
    r = c.patchJson("/users/7", `{"name":"Bia","age":20}`); // JSON text goes as is
    assert(r.json!User.id == 7 && r.json["name"].asString == "Bia");
    r = c.putJson("/users/7", NewUser("Bia", 20)); // no PUT route: 405
    assert(r.status == 405);
    r = c.postJson("/users", NewUser("A", 1));
    assert(r.status == 422);
    bool threw;
    try
        r.json!User; // the 422 body is not a User
    catch (JsonError)
        threw = true;
    assert(threw);
}

unittest
{
    // off by default: nothing is kept
    auto plain = TestClient(build());
    plain.get("/login");
    assert(plain.get("/echo").body == "" && plain.cookie("session") is null);

    auto c = TestClient(build());
    c.cookies = true;
    c.get("/login");
    assert(c.cookie("session") == "s1" && c.cookie("admin") == "a1");
    assert(c.get("/echo").body == "session=s1", "the /admin cookie stays out of /echo");
    assert(c.get("/admin/echo").body == "session=s1; admin=a1");
    assert(c.get("/echo", hdr("Cookie", "theme=dark")).body == "theme=dark; session=s1", "merged with the test's own");

    c.get("/rotate");
    assert(c.cookie("session") == "s2" && c.get("/echo").body == "session=s2", "replaced, not duplicated");

    c.get("/admin/expire");
    assert(c.cookie("admin") is null, "Expires in the past deletes it");
    c.get("/logout");
    assert(c.cookie("session") is null && c.get("/echo").body == "", "Max-Age=0 deletes it");

    c.get("/login");
    c.clearCookies();
    assert(c.get("/admin/echo").body == "");
}
