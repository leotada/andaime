/// `Timestamp` and `CalendarDate` from `andaime.values` through path, query, form, JSON, the 422 body and OpenAPI.
module time_values 2025;

@safe:

import andaime;
import andaime.web.testing;
import std.json : parseJSON;

struct Meeting { string title; Timestamp startsAt; CalendarDate day; Optional!Timestamp endedAt; }
struct Range { CalendarDate from; Timestamp until; }

string onDay(CalendarDate day) => day.toString ~ " is day " ~ cast(char)('0' + day.day % 10);
string at(Timestamp at) => at.toString ~ " = " ~ at.utc.toString;
string between(Query!Range r) => r.from.toString ~ ".." ~ r.until.toString;
string book(Form!Range r) => r.from.toString ~ ".." ~ r.until.toString;
Meeting echo(JsonBody!Meeting m) => m.value;

App build()
{
    auto app = new App;
    app.get!("/day/{day}", onDay);
    app.get!("/at", at);
    app.get!("/between", between);
    app.post!("/book", book);
    app.post!("/meeting", echo);
    app.serveOpenApi(OpenApiInfo("T", "1"));
    return app;
}

unittest
{
    auto c = TestClient(build());
    assert(c.get("/day/2024-02-29").body == "2024-02-29 is day 9");

    // `+` in a query string is a space: an offset is sent as %2B (a space before the time is accepted, as Postgres prints)
    assert(c.get("/at?at=2026-10-19T17:30:00%2B05:30").body == "2026-10-19T17:30:00+05:30 = 2026-10-19T12:00:00Z");
    assert(c.get("/at?at=2026-10-19+12:00:00.250Z").body == "2026-10-19T12:00:00.25Z = 2026-10-19T12:00:00.25Z");
    assert(c.get("/between?from=2026-01-01&until=2026-01-31T23:59:59-03:00").body
        == "2026-01-01..2026-01-31T23:59:59-03:00");
    assert(c.post("/book", "from=2026-01-01&until=2026-01-02T00:00:00Z",
        hdr("Content-Type", "application/x-www-form-urlencoded")).body == "2026-01-01..2026-01-02T00:00:00Z");

    // JSON in and out: strings, the offset kept, the fraction trimmed, null for an empty Optional
    auto r = c.post("/meeting", `{"title":"standup","startsAt":"2026-10-19 09:00:00.500000-03","day":"2026-10-19",`
        ~ `"endedAt":null}`);
    assert(r.status == 200);
    assert(r.body == `{"title":"standup","startsAt":"2026-10-19T09:00:00.5-03:00","day":"2026-10-19","endedAt":null}`, r.body);
    r = c.post("/meeting", `{"title":"x","startsAt":"2026-10-19T12:00:00Z","day":"2026-10-19","endedAt":"2026-10-19T13:00:00Z"}`);
    assert(r.status == 200 && parseJSON(r.body)["endedAt"].str == "2026-10-19T13:00:00Z");
}

unittest
{
    auto c = TestClient(build());

    // invalid text: value_error with the type's one-line message
    auto r = c.get("/day/2023-02-29");
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"value_error","loc":["path","day"],"msg":"expected a date like 2026-10-19 (YYYY-MM-DD)"}]}`,
        r.body);
    r = c.get("/at?at=2026-10-19T12:00:00");
    assert(r.body == `{"detail":[{"type":"value_error","loc":["query","at"],`
        ~ `"msg":"expected a date-time with an offset, like 2026-10-19T12:00:00Z"}]}`, r.body);
    r = c.post("/meeting", `{"title":"x","startsAt":"2026-10-19T24:00:00Z","day":20261019}`);
    assert(r.status == 422);
    assert(r.body == `{"detail":[{"type":"value_error","loc":["body","startsAt"],`
        ~ `"msg":"expected a date-time with an offset, like 2026-10-19T12:00:00Z"},`
        ~ `{"type":"string_type","loc":["body","day"],"msg":"expected a string"}]}`, r.body);
}

@system unittest
{
    auto c = TestClient(build());
    auto doc = parseJSON(c.get("/openapi.json").body);
    auto day = doc["paths"]["/day/{day}"]["get"]["parameters"].array[0]["schema"];
    assert(day["type"].str == "string" && day["format"].str == "date");
    auto at = doc["paths"]["/at"]["get"]["parameters"].array[0]["schema"];
    assert(at["type"].str == "string" && at["format"].str == "date-time");
    auto m = doc["components"]["schemas"]["Meeting"]["properties"];
    assert(m["startsAt"]["format"].str == "date-time" && m["day"]["format"].str == "date");
}
