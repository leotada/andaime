/// Recursos da camada web que uma aplicação real usa: grupos com middleware,
/// ctx.locals / Local!T, onError, onNotFound, barra final e CORS.
module features;

import vela;
import vela.web.testing;

struct User { int id; string name; }

string hi() => "hi";
string me(Local!User u) => u.name;
string boom() { throw new Exception("segredo interno"); }
string denied() { throw new HttpError(403, "proibido"); }
string orphan(Local!User u) => u.name;
string echo(string x) => x;
string id(int n) => "id=" ~ (n < 10 ? "0" : "") ~ "x";

App build(ref string[] trace)
{
    auto app = new App;
    app.redirectTrailingSlash = true;
    app.use(cors(CorsConfig(["https://app.exemplo.com"], "GET, POST", null, "X-Total", true)));
    app.use((Context c, Next n) { trace ~= "app>"; n(); trace ~= "<app"; });

    app.get!("/hi", hi);
    app.get!("/boom", boom);
    app.get!("/denied", denied);
    app.get!("/orphan", orphan);

    auto api = app.group("/api");
    api.use((Context c, Next n) { trace ~= "api>"; n(); trace ~= "<api"; });
    api.get!("/hi", hi);
    api.get!("/", hi);

    auto admin = api.group("/admin");
    admin.use((Context c, Next n) {
        auto tok = c.request.header("Authorization");
        if (tok != "Bearer ok")
            throw new HttpError(401, "faltou o token");
        c.locals.set(User(1, "ana"));
        trace ~= "admin>";
        n();
    });
    admin.get!("/me", me);
    admin.get!("/x/{x}", echo);
    return app;
}

unittest
{
    string[] trace;
    auto c = TestClient(build(trace));

    // grupo: prefixo + middleware só nas rotas do grupo
    auto r = c.get("/hi");
    assert(r.status == 200 && r.body == "hi");
    assert(trace == ["app>", "<app"], "middleware do grupo vazou para fora");
    trace = null;
    r = c.get("/api/hi");
    assert(r.status == 200 && r.body == "hi");
    assert(trace == ["app>", "api>", "<api", "<app"], trace[0]);
    assert(c.get("/api").body == "hi", "'/' do grupo vira o próprio prefixo");

    // subgrupo herda middlewares e usa locals
    assert(c.get("/api/admin/me").status == 401);
    trace = null;
    r = c.get("/api/admin/me", hdr("Authorization", "Bearer ok"));
    assert(r.status == 200 && r.body == "ana");
    assert(trace == ["app>", "api>", "admin>", "<api", "<app"]);
    assert(c.get("/api/admin/x/abc", hdr("Authorization", "Bearer ok")).body == "abc");

    // Local!T sem middleware: erro de configuração, 500 sem vazar detalhes
    r = c.get("/orphan");
    assert(r.status == 500 && r.body == `{"detail":"erro interno"}`);

    // locals não vazam entre requisições
    c.get("/api/admin/me", hdr("Authorization", "Bearer ok"));
    assert(c.get("/orphan").status == 500);

    // barra final
    r = c.get("/hi/?a=1");
    assert(r.status == 308 && r.header("Location") == "/hi?a=1", r.header("Location"));
    r = c.get("/api/");
    assert(r.status == 308 && r.header("Location") == "/api");
    assert(c.get("/nada/").status == 404); // nem com nem sem barra: 404 normal
    assert(c.get("/api/hi/").status == 308);
}

unittest
{
    string[] trace;
    auto c = TestClient(build(trace));
    string ori = "https://app.exemplo.com";

    // sem Origin: nenhum header CORS
    auto r = c.get("/hi");
    assert(r.header("Access-Control-Allow-Origin") is null);

    // origem permitida
    r = c.get("/hi", hdr("Origin", ori));
    assert(r.status == 200);
    assert(r.header("Access-Control-Allow-Origin") == ori && r.header("Vary") == "Origin");
    assert(r.header("Access-Control-Allow-Credentials") == "true");
    assert(r.header("Access-Control-Expose-Headers") == "X-Total");

    // origem desconhecida: sem headers (o navegador bloqueia)
    r = c.get("/hi", hdr("Origin", "https://mal.com"));
    assert(r.status == 200 && r.header("Access-Control-Allow-Origin") is null);

    // preflight de uma rota que só existe para GET: 204 sem passar pelo roteador
    r = c.send(Method.OPTIONS, "/hi", null, [hdr("Origin", ori), hdr("Access-Control-Request-Method", "POST"),
        hdr("Access-Control-Request-Headers", "content-type,authorization")]);
    assert(r.status == 204, "preflight");
    assert(r.header("Access-Control-Allow-Methods") == "GET, POST");
    assert(r.header("Access-Control-Allow-Headers") == "content-type,authorization");
    assert(r.header("Access-Control-Max-Age") == "600");
    assert(r.body.length == 0);
}

unittest
{
    string[] trace;
    auto app = build(trace);
    app.onError((Context ctx, Exception e) {
        if (auto he = cast(HttpError) e)
            ctx.text("http:" ~ he.msg, he.status);
        else
            ctx.text("falha", 500);
    });
    app.onNotFound((Context ctx) { ctx.text("sumiu", 404); });
    auto c = TestClient(app);

    auto r = c.get("/boom");
    assert(r.status == 500 && r.body == "falha", "detalhes internos não devem vazar");
    r = c.get("/denied");
    assert(r.status == 403 && r.body == "http:proibido");
    r = c.get("/nao-existe");
    assert(r.status == 404 && r.body == "sumiu");
    // exceção lançada por middleware também passa pelo onError
    r = c.get("/api/admin/me");
    assert(r.status == 401 && r.body == "http:faltou o token");
}

unittest
{
    // prefixo inválido é erro de startup com mensagem clara
    auto app = new App;
    foreach (bad; ["api", "/api/", "/o/{id}"])
    {
        bool threw;
        try app.group(bad);
        catch (Exception e) threw = true;
        assert(threw, bad);
    }
}

unittest
{
    // requestId + accessLog + bearerToken
    string seen;
    auto app = new App;
    app.use(requestId());
    app.use(accessLog());
    app.get!("/rid", (Local!RequestId r) => cast(string) r.value.idup);
    app.get!("/tok", (Context c) => bearerToken(c).idup);
    auto c = TestClient(app);

    auto r = c.get("/rid");
    assert(r.body.length == 16 && r.header("X-Request-Id") == r.body);
    auto r2 = c.get("/rid");
    assert(r2.body != r.body, "ids deveriam variar");
    r = c.get("/rid", hdr("X-Request-Id", "abc-123"));
    assert(r.body == "abc-123" && r.header("X-Request-Id") == "abc-123");
    r = c.get("/rid", hdr("X-Request-Id", "evil\r\nSet-Cookie: x"));
    assert(r.body.length == 16, "id inseguro deve ser descartado");

    assert(c.get("/tok", hdr("Authorization", "Bearer abc.def")).body == "abc.def");
    assert(c.get("/tok").body == "");
    assert(c.get("/tok", hdr("Authorization", "Basic xyz")).body == "");
}
