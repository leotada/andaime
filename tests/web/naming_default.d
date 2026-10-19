// FLAGS: -version=AndaimeNamingSnakeCase
/// The project-wide default naming (`versions "AndaimeNamingSnakeCase"`): a struct with no andaime attribute is snake_case
/// in JSON (both ways), in `Query!T` and in OpenAPI; its enums too. A type's own `@naming` still wins.
module naming_default 2025;

@safe:

import andaime;
import andaime.web.testing;

// a domain type: no andaime import would be needed to declare it
enum Plan { free, proYearly }
struct Company { long companyId; string displayName; Plan plan; }
struct Search { int pageSize = 20; string nameStartsWith; }
@naming(Naming.asIs) struct Legacy { long companyId; }

Company create(JsonBody!Company c) => c.value;
string search(Query!Search q) => q.value.nameStartsWith ~ "/" ~ itoaSmall(q.value.pageSize);
Legacy legacy() => Legacy(3);

string itoaSmall(int n) => n == 5 ? "5" : n == 20 ? "20" : "?";

App build()
{
    auto app = new App;
    app.post!("/companies", create);
    app.get!("/companies", search);
    app.get!("/legacy", legacy);
    app.serveOpenApi(OpenApiInfo("T", "1"));
    return app;
}

unittest
{
    static assert(defaultNaming == Naming.snakeCase || defaultNaming == Naming.asIs);
    version (AndaimeNamingSnakeCase)
    {
        auto c = TestClient(build());
        auto r = c.post("/companies", `{"company_id":7,"display_name":"Acme","plan":"pro_yearly"}`);
        assert(r.status == 200 && r.body == `{"company_id":7,"display_name":"Acme","plan":"pro_yearly"}`, r.body);
        assert(c.post("/companies", `{"companyId":7,"displayName":"Acme","plan":"free"}`).status == 422,
            "the D names are not the wire names any more");
        assert(c.get("/companies?page_size=5&name_starts_with=Ac").body == "Ac/5");
        assert(c.get("/legacy").body == `{"companyId":3}`, "an explicit @naming wins");

        auto doc = c.get("/openapi.json").body;
        assert(contains(doc, `"display_name"`) && contains(doc, `"pro_yearly"`) && contains(doc, `"page_size"`), doc);
        assert(!contains(doc, `"displayName"`));
    }
}

bool contains(string s, string part) pure
{
    if (part.length > s.length)
        return false;
    foreach (i; 0 .. s.length - part.length + 1)
        if (s[i .. i + part.length] == part)
            return true;
    return false;
}
