/// Event loop contract. The Linux implementation is in `vela.engine.epoll`;
/// kqueue (M5) and io_uring (M6) implement the same interface.
///
/// Model: one worker per core, each with its own loop, its own BufferPool and its own
/// listening socket (SO_REUSEPORT). No mutable state shared between
/// workers. Each request runs in a fiber of its own worker: waiting for I/O
/// (`vela.engine.fiberio`) suspends the fiber and the loop serves other connections.
module vela.engine.loop;

import vela.http.types : Request;
import vela.http.buffer : ByteBuffer;
import vela.http.parser : Limits;

/// The engine calls this with a complete request (head + body) and
/// expects the whole response (head + body) serialized into `output`.
/// Runs inside a fiber, so it may call `sleep`/`awaitFd`.
alias RequestCallback = void delegate(ref Request req, ref ByteBuffer output);

/// Called once per fiber (not per request) to create the state the
/// callback reuses (Context, buffers...). May be called from several
/// threads, one per worker, so it must be safe for that.
alias HandlerFactory = RequestCallback delegate();

struct ServerConfig
{
    string host = "0.0.0.0";
    ushort port = 8080;
    uint workers = 0;                /// 0 = number of cores
    uint backlog = 1024;
    uint maxConnections = 10_000;    /// per worker
    uint maxInFlight = 1024;         /// requests in progress per worker; above that, 503
    uint maxIdleWorkers = 64;        /// idle fibers kept in a pool; the rest are torn down
    uint fiberStackBytes = 128 << 10; /// virtual stack of each fiber (only what is used becomes RSS)
    uint headerTimeoutMs = 10_000;   /// from the first byte to the end of the head (slowloris)
    uint idleTimeoutMs = 60_000;     /// idle keep-alive
    uint requestTimeoutMs = 30_000;  /// handler went past this: cancelled, 504
    uint writeTimeoutMs = 30_000;    /// client that does not read the response
    uint shutdownGraceMs = 10_000;   /// wait for in-flight requests on stop
    uint stallWarnMs = 50;           /// warning when a handler holds the worker longer than this without yielding; 0 turns it off
    bool reusePort = true;           /// SO_REUSEPORT: one listener per worker
    bool trimAfterBurst = true;      /// returns memory to the OS 1 s after a burst (runs the GC)
    Limits limits;
}

/// Counters of one worker (read without a lock: for metrics and tests only).
struct LoopStats
{
    size_t inFlight;       /// fibers in use now (running, suspended or sending)
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
}

/// I/O backend. Planned implementations:
/// - EpollLoop  (Linux, M2)    edge-triggered, accept4, fiber per request
/// - KqueueLoop (macOS/BSD, M5)
/// - UringLoop  (Linux 6.0+, M6)  multishot accept/recv, buffer rings
interface EventLoop
{
    /// Blocks the current thread serving connections until `stop`.
    void run(ref const ServerConfig cfg, HandlerFactory factory);

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
}
