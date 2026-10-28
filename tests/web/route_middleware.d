/// One group holds a public and a protected route: `useUnless!Public` / `useOnly!Admin` run a middleware on the routes
/// their marker selects, and OpenAPI lists the security scheme on exactly those operations.
module route_middleware_test 2025;

@safe:

import andaime;
import andaime.web.testing;
import std.json : parseJSON, JSONType;

enum Public;
enum Admin;

int guardRuns;
int adminRuns;

final class Sessions
{
    @Public @Post("/login") string login() => "token";
    @Get("/me") string me() => "ana";
    @Admin @Get("/admin") string admin() => "root";
}

@Public string health() => "ok";

App build()
{
    guardRuns = 0;
    adminRuns = 0;
    auto app = new App;
    auto api = app.group("/api");
    api.useUnless!Public((Context c, Next n) {
        guardRuns++;
        if (c.request.header("Authorization").length == 0)
            c.json(`{"detail":"no token"}`, 401);
        else
            n();
    }, "bearer");
    api.useOnly!Admin((Context c, Next n) { adminRuns++; n(); }, "admin");
    api.mount(new Sessions);
    api.get!("/health", health);
    app.serveOpenApi(OpenApiInfo("R", "1", securitySchemes: [bearerScheme(), apiKeyScheme("admin", "X-Admin")]));
    return app;
}

unittest
{
    auto c = TestClient(build());
    // public routes skip the guard
    assert(c.post("/api/login", "").status == 200 && guardRuns == 0);
    assert(c.get("/api/health").status == 200 && guardRuns == 0);
    // the protected one runs it
    assert(c.get("/api/me").status == 401 && guardRuns == 1);
    assert(c.get("/api/me", HeaderField("Authorization", "Bearer x")).status == 200 && guardRuns == 2);
    // the admin-only middleware runs on /admin alone, after the guard
    assert(adminRuns == 0);
    assert(c.get("/api/admin", HeaderField("Authorization", "Bearer x")).status == 200 && adminRuns == 1);
    assert(c.get("/api/admin").status == 401 && adminRuns == 1); // the guard stopped it first
}

unittest
{
    auto doc = parseJSON(TestClient(build()).get("/openapi.json").body);
    auto paths = doc["paths"];
    assert("security" !in paths["/api/login"]["post"], paths["/api/login"].toString);
    assert("security" !in paths["/api/health"]["get"]);
    assert(paths["/api/me"]["get"]["security"].toString == `[{"bearer":[]}]`, paths["/api/me"].toString);
    auto both = paths["/api/admin"]["get"]["security"][0]; // one requirement object: both schemes (AND)
    assert("bearer" in both && "admin" in both && paths["/api/admin"]["get"]["security"].toString.length > 0, both.toString);
    auto schemes = doc["components"]["securitySchemes"];
    assert(schemes["bearer"]["scheme"].str == "bearer" && schemes["admin"]["in"].str == "header", schemes.toString);
}
