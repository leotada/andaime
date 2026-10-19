/// Event loop contract. The Linux implementation is in `andaime.engine.epoll`;
/// kqueue (M5) and io_uring (M6) implement the same interface.
///
/// Model: one worker per core, each with its own loop, its own BufferPool and its own
/// listening socket (SO_REUSEPORT). No mutable state shared between
/// workers. Each request runs in a fiber of its own worker: waiting for I/O
/// (`andaime.engine.fiberio`) suspends the fiber and the loop serves other connections.
module andaime.engine.loop 2025;

@safe:

import andaime.http.types : Request;
import andaime.http.response : ResponseSink;
import andaime.http.parser : Limits;

/// The engine calls this with a complete request (head + body) and a `ResponseSink` for the response: `sink.start(head)`,
/// any number of `sink.write(...)`, `sink.end()`. A response of known length is buffered and sent in one go; a streamed
/// one (`contentLength < 0`) goes out chunk by chunk, and `write`/`flush` suspend the fiber while the client is slow.
/// Runs inside a fiber, so it may call `sleep`/`awaitFd`.
alias RequestCallback = void delegate(ref Request req, ResponseSink sink) @safe;

/// Called once per fiber (not per request) to create the state the
/// callback reuses (Context, buffers...). May be called from several
/// threads, one per worker, so it must be safe for that.
alias HandlerFactory = RequestCallback delegate();

/// Called once per worker, ON that worker's own thread, before it opens its listener; returns that worker's
/// `HandlerFactory`. Whatever it creates (the App, thread-local state, `pgPool`, `httpClient`) therefore belongs to that
/// worker. Worker 0 runs it first, alone; the others run it concurrently, so it must not touch shared state without a
/// lock. It may throw: the server then reports it and starts nothing (or stops, if a later worker failed).
alias WorkerInit = HandlerFactory delegate() @safe;

/// TLS on the listener. Set `certFile` and `keyFile` and the server speaks HTTPS only on `port`,
/// with ALPN choosing HTTP/2 (`h2`) or HTTP/1.1. Needs OpenSSL 3 at run time (loaded by dlopen).
struct TlsConfig
{
    string certFile;  /// PEM: the certificate followed by its intermediates (Let's Encrypt's fullchain.pem)
    string keyFile;   /// PEM private key
    /// How often each worker checks both files for changes (renewal) and reloads them; 0 = never.
    /// New connections get the new certificate; a file that fails to load is logged and the old one kept.
    uint reloadCheckMs = 10_000;
    /// Also listen in cleartext on this port (usually 80). Requests there never reach the application:
    /// ACME HTTP-01 challenges are answered from `acmeWebroot`, everything else gets a 308 to the same
    /// host and path over HTTPS. 0 = no cleartext listener.
    ushort redirectPort;
    /// The directory given to `certbot certonly --webroot -w <dir>`: files it writes under
    /// `<dir>/.well-known/acme-challenge/` are served on `redirectPort`. Empty = no challenges.
    string acmeWebroot;

    bool enabled() const pure nothrow @nogc @safe => certFile.length != 0;
}

struct ServerConfig
{
    string host = "0.0.0.0";
    ushort port = 8080;
    /// Bind a listening socket and accept connections. False skips the bind and does not load TLS; the loop still
    /// polls, so background fibers can `sleep` and `awaitFd`. The process stays up while those fibers are in flight
    /// and, after stop, leaves once they finish. At `shutdownGraceMs` the ones still sleeping are cancelled.
    bool accept = true;
    uint workers = 0;                /// 0 = number of cores
    uint backlog = 1024;
    uint maxConnections = 10_000;    /// per worker
    uint maxInFlight = 1024;         /// requests in progress per worker; above that, 503
    uint maxIdleWorkers = 64;        /// idle fibers kept in a pool; the rest are torn down
    /// Virtual stack of each fiber; only the pages a handler actually touches become RSS, so a generous default costs
    /// almost nothing. Overflowing it is a SIGSEGV that ends the whole process, so a handler that recurses deeply or
    /// keeps big arrays on the stack should raise it. Each fiber uses 2 memory mappings (stack + guard page), and Linux
    /// allows 65,530 per process by default (`vm.max_map_count`): about 32,000 fibers.
    /// The default is 256 KiB (it was 128 KiB): that measured the same RSS at 1,000 in-flight requests, while 512 KiB
    /// cost ~0.8 MB more (LDC).
    uint fiberStackBytes = 256 << 10;
    uint headerTimeoutMs = 10_000;   /// from the first byte to the end of the head (slowloris)
    uint idleTimeoutMs = 60_000;     /// idle keep-alive
    uint requestTimeoutMs = 30_000;  /// handler went past this: cancelled, 504
    uint writeTimeoutMs = 30_000;    /// client that does not read the response (also each blocked write of a streamed one)
    /// A response that is being written goes out as soon as this many bytes are buffered; past it `write` waits for the
    /// transport (HTTP/1.1: the socket; HTTP/2: the flow-control windows), so a slow reader never makes memory grow.
    uint streamHighWaterBytes = 64 << 10;
    /// Longest a response may take from its first byte to its end; 0 = no limit (Server-Sent Events can live for hours).
    /// `requestTimeoutMs` covers the time until the response head is started.
    uint streamTimeoutMs = 0;
    /// Proxies whose `X-Forwarded-For` is believed, as CIDR strings (`"10.0.0.0/8"`, `"127.0.0.1"`). For a request whose TCP
    /// peer is one of them `ctx.clientIp()` returns the first address in the header that is not a trusted proxy; for any
    /// other peer the header is ignored (anyone can send it). An invalid entry fails startup.
    const(string)[] trustedProxies;
    string forwardedHeader = "X-Forwarded-For"; /// the header `ctx.clientIp()` reads behind a trusted proxy
    uint shutdownGraceMs = 10_000;   /// on stop, wait for in-flight requests and background fibers; then cancel any still sleeping
    uint stallWarnMs = 50;           /// warning when a handler holds the worker longer than this without yielding; 0 turns it off
    bool reusePort = true;           /// SO_REUSEPORT: one listener per worker
    bool trimAfterBurst = true;      /// returns memory to the OS 1 s after a burst (runs the GC)
    /// HTTP/2 over cleartext (h2c): prior knowledge (the `PRI *` preface) and `Upgrade: h2c`.
    /// HTTP/1.1 keeps working on the same port. Each stream runs in its own fiber, like a request.
    bool http2 = true;
    uint http2MaxStreams = 100;      /// SETTINGS_MAX_CONCURRENT_STREAMS per connection (maxInFlight still applies per worker)
    uint http2StreamWindowBytes = 256 << 10;   /// per-stream receive window: request body a client may send per round trip
    uint http2ConnectionWindowBytes = 1 << 20; /// connection receive window: request body in flight across all streams
    /// WebSockets over HTTP/2 (RFC 8441): announces SETTINGS_ENABLE_CONNECT_PROTOCOL, so browsers open a WebSocket as a
    /// stream of the page's HTTP/2 connection. False: they open their own HTTP/1.1 connection for it, as before.
    bool http2WebSockets = true;
    /// HTTPS (see `TlsConfig`). The handshake must finish within `headerTimeoutMs`.
    TlsConfig tls;
    /// Logs failed TLS handshakes and HTTP/2 connection errors to stderr with the client's address,
    /// at most one line per second per worker (the rest are counted in the next line).
    bool logConnectionErrors = true;
    Limits limits;
    /// Bodies for the HTTP/1.1 answers the engine gives on its own, before any handler runs: a malformed request (400),
    /// a head or body too slow (408), a body over the limit (413), a head over the limit (431), an unsupported transfer
    /// coding (501), the in-flight ceiling (503), an unsupported version (505). A status without an entry has no body.
    /// `jsonErrorBodies()` gives `{"detail":"..."}` for each, like the app's own 404 and 405.
    ///
    /// For a status, the entries with an `accept` come first: the first one the request's `Accept` names wins, else the
    /// first it takes through a wildcard (`*/*`, or no `Accept` at all); when none is taken, the first entry for the status
    /// with an empty `accept`. For a head that did not parse, `Accept` is read from its raw bytes. HTTP/2 streams and the
    /// development server answer these with no body.
    const(ErrorBody)[] errorBodies;
}

/// One entry of `ServerConfig.errorBodies`: a fixed body for `status`.
struct ErrorBody
{
    int status;
    string body_;
    string contentType = "application/json";
    /// When not 0, the status actually sent instead of `status`: for an application that must keep an older contract
    /// (413 for a head too large, say). The default keeps the correct status.
    int replyStatus = 0;
    /// A media range (`application/json`, `text/html`, `text/*`, `*/*`): the entry is used only when the request's
    /// `Accept` takes it. Empty: any request. A request without `Accept` takes every entry.
    string accept;
}

/// `{"detail":"<reason>"}` bodies for every status the engine answers by itself (see `ServerConfig.errorBodies`).
immutable(ErrorBody)[] jsonErrorBodies() pure nothrow @safe
{
    static immutable ErrorBody[] all = [
        ErrorBody(400, `{"detail":"bad request"}`),
        ErrorBody(408, `{"detail":"request timeout"}`),
        ErrorBody(413, `{"detail":"request body too large"}`),
        ErrorBody(414, `{"detail":"uri too long"}`),
        ErrorBody(431, `{"detail":"request header fields too large"}`),
        ErrorBody(501, `{"detail":"not implemented"}`),
        ErrorBody(503, `{"detail":"service unavailable"}`),
        ErrorBody(505, `{"detail":"http version not supported"}`),
    ];
    return all;
}

/// Counters of one worker (read without a lock: for metrics and tests only).
struct LoopStats
{
    size_t inFlight;       /// fibers in use now (requests and background fibers: running, suspended or sending)
    size_t peakInFlight;
    size_t workersCreated; /// fibers created since the start
    size_t workersRetired; /// fibers torn down because of too many idle ones
    size_t idleWorkers;
    size_t connections;
    size_t rejected;       /// 503s because of the in-flight ceiling
    size_t cancelled;      /// cancelled requests (client went away)
    size_t timedOut;       /// requests cancelled by deadline (504)
    size_t stalls;         /// handlers that held the worker beyond stallWarnMs
    long maxStallMs;       /// the longest stretch without yielding seen so far
    size_t http2Connections; /// connections that switched to HTTP/2 since the start
    size_t http2Streams;     /// HTTP/2 requests handed to a fiber since the start
    size_t tlsHandshakes;    /// TLS handshakes completed since the start
    size_t tlsFailures;      /// TLS handshakes that failed or timed out
    size_t tlsReloads;       /// certificate reloads of this worker
    size_t redirects;        /// requests answered on `tls.redirectPort` (308 or ACME challenge)
    size_t handlerErrors;    /// throwables that escaped a handler (answered 500)
    size_t fibersPoisoned;   /// fibers thrown away because an `Error` escaped (never reused)
    size_t webSockets;       /// connections taken over after a 101 (WebSockets) open now; each holds a fiber
    size_t webSocketsTotal;  /// WebSocket connections accepted since the start
}

/// I/O backend. Planned implementations:
/// - EpollLoop  (Linux, M2)    edge-triggered, accept4, fiber per request
/// - KqueueLoop (macOS/BSD, M5)
/// - UringLoop  (Linux 6.0+, M6)  multishot accept/recv, buffer rings
interface EventLoop
{
    /// Blocks the current thread serving connections until `stop`.
    /// `@system`: loops are raw-syscall code (epoll_wait, fibers, sockets). The handlers
    /// they call are `@safe` delegates; `andaime.server.serve` is the `@trusted` entry point.
    void run(ref const ServerConfig cfg, HandlerFactory factory) @system;

    /// Requests a graceful stop: stops accepting, drains in-flight requests.
    /// May be called from another thread or from a signal handler.
    void stop() nothrow @nogc;
}

/// States of a connection in the loop.
enum ConnState : ubyte
{
    idle,        /// no borrowed buffer; waiting for bytes
    readingHead, /// buffer lent out; head incomplete
    readingBody, /// head ok; body bytes missing
    running,     /// handler in the fiber (running or suspended waiting for I/O)
    writing,     /// response ready; sending
    closing,
    http2,       /// multiplexed: reading frames and running streams at the same time
    handshake,   /// TLS handshake in progress
}
