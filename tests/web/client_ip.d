/// The client's address: the TCP peer, and the real client behind trusted proxies.
module client_ip 2025;

@safe:

import andaime;
import andaime.web.testing;

string who(ClientIp ip) => ip.toString;
string whoCtx(Context ctx) => ctx.clientIp().toString;

App build(const(string)[] trusted)
{
    auto app = new App;
    app.get!("/who", who);
    app.get!("/who2", whoCtx);
    if (trusted.length)
        app.trustProxies(trusted);
    return app;
}

unittest
{
    // no trusted proxies: the header is ignored, whoever sends it
    auto c = TestClient(build(null));
    assert(c.get("/who").body == "127.0.0.1");
    assert(c.from("203.0.113.9").get("/who", hdr("X-Forwarded-For", "6.6.6.6")).body == "203.0.113.9");

    // a trusted proxy: the header counts
    c = TestClient(build(["10.0.0.0/8", "127.0.0.1"]));
    assert(c.from("10.0.0.2").get("/who", hdr("X-Forwarded-For", "198.51.100.7")).body == "198.51.100.7");
    assert(c.from("10.0.0.2").get("/who2", hdr("X-Forwarded-For", "198.51.100.7")).body == "198.51.100.7");

    // a chain: client, then two proxies; walking from the right skips the trusted hops
    assert(c.from("10.0.0.2").get("/who", hdr("X-Forwarded-For", "198.51.100.7, 10.1.1.1, 10.2.2.2")).body == "198.51.100.7");
    // a client-supplied fake in front of the real one is not believed: the first untrusted from the right wins
    assert(c.from("10.0.0.2").get("/who", hdr("X-Forwarded-For", "6.6.6.6, 198.51.100.7, 10.1.1.1")).body == "198.51.100.7");

    // the header from an untrusted peer is ignored even though proxies are configured
    assert(c.from("203.0.113.9").get("/who", hdr("X-Forwarded-For", "6.6.6.6")).body == "203.0.113.9");

    // several header lines are one list; no header at all gives the peer; IPv6 and ports in the header are understood
    assert(c.from("10.0.0.2").get("/who", hdr("X-Forwarded-For", "198.51.100.7"), hdr("X-Forwarded-For", "10.9.9.9")).body == "198.51.100.7");
    assert(c.from("10.0.0.2").get("/who").body == "10.0.0.2");
    assert(c.from("10.0.0.2").get("/who", hdr("X-Forwarded-For", "[2001:db8::7]:443")).body == "2001:db8::7");

    // an invalid entry stops the walk: the peer is returned, never a guess
    assert(c.from("10.0.0.2").get("/who", hdr("X-Forwarded-For", "garbage, 10.1.1.1")).body == "10.0.0.2");
    assert(c.from("10.0.0.2").get("/who", hdr("X-Forwarded-For", "198.51.100.7, , 10.1.1.1")).body == "10.0.0.2");

    // every hop trusted: the leftmost
    assert(c.from("10.0.0.2").get("/who", hdr("X-Forwarded-For", "10.5.5.5, 10.1.1.1")).body == "10.5.5.5");
}

unittest
{
    // a bad entry fails when configuring, with the offending text
    auto app = new App;
    try
        app.trustProxies(["10.0.0.0/8", "not-an-ip"]);
    catch (RouteError e)
    {
        import std.algorithm : canFind;
        assert(e.msg.canFind("not-an-ip"), e.msg);
        return;
    }
    assert(0, "expected a RouteError");
}
