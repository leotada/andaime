/// `app.validationMessages`: the 422's messages in another language. A catalog keyed by `FieldError.type` that uses
/// `FieldError.params`, one test per built-in rule type. Without it the text is the English one, byte for byte.
module validation_messages 2025;

@safe:

import andaime;
import andaime.web.testing;
import std.json : parseJSON;

enum Color { red, green }

struct Person
{
    @minLength(3) @maxLength(5) string name;
    @minLength(1) @maxLength(2) int[] tags;
    @inRange(1, 120) int age;
}

struct Wrapper { Person inner; string[] list; Color color; }
struct Scores { int[string] scores; }
struct Ratio { @inRange(0.5, 2.5) double r; }
struct Upload { @minLength(2) @maxLength(4) UploadedFile file; }

string person(JsonBody!Person p) => p.value.name;
string wrapper(JsonBody!Wrapper w) => "ok";
string ints(int n, bool flag, double x, Color color, Uuid id, string s) => "ok";
string ratio(Query!Ratio q) => "ok";
string upload(Form!Upload f) => "ok";
string scores(JsonBody!Scores s) => "ok";
string tooMany(JsonBody!(int[]) xs) => "ok";

/// A Brazilian Portuguese catalog: the `type` picks the sentence, `params` fills the numbers.
string ptBR(ref const FieldError e)
{
    import std.conv : to;

    switch (e.type)
    {
        case "missing": return e.location == "body" && e.locJson.length == 0 ? "corpo JSON obrigatório" : "campo obrigatório";
        case "string_too_short": return "mínimo de " ~ e.params.limit.to!string ~ " caracteres";
        case "string_too_long": return "máximo de " ~ e.params.limit.to!string ~ " caracteres";
        case "too_short": return "mínimo de " ~ e.params.limit.to!string ~ " itens";
        case "too_long": return "máximo de " ~ e.params.limit.to!string ~ " itens";
        case "bytes_too_short": return "mínimo de " ~ e.params.limit.to!string ~ " bytes";
        case "bytes_too_long": return "máximo de " ~ e.params.limit.to!string ~ " bytes";
        case "greater_than_equal": return "deve ser >= " ~ e.params.bound.to!string;
        case "less_than_equal": return "deve ser <= " ~ e.params.bound.to!string;
        case "int_parsing": return "esperado um inteiro entre " ~ e.params.min.to!string ~ " e " ~ e.params.max.to!string;
        case "bool_parsing": return "esperado verdadeiro ou falso";
        case "float_parsing": return "esperado um número";
        case "enum":
            string r = "esperado um de: ";
            foreach (k, w; e.params.allowed)
                r ~= (k ? ", " : "") ~ w;
            return r;
        case "value_error": return "valor inválido";
        case "percent_encoding": return "codificação percentual inválida";
        case "string_unicode": return "UTF-8 inválido";
        case "string_type": return "esperado um texto";
        case "dict_type", "model_type": return "esperado um objeto";
        case "list_type": return "esperado uma lista";
        case "json_invalid": return "JSON inválido";
        case "too_many_errors": return e.params.count.to!string ~ " erros a mais não mostrados";
        default: return e.message;
    }
}

App build(bool translated)
{
    auto app = new App;
    if (translated)
        app.validationMessages(&ptBR);
    app.post!("/person", person);
    app.post!("/wrapper", wrapper);
    app.get!("/ints", ints);
    app.get!("/ratio", ratio);
    app.post!("/upload", upload);
    app.post!("/many", tooMany);
    app.post!("/scores", scores);
    return app;
}

private string msgs(TestResponse r) @system
{
    string o;
    foreach (e; parseJSON(r.body)["detail"].array)
        o ~= (o.length ? " | " : "") ~ e["type"].str ~ ": " ~ e["msg"].str;
    return o;
}

private string[] field(string name, string body, string filename = null)
{
    return [name, body, filename];
}

private string multipart(string[][] parts...)
{
    string b;
    foreach (p; parts)
        b ~= "--z\r\nContent-Disposition: form-data; name=\"" ~ p[0] ~ "\"" ~ (p[2] ? "; filename=\"" ~ p[2] ~ "\"" : "")
            ~ "\r\n\r\n" ~ p[1] ~ "\r\n";
    return b ~ "--z--\r\n";
}

@system unittest // every length, count and range rule, in the body
{
    auto en = TestClient(build(false)), pt = TestClient(build(true));
    enum json = hdr("Content-Type", "application/json");

    auto bad = `{"name":"ab","tags":[],"age":0}`;
    assert(msgs(en.post("/person", bad)) == "string_too_short: expected at least 3 characters | too_short: expected at least 1 items"
        ~ " | greater_than_equal: must be >= 1");
    assert(msgs(pt.post("/person", bad)) == "string_too_short: mínimo de 3 caracteres | too_short: mínimo de 1 itens"
        ~ " | greater_than_equal: deve ser >= 1");

    bad = `{"name":"abcdef","tags":[1,2,3],"age":121}`;
    assert(msgs(en.post("/person", bad)) == "string_too_long: expected at most 5 characters | too_long: expected at most 2 items"
        ~ " | less_than_equal: must be <= 120");
    assert(msgs(pt.post("/person", bad)) == "string_too_long: máximo de 5 caracteres | too_long: máximo de 2 itens"
        ~ " | less_than_equal: deve ser <= 120");
    assert(pt.post("/person", `{"name":"abcd","tags":[1],"age":30}`).status == 200);
}

@system unittest // a fractional bound is a double, not rounded
{
    auto pt = TestClient(build(true));
    assert(msgs(pt.get("/ratio?r=0.1")) == "greater_than_equal: deve ser >= 0.5");
    assert(msgs(pt.get("/ratio?r=3")) == "less_than_equal: deve ser <= 2.5");
}

@system unittest // the type errors of a parameter: path, query, header and cookie share them
{
    auto en = TestClient(build(false)), pt = TestClient(build(true));
    auto url = "/ints?n=x&flag=maybe&x=abc&color=blue&id=nope&s=%ff";
    assert(msgs(en.get(url)) == "int_parsing: expected an integer between -2147483648 and 2147483647"
        ~ " | bool_parsing: expected true or false | float_parsing: expected a number | enum: expected one of: red, green"
        ~ " | value_error: expected a UUID (8-4-4-4-12 hexadecimal digits) | string_unicode: invalid UTF-8", msgs(en.get(url)));
    assert(msgs(pt.get(url)) == "int_parsing: esperado um inteiro entre -2147483648 e 2147483647"
        ~ " | bool_parsing: esperado verdadeiro ou falso | float_parsing: esperado um número"
        ~ " | enum: esperado um de: red, green | value_error: valor inválido | string_unicode: UTF-8 inválido", msgs(pt.get(url)));

    assert(msgs(pt.get("/ints")) == "missing: campo obrigatório | missing: campo obrigatório | missing: campo obrigatório"
        ~ " | missing: campo obrigatório | missing: campo obrigatório | missing: campo obrigatório");
    assert(msgs(en.get("/ints?n=1&flag=true&x=1&color=red&id=123e4567-e89b-12d3-a456-426614174000&s=%zz"))
        == "percent_encoding: invalid percent-encoding");
    assert(msgs(pt.get("/ints?n=1&flag=true&x=1&color=red&id=123e4567-e89b-12d3-a456-426614174000&s=%zz"))
        == "percent_encoding: codificação percentual inválida");
}

@system unittest // the shape errors of a JSON body, and the body that is not there
{
    auto en = TestClient(build(false)), pt = TestClient(build(true));

    auto bad = `{"inner":5,"list":{},"color":7}`;
    assert(msgs(en.post("/wrapper", bad)) == "model_type: expected an object | list_type: expected an array"
        ~ " | enum: expected one of: red, green", msgs(en.post("/wrapper", bad)));
    assert(msgs(pt.post("/wrapper", bad)) == "model_type: esperado um objeto | list_type: esperado uma lista"
        ~ " | enum: esperado um de: red, green");
    assert(msgs(pt.post("/wrapper", `{"inner":{"name":"abc","tags":[1],"age":"x"},"list":[1],"color":"red"}`))
        == "int_parsing: esperado um inteiro entre -2147483648 e 2147483647 | greater_than_equal: deve ser >= 1"
        ~ " | string_type: esperado um texto"); // (a field that failed to parse keeps its default, which the rules judge)
    assert(msgs(en.post("/scores", `{"scores":[1]}`)) == "dict_type: expected an object");
    assert(msgs(pt.post("/scores", `{"scores":[1]}`)) == "dict_type: esperado um objeto");
    assert(msgs(pt.post("/many", `{}`)) == "list_type: esperado uma lista");
    assert(msgs(en.post("/many", `{"a":`)).length > 0 && msgs(pt.post("/many", `{"a":`)) == "json_invalid: JSON inválido");
    assert(msgs(pt.post("/person", `{}`)) == "missing: campo obrigatório | missing: campo obrigatório | missing: campo obrigatório");
    assert(msgs(en.post("/person", ``)) == "missing: JSON body required");
    assert(msgs(pt.post("/person", ``)) == "missing: corpo JSON obrigatório");
}

@system unittest // bytes of an uploaded file
{
    auto en = TestClient(build(false)), pt = TestClient(build(true));
    auto mp = hdr("Content-Type", "multipart/form-data; boundary=z");
    assert(msgs(en.post("/upload", multipart(field("file", "x", "a.bin")), mp)) == "bytes_too_short: expected at least 2 bytes");
    assert(msgs(pt.post("/upload", multipart(field("file", "x", "a.bin")), mp)) == "bytes_too_short: mínimo de 2 bytes");
    assert(msgs(pt.post("/upload", multipart(field("file", "12345", "a.bin")), mp)) == "bytes_too_long: máximo de 4 bytes");
}

@system unittest // errors past the capacity
{
    auto en = TestClient(build(false)), pt = TestClient(build(true));
    string xs = "[";
    foreach (i; 0 .. 20)
        xs ~= (i ? "," : "") ~ `"x"`;
    xs ~= "]";
    auto last = parseJSON(en.post("/many", xs).body)["detail"].array[$ - 1];
    assert(last["type"].str == "too_many_errors" && last["msg"].str == "4 more errors not shown");
    last = parseJSON(pt.post("/many", xs).body)["detail"].array[$ - 1];
    assert(last["type"].str == "too_many_errors" && last["msg"].str == "4 erros a mais não mostrados");
}

@system unittest // the messages reach errorBody's ErrorInfo.message and a group's validation handler
{
    struct Out { string message; }
    auto app = new App;
    app.validationMessages(&ptBR);
    app.errorBody((ref const ErrorInfo e) => Out(e.message));
    app.post!("/person", person);
    auto c = TestClient(app);
    assert(c.post("/person", `{"name":"ab","tags":[1],"age":30}`).body == `{"message":"body.name: mínimo de 3 caracteres"}`);

    auto g = new App;
    g.validationMessages(&ptBR);
    string seen;
    g.onValidationError((Context ctx, ValidationErrors errors) {
        foreach (ref e; errors.items)
            seen ~= e.type ~ "=" ~ e.message ~ ";";
        ctx.response.body.put("custom");
    });
    g.post!("/person", person);
    auto r = TestClient(g).post("/person", `{"name":"ab","tags":[1],"age":0}`);
    assert(r.body == "custom" && seen == "string_too_short=mínimo de 3 caracteres;greater_than_equal=deve ser >= 1;", seen);
}

unittest // params are there for the app's own handler, translated or not
{
    auto app = new App;
    const(FieldError)[] got;
    app.onValidationError((Context ctx, ValidationErrors errors) @trusted {
        got = errors.items.dup;
        ctx.response.body.put("x");
    });
    app.post!("/person", person);
    TestClient(app).post("/person", `{"name":"ab","tags":[1,2,3],"age":500}`);
    assert(got.length == 3);
    assert(got[0].type == "string_too_short" && got[0].params.limit == 3);
    assert(got[1].type == "too_long" && got[1].params.limit == 2);
    assert(got[2].type == "less_than_equal" && got[2].params.bound == 120);
}
