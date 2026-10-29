/// A scripted stand-in for the network, for testing code that calls `httpClient()`: each expected request gets its
/// reply, every request is recorded, and a request nobody expected fails loudly.
///
/// ```d
/// auto fake = new FakeHttpClient;
/// fake.expect("PUT", "https://bucket.s3.example.com/avatars/1.png").respond(200, "", [HeaderPair("ETag", `"abc"`)]);
/// fake.expect("POST", "https://api.mail.example/send").timeout();
/// fake.install();                    // every HttpClient of this thread now talks to `fake`
/// scope (exit) fake.uninstall();
///
/// uploadAvatar(1, pngBytes);         // the code under test, unchanged
/// assert(fake.requests[0].body_ == pngBytes);
/// fake.verify();                     // throws if an expected request was not made
/// ```
///
/// A URL ending in `*` matches by prefix. Expectations are tried in the order they were added; each one answers as many
/// requests as it has replies (one, `200` with no body, when it has none), unless `always()` makes its last reply repeat.
/// The real client pays one thread-local null check per request for this.
module andaime.engine.httpfake 2025;

@safe:

import core.time : Duration;

import andaime.engine.httpclient : ClientResponse, HeaderPair, HttpClientError, HttpClientTimeout, HttpTransport,
    setHttpTransport;

/// A request the code under test made.
struct RecordedRequest
{
    string method;
    string url;
    HeaderPair[] headers;
    immutable(ubyte)[] body_;
    Duration timeout; /// the per-call timeout (zero: the configured one)

    /// The body as text.
    string text() const pure nothrow @trusted => cast(string) body_; // sound: immutable bytes viewed as immutable chars

    /// Value of the first header `name` (case-insensitive), or null.
    string header(scope const(char)[] name) const pure nothrow
    {
        foreach (h; headers)
            if (sameFold(h.name, name))
                return h.value;
        return null;
    }
}

/// One expected request and its replies (see `FakeHttpClient.expect`).
final class Expectation
{
    private string method, url;
    private bool prefix, repeat;
    private Reply[] replies;
    private size_t used;

    private this(string method, string url)
    {
        this.method = method;
        if (url.length && url[$ - 1] == '*')
        {
            prefix = true;
            url = url[0 .. $ - 1];
        }
        this.url = url;
    }

    /// Answers with `status`, `body_` and `headers`.
    Expectation respond(int status, string body_ = null, HeaderPair[] headers = null)
    {
        replies ~= Reply(Reply.Kind.response, ClientResponse(status, headers, body_), null);
        return this;
    }

    /// The request ends with `HttpClientTimeout`, as when the deadline passes.
    Expectation timeout()
    {
        replies ~= Reply(Reply.Kind.timeout, ClientResponse.init, null);
        return this;
    }

    /// The request fails with `HttpClientError("andaime.http: " ~ msg)`, as a network error does.
    Expectation fail(string msg = "connection refused")
    {
        replies ~= Reply(Reply.Kind.error, ClientResponse.init, msg);
        return this;
    }

    /// The last reply answers every further matching request (and `verify` accepts any count).
    Expectation always()
    {
        repeat = true;
        return this;
    }

    private size_t expected() const pure nothrow => replies.length ? replies.length : 1;

    private bool matches(scope const(char)[] m, scope const(char)[] u) const pure nothrow
    {
        if (m != method)
            return false;
        return prefix ? u.length >= url.length && u[0 .. url.length] == url : u == url;
    }

    private bool exhausted() const pure nothrow => !repeat && used >= expected;

    private string describe() const pure => method ~ " " ~ url ~ (prefix ? "*" : "");
}

private struct Reply
{
    enum Kind : ubyte { response, timeout, error }

    Kind kind;
    ClientResponse response;
    string message;
}

/// See the module documentation.
final class FakeHttpClient : HttpTransport
{
    /// Every request, in order, expected or not.
    RecordedRequest[] requests;

    private Expectation[] expectations;
    private HttpTransport previous;
    private bool installed;

    /// Expects `method url` (a trailing `*` in `url` matches by prefix). Add replies to the result.
    Expectation expect(string method, string url)
    {
        auto e = new Expectation(method, url);
        expectations ~= e;
        return e;
    }

    /// Routes every `HttpClient` of this thread to this fake (until `uninstall`).
    void install() nothrow @nogc
    {
        if (installed)
            return;
        previous = setHttpTransport(this);
        installed = true;
    }

    /// Restores what was installed before.
    void uninstall() nothrow @nogc
    {
        if (!installed)
            return;
        setHttpTransport(previous);
        previous = null;
        installed = false;
    }

    /// Throws `HttpClientError` naming every expected request that was not made (or made fewer times than it has
    /// replies).
    void verify() const
    {
        string missing;
        foreach (e; expectations)
            if (!e.repeat && e.used < e.expected)
                missing ~= (missing.length ? ", " : "") ~ e.describe;
        if (missing.length)
            throw new HttpClientError("andaime.http: FakeHttpClient: expected requests not made: " ~ missing);
    }

    /// Forgets the requests and the expectations.
    void reset()
    {
        requests = null;
        expectations = null;
    }

    ClientResponse send(string method, string url, const(HeaderPair)[] headers, const(ubyte)[] body_,
        Duration timeout)
    {
        requests ~= RecordedRequest(method, url, headers.dup, body_.idup, timeout);
        foreach (e; expectations)
        {
            if (e.exhausted || !e.matches(method, url))
                continue;
            immutable i = e.used++;
            if (e.replies.length == 0)
                return ClientResponse(200);
            auto r = e.replies[i < e.replies.length ? i : $ - 1];
            final switch (r.kind)
            {
            case Reply.Kind.response:
                return r.response;
            case Reply.Kind.timeout:
                throw new HttpClientTimeout;
            case Reply.Kind.error:
                throw new HttpClientError("andaime.http: " ~ r.message);
            }
        }
        throw new HttpClientError("andaime.http: FakeHttpClient: unexpected request " ~ method ~ " " ~ url);
    }
}

private bool sameFold(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
    {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z')
            x += 32;
        if (y >= 'A' && y <= 'Z')
            y += 32;
        if (x != y)
            return false;
    }
    return true;
}

unittest
{
    import andaime.engine.httpclient : HttpClient, httpClient;

    auto fake = new FakeHttpClient;
    fake.expect("PUT", "https://bucket.example.com/a.png").respond(200, "", [HeaderPair("ETag", `"x"`)]);
    fake.expect("POST", "https://api.example.com/send").fail("connection reset").respond(202, `{"id":1}`);
    fake.expect("GET", "https://api.example.com/v1/*").respond(200, "a").respond(500, "b").always();
    fake.expect("POST", "https://slow.example.com/").timeout();
    fake.install();
    scope (exit) fake.uninstall();

    // through the worker's client and through one the code made itself
    immutable ubyte[] png = [0x89, 'P', 'N', 'G', 0, 0xff];
    auto r = httpClient().put("https://bucket.example.com/a.png", png, [HeaderPair("Content-Type", "image/png")]);
    assert(r.status == 200 && r.header("etag") == `"x"`);
    assert(fake.requests[0].method == "PUT" && fake.requests[0].body_ == png);
    assert(fake.requests[0].header("content-type") == "image/png");

    // replies in order: a failure, then the answer
    bool threw;
    try
        httpClient().post("https://api.example.com/send", `{"to":"a"}`);
    catch (HttpClientError e)
        threw = e.msg == "andaime.http: connection reset";
    assert(threw);
    r = new HttpClient().postJson("https://api.example.com/send", `{"to":"a"}`);
    assert(r.status == 202 && r.body == `{"id":1}`);
    assert(fake.requests[2].text == `{"to":"a"}` && fake.requests[2].header("Content-Type") == "application/json");

    // a prefix, and always(): the last reply repeats
    assert(httpClient().get("https://api.example.com/v1/users").body == "a");
    assert(httpClient().get("https://api.example.com/v1/users?page=2").status == 500);
    assert(httpClient().get("https://api.example.com/v1/x").status == 500);

    // a timeout
    threw = false;
    try
        httpClient().post("https://slow.example.com/", null);
    catch (HttpClientTimeout)
        threw = true;
    assert(threw);

    // an unexpected request, and an expectation already used up
    threw = false;
    try
        httpClient().del("https://bucket.example.com/a.png");
    catch (HttpClientError e)
        threw = e.msg == "andaime.http: FakeHttpClient: unexpected request DELETE https://bucket.example.com/a.png";
    assert(threw);
    threw = false;
    try
        httpClient().put("https://bucket.example.com/a.png", "again");
    catch (HttpClientError e)
        threw = true;
    assert(threw);
    assert(fake.requests.length == 9, "unexpected requests are recorded too");
    fake.verify();

    // verify names what was not called
    fake.reset();
    fake.expect("GET", "https://a.example.com/").respond(200);
    fake.expect("DELETE", "https://b.example.com/*");
    threw = false;
    try
        fake.verify();
    catch (HttpClientError e)
        threw = e.msg == "andaime.http: FakeHttpClient: expected requests not made: GET https://a.example.com/, "
            ~ "DELETE https://b.example.com/*";
    assert(threw);

    // a malformed URL fails the same way as with the network
    threw = false;
    try
        httpClient().get("ftp://x");
    catch (HttpClientError e)
        threw = true;
    assert(threw && fake.requests.length == 0);

    // uninstall restores the network
    fake.uninstall();
    assert(setHttpTransport(null) is null);
}

// streamed bodies: a BodySource is recorded whole, and `open` reads the reply in pieces
unittest
{
    import andaime.engine.httpclient : BodySource, httpClient;

    auto fake = new FakeHttpClient;
    fake.expect("PUT", "https://bucket.example.com/big").respond(200);
    fake.expect("GET", "https://bucket.example.com/big").respond(200, "0123456789", [HeaderPair("ETag", `"e"`)]);
    fake.expect("GET", "https://bucket.example.com/none").respond(404);
    fake.install();
    scope (exit) fake.uninstall();

    auto source = BodySource(6, (scope sink) {
        immutable(ubyte)[3] a = ['a', 'b', 'c'], b = ['d', 'e', 'f'];
        sink(a[]);
        sink(b[]);
    });
    assert(httpClient().put("https://bucket.example.com/big", source).status == 200);
    assert(fake.requests[0].text == "abcdef");

    auto s = httpClient().open("GET", "https://bucket.example.com/big");
    scope (exit) s.close();
    assert(s.ok && s.header("etag") == `"e"` && s.contentLength == 10);
    ubyte[4] buf;
    string got;
    size_t n;
    while ((n = s.read(buf[])) > 0)
        got ~= cast(const(char)[]) buf[0 .. n];
    assert(got == "0123456789");

    auto missing = httpClient().open("GET", "https://bucket.example.com/none");
    assert(missing.status == 404 && missing.read(buf[]) == 0);
    missing.close();
    fake.verify();
}
