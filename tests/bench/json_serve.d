module json_serve 2025;
/// Server for the JSON load test (tools/json_load.sh): the same work behind two routes, so only the JSON code differs.
///   POST /andaime  body -> Order (andaime's decoder, validation included) -> Order (andaime's writer)
///   POST /stdjson  body -> std.json tree -> Order (copied by hand) -> std.json tree -> text
/// Usage: json_serve [port=18101] [workers=1]
import andaime;
import order;

Order viaAndaime(JsonBody!Order body_) @safe => body_.value;

// std.json is @system (its accessors), and a @system handler is accepted unless AndaimeStrictSafe is set.
@system string viaStdJson(Context ctx) => toStd(viaStd(cast(string) ctx.request.body));

void main(string[] args)
{
    import std.conv : to;

    ServerConfig cfg;
    cfg.port = args.length > 1 ? args[1].to!ushort : 18101;
    cfg.workers = args.length > 2 ? args[2].to!uint : 1;
    serve(() {
        auto app = new App;
        app.post!("/andaime", viaAndaime);
        app.post!("/stdjson", viaStdJson);
        return app;
    }, cfg);
}
