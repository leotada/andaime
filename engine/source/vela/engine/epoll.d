/// Loop de eventos do Linux: epoll edge-triggered, um fiber por requisição.
///
/// Fluxo de uma conexão (`Conn.phase`):
///   reading -> (head+corpo completos) -> running -> writing -> reading ...
/// `running` é o handler dentro de um fiber; se ele chama `sleep`/`awaitFd`,
/// o fiber é suspenso e o loop segue com as outras conexões. Quando o fiber
/// volta (timer ou fd pronto), o loop retoma de onde parou.
///
/// Cancelamento: se o cliente fecha enquanto o fiber está suspenso (EPOLLRDHUP)
/// ou o prazo da requisição estoura, a próxima espera do handler lança
/// `RequestCancelled`; a pilha desce rodando `scope(exit)` e destrutores.
///
/// Pools: fibers ociosos acima de `maxIdleWorkers` são desfeitos (a stack volta
/// ao SO); buffers de rede vão ao `BufferPool`, que tem teto próprio.
module vela.engine.epoll;

version (linux):

import core.thread : Fiber, Thread;
import core.time : MonoTime;
import core.atomic : atomicLoad, atomicStore;
import core.stdc.errno;
import core.stdc.stdio : printf, fprintf, stderr, perror;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.netinet.tcp : TCP_NODELAY;
import core.sys.posix.arpa.inet : inet_pton;
import core.sys.posix.unistd : close, read, write, sysconf, _SC_NPROCESSORS_ONLN;
import core.sys.posix.signal;
import core.sys.linux.epoll;
import core.sys.linux.sys.eventfd : eventfd;

import vela.http;
import vela.engine.bufferpool;
import vela.engine.loop;
import vela.engine.fiberio;

private extern (C) int accept4(int, sockaddr*, socklen_t*, int) nothrow @nogc;
version (CRuntime_Glibc)
    private extern (C) int malloc_trim(size_t) nothrow @nogc;
private void mallocTrim(size_t pad) nothrow @nogc
{
    version (CRuntime_Glibc)
        malloc_trim(pad);
}
private enum SOCK_NONBLOCK = 0x800, SOCK_CLOEXEC = 0x80000;

// ======================================================================= estruturas

/// Headers por requisição. Cada fiber carrega a sua tabela (32 B por entrada), então
/// o valor pesa em toda requisição em voo; acima disso o parser responde 431.
private enum maxHeaders = 32;

private enum Kind : ubyte { listener, wake, conn, waiter }

private class Item
{
    immutable Kind kind;
    this(Kind k) nothrow @nogc @safe { kind = k; }
}

private enum Phase : ubyte { reading, running, writing, closed }

private struct Stack(T)
{
    T[] a;
    size_t n;

    bool empty() const pure nothrow @nogc @safe => n == 0;
    void push(T v) nothrow
    {
        if (n == a.length)
            a.length = a.length ? a.length * 2 : 16;
        a[n++] = v;
    }
    T pop() nothrow
    {
        auto v = a[--n];
        a[n] = T.init;
        return v;
    }
}

private final class Conn : Item
{
    int fd = -1;
    Phase phase;
    Buffer buf;
    bool haveHead;
    bool sent100;          /// já respondeu 100 Continue a esta requisição
    size_t headLen, total; /// geometria da requisição atual (válida com haveHead)
    Worker worker;         /// enquanto running/writing
    size_t sent;           /// bytes de worker.output já enviados
    long deadlineMs;       /// relógio monotônico do loop; 0 = sem prazo

    this() nothrow @safe { super(Kind.conn); }
}

private final class WaitItem : Item
{
    Worker w;
    this() nothrow @safe { super(Kind.waiter); }
}

private struct Timer
{
    long dl;
    Worker w;
    uint gen;
}

private final class Worker : Fiber
{
    EpollLoop loop;
    RequestCallback cb;
    Conn conn;
    Request req;
    HeaderField[maxHeaders] store;
    ByteBuffer output;
    WaitItem item;

    bool done, cancelled, timedOut, failed, closeAfter, retiring;
    bool waiting, timerPending;
    uint waitGen;
    int waitFd = -1;
    uint wakeEvents;

    this(EpollLoop l, size_t stackBytes)
    {
        super(&run, stackBytes);
        loop = l;
        cb = l.factory();
        item = new WaitItem;
        item.w = this;
    }

    private void run()
    {
        for (;;)
        {
            if (retiring)
                return;
            done = false;
            try
                cb(req, output);
            catch (RequestCancelled)
                cancelled = true;
            catch (Throwable t)
            {
                failed = true;
                fprintf(stderr, "vela: erro não tratado no handler: %.*s\n",
                    cast(int) t.msg.length, t.msg.ptr);
            }
            done = true;
            Fiber.yield();
        }
    }
}

// ======================================================================= o loop

final class EpollLoop : EventLoop, Scheduler
{
    private ServerConfig cfg;
    private HandlerFactory factory;

    private int ep = -1, listenFd = -1, wakeFd = -1;
    private Item listenItem, wakeItem;
    private BufferPool pool;
    private HeaderField[maxHeaders] scratch;
    private ByteBuffer errOut;

    private Conn[] conns; /// por fd
    private Stack!Conn spare, dead;
    private Stack!Worker idle;
    private Timer[] heap;
    private size_t heapN, staleTimers;

    private MonoTime t0;
    private long nowMs;
    private long nextSweepMs;
    private long stopDeadlineMs;
    private size_t connCount, inFlight, peakInFlight, workersCreated, workersRetired;
    private size_t rejected, cancelledN, timedOutN, stalls;
    private long quietSinceMs;      /// desde quando inFlight == 0 (0 = ocupado)
    private size_t createdAtTrim;  /// workersCreated na última limpeza
    private size_t trims;
    private long maxStallMs, lastStallLogMs = -1_000_000;
    private bool stopping;
    private shared bool stopReq;
    private RequestCancelled cancelledEx;

    /// Porta em que este loop escuta (útil com `port = 0`); válida quando `ready`.
    ushort boundPort;
    shared bool ready;

    this()
    {
        ep = epoll_create1(0);
        wakeFd = eventfd(0, 0x800 /*EFD_NONBLOCK*/ | 0x80000 /*EFD_CLOEXEC*/);
        wakeItem = new Item(Kind.wake);
        epoll_event ev;
        ev.events = EPOLLIN;
        ev.data.ptr = cast(void*) wakeItem;
        epoll_ctl(ep, EPOLL_CTL_ADD, wakeFd, &ev);
        cancelledEx = new RequestCancelled;
    }

    ~this()
    {
        if (ep >= 0) close(ep);
        if (wakeFd >= 0) close(wakeFd);
    }

    LoopStats stats() const nothrow @nogc
    {
        return LoopStats(inFlight, peakInFlight, workersCreated, workersRetired, idle.n,
            connCount, rejected, cancelledN, timedOutN, stalls, maxStallMs);
    }

    /// Quantas vezes o loop devolveu memória ao SO depois de uma rajada.
    size_t trimCount() const nothrow @nogc => trims;

    override void stop() nothrow @nogc
    {
        atomicStore(stopReq, true);
        ulong one = 1;
        write(wakeFd, &one, one.sizeof);
    }

    // ------------------------------------------------------------------ run

    override void run(ref const ServerConfig c, HandlerFactory f)
    {
        cfg = c;
        factory = f;
        t0 = MonoTime.currTime;
        currentScheduler = this;
        scope (exit)
        {
            currentScheduler = null;
            teardown();
        }
        if (!openListener())
            return;
        nowMs = elapsedMs();
        nextSweepMs = nowMs + sweepEveryMs;
        atomicStore(ready, true);

        epoll_event[256] evs;
        for (;;)
        {
            long timeout = nextSweepMs - nowMs;
            if (heapN)
            {
                immutable w = heap[0].dl - nowMs;
                if (w < timeout)
                    timeout = w;
            }
            if (stopping && timeout > 50)
                timeout = 50;
            if (timeout < 0)
                timeout = 0;

            immutable n = epoll_wait(ep, evs.ptr, cast(int) evs.length, cast(int) timeout);
            if (n < 0 && errno != EINTR)
                break;
            nowMs = elapsedMs();

            foreach (i; 0 .. (n < 0 ? 0 : n))
                onEvent(cast(Item) evs[i].data.ptr, evs[i].events);
            flushDead();

            fireTimers();
            flushDead();

            if (nowMs >= nextSweepMs)
            {
                sweep();
                flushDead();
                trimIfQuiet();
                nextSweepMs = nowMs + sweepEveryMs;
            }

            if (atomicLoad(stopReq) && !stopping)
                beginStop();
            if (stopping)
            {
                closeIdleConns();
                flushDead();
                if (inFlight == 0 && connCount == 0)
                    break;
                if (nowMs >= stopDeadlineMs)
                    break;
            }
        }
    }

    private enum sweepEveryMs = 250;

    private long elapsedMs() const nothrow @nogc
    {
        return (MonoTime.currTime - t0).total!"msecs";
    }

    // ------------------------------------------------------------------ listener

    private bool openListener()
    {
        listenFd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        if (listenFd < 0)
        {
            perror("vela: socket");
            return false;
        }
        int one = 1;
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &one, one.sizeof);
        if (cfg.reusePort)
            setsockopt(listenFd, SOL_SOCKET, SO_REUSEPORT, &one, one.sizeof);

        sockaddr_in addr;
        addr.sin_family = AF_INET;
        addr.sin_port = htons(cfg.port);
        char[64] host = 0;
        if (cfg.host.length == 0 || cfg.host.length >= host.length)
            addr.sin_addr.s_addr = htonl(INADDR_ANY);
        else
        {
            host[0 .. cfg.host.length] = cfg.host[];
            if (inet_pton(AF_INET, host.ptr, &addr.sin_addr) != 1)
            {
                fprintf(stderr, "vela: host inválido: %s\n", host.ptr);
                return false;
            }
        }
        if (bind(listenFd, cast(sockaddr*)&addr, addr.sizeof) < 0)
        {
            perror("vela: bind");
            return false;
        }
        if (listen(listenFd, cast(int) cfg.backlog) < 0)
        {
            perror("vela: listen");
            return false;
        }
        sockaddr_in got;
        socklen_t gl = got.sizeof;
        getsockname(listenFd, cast(sockaddr*)&got, &gl);
        boundPort = ntohs(got.sin_port);

        listenItem = new Item(Kind.listener);
        epoll_event ev;
        ev.events = EPOLLIN; // nível: se sobrar conexão após o lote, o próximo wait avisa
        ev.data.ptr = cast(void*) listenItem;
        epoll_ctl(ep, EPOLL_CTL_ADD, listenFd, &ev);
        return true;
    }

    private void acceptSome()
    {
        foreach (_; 0 .. 64)
        {
            immutable fd = accept4(listenFd, null, null, SOCK_NONBLOCK | SOCK_CLOEXEC);
            if (fd < 0)
                return; // EAGAIN, EMFILE...: o próximo wait tenta de novo
            if (connCount >= cfg.maxConnections || stopping)
            {
                close(fd);
                continue;
            }
            int one = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, one.sizeof);

            Conn c = spare.empty ? new Conn : spare.pop();
            c.fd = fd;
            c.phase = Phase.reading;
            c.buf = Buffer.init;
            c.haveHead = false;
            c.sent100 = false;
            c.headLen = c.total = c.sent = 0;
            c.worker = null;
            c.deadlineMs = nowMs + cfg.idleTimeoutMs;
            if (fd >= conns.length)
                conns.length = fd + 1024;
            conns[fd] = c;
            connCount++;

            epoll_event ev;
            ev.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET;
            ev.data.ptr = cast(void*) c;
            epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
        }
    }

    // ------------------------------------------------------------------ eventos

    private void onEvent(Item it, uint events)
    {
        final switch (it.kind)
        {
            case Kind.listener:
                if (!stopping)
                    acceptSome();
                break;
            case Kind.wake:
                ulong v;
                read(wakeFd, &v, v.sizeof);
                break;
            case Kind.conn:
                onConnEvent(cast(Conn) cast(void*) it, events);
                break;
            case Kind.waiter:
                onWaiter((cast(WaitItem) cast(void*) it).w, events);
                break;
        }
    }

    private void onConnEvent(Conn c, uint events)
    {
        if (c.fd < 0)
            return; // fechada neste mesmo lote
        if (events & EPOLLERR)
        {
            if (c.phase == Phase.running)
                cancelRequest(c, false);
            else
                closeConn(c);
            return;
        }
        if (events & (EPOLLHUP | EPOLLRDHUP))
        {
            final switch (c.phase)
            {
                case Phase.running:
                    cancelRequest(c, false);
                    break;
                case Phase.writing:
                    closeConn(c);
                    break;
                case Phase.reading:
                    drive(c); // pode haver uma requisição completa antes do FIN
                    if (c.fd >= 0 && c.phase == Phase.reading)
                        closeConn(c);
                    break;
                case Phase.closed:
                    break;
            }
            return;
        }
        if ((events & EPOLLOUT) && c.phase == Phase.writing)
        {
            trySend(c);
            if (c.fd >= 0 && c.phase == Phase.reading)
                drive(c);
        }
        if ((events & EPOLLIN) && c.fd >= 0 && c.phase == Phase.reading)
            drive(c);
    }

    private void onWaiter(Worker w, uint events)
    {
        if (!w.waiting)
            return; // evento atrasado de uma espera que já acabou
        w.wakeEvents = events;
        wake(w);
        Conn c = w.conn;
        resume(w);
        if (c.fd >= 0 && c.phase == Phase.reading)
            drive(c);
    }

    // ------------------------------------------------------------------ leitura e parse

    private enum Step : ubyte { needMore, ready, failed }

    /// Lê e processa o que houver na conexão, até esperar por mais bytes,
    /// suspender num handler ou fechar. Nunca recursivo.
    private void drive(Conn c)
    {
        for (;;)
        {
            if (c.fd < 0 || c.phase != Phase.reading)
                return;
            final switch (tryParse(c))
            {
                case Step.ready:
                    startRequest(c);
                    break; // volta ao topo: pode haver outra requisição em pipelining
                case Step.needMore:
                    if (!fill(c))
                        return;
                    break;
                case Step.failed:
                    return;
            }
        }
    }

    /// Lê até EAGAIN. Devolve false se não há mais o que ler agora (ou fechou).
    private bool fill(Conn c)
    {
        if (c.buf.isNull)
            c.buf = pool.acquire(4096); // empresta só quando chega o primeiro byte
        bool any = false;
        for (;;)
        {
            if (c.buf.free_.length == 0)
            {
                if (!pool.grow(c.buf, c.buf.mem.length + 1))
                {
                    sendErrorAndClose(c, 431);
                    return false;
                }
            }
            immutable wasEmpty = c.buf.len == 0;
            immutable r = read(c.fd, c.buf.free_.ptr, c.buf.free_.length);
            if (r > 0)
            {
                if (wasEmpty)
                    c.deadlineMs = nowMs + cfg.headerTimeoutMs; // não estende a cada byte
                c.buf.len += r;
                any = true;
                if (c.buf.free_.length != 0)
                    return true; // leitura curta: o kernel esvaziou
                continue;
            }
            if (r == 0)
            {
                closeConn(c);
                return false;
            }
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN)
            {
                if (c.buf.len == 0)
                    pool.release(c.buf); // nada chegou: não segura o buffer
                return any;
            }
            closeConn(c);
            return false;
        }
    }

    private Step tryParse(Conn c)
    {
        if (c.buf.isNull || c.buf.len == 0)
            return Step.needMore;
        if (!c.haveHead)
        {
            Request tmp;
            auto h = parseRequestHead(cast(const(char)[]) c.buf.data, tmp, scratch[], cfg.limits);
            if (h.status == ParseStatus.incomplete)
                return Step.needMore;
            if (h.status == ParseStatus.error)
            {
                sendErrorAndClose(c, h.errorStatus);
                return Step.failed;
            }
            c.haveHead = true;
            c.headLen = h.headLength;
            c.total = h.headLength + h.contentLength;
            if (c.total > c.buf.mem.length && !pool.grow(c.buf, c.total))
            {
                sendErrorAndClose(c, 413);
                return Step.failed;
            }
        }
        // Expect: 100-continue: o cliente espera o aval antes de mandar o corpo.
        // O parser já recusou (413/417) o que não vale a pena receber.
        if (!c.sent100 && c.buf.len < c.total)
        {
            Request tmp;
            parseRequestHead(cast(const(char)[]) c.buf.data, tmp, scratch[], cfg.limits);
            if (equalsIgnoreCase(tmp.header("expect"), "100-continue"))
            {
                c.sent100 = true;
                sendRaw(c, "HTTP/1.1 100 Continue\r\n\r\n");
            }
        }
        return c.buf.len >= c.total ? Step.ready : Step.needMore;
    }

    // ------------------------------------------------------------------ requisição

    private void startRequest(Conn c)
    {
        if (inFlight >= cfg.maxInFlight)
        {
            rejected++;
            static immutable HeaderField[1] retry = [HeaderField("Retry-After", "1")];
            errOut.clear();
            writeResponseHead(errOut, 503, null, 0, retry[], false);
            sendRaw(c, errOut.data);
            closeConn(c);
            return;
        }
        Worker w = acquireWorker();
        // segundo parse, agora nas estruturas do próprio fiber (o parse é barato;
        // o head fica vivo enquanto o fiber estiver suspenso)
        parseRequestHead(cast(const(char)[]) c.buf.data, w.req, w.store[], cfg.limits);
        w.req.body = c.buf.mem[c.headLen .. c.total];
        if (stopping)
            w.req.keepAlive = false; // drenando: a resposta anuncia Connection: close
        w.conn = c;
        w.output.clear();
        w.cancelled = w.timedOut = w.failed = w.closeAfter = false;
        c.worker = w;
        c.phase = Phase.running;
        c.deadlineMs = nowMs + cfg.requestTimeoutMs;
        resume(w);
    }

    private Worker acquireWorker()
    {
        Worker w;
        if (!idle.empty)
            w = idle.pop();
        else
        {
            w = new Worker(this, cfg.fiberStackBytes);
            workersCreated++;
        }
        inFlight++;
        if (inFlight > peakInFlight)
            peakInFlight = inFlight;
        return w;
    }

    private void releaseWorker(Worker w)
    {
        w.conn = null;
        inFlight--;
        w.output.shrinkTo(64 << 10); // um pico de resposta não fica preso ao fiber
        if (idle.n < cfg.maxIdleWorkers)
            idle.push(w);
        else
        {
            // termina o fiber de verdade (a stack volta ao SO) e solta o objeto
            w.retiring = true;
            w.call();
            destroy(w);
            workersRetired++;
        }
    }

    private void resume(Worker w)
    {
        immutable t = MonoTime.currTime;
        w.call();
        if (cfg.stallWarnMs)
        {
            immutable ms = (MonoTime.currTime - t).total!"msecs";
            if (ms >= cfg.stallWarnMs)
                noteStall(w, ms);
        }
        if (w.done)
            finish(w);
    }

    /// Um handler ficou `ms` sem devolver o worker ao loop: nesse tempo nenhuma
    /// outra conexão deste worker andou. Conta sempre; avisa no máximo 1x por segundo.
    private void noteStall(Worker w, long ms)
    {
        stalls++;
        if (ms > maxStallMs)
            maxStallMs = ms;
        immutable now = elapsedMs();
        if (now - lastStallLogMs < 1000)
            return;
        lastStallLogMs = now;
        auto m = methodName(w.req.method);
        fprintf(stderr, "vela: aviso: um handler segurou o worker por %ld ms sem ceder (%.*s %.*s); "
            ~ "espere com sleep/awaitFd ou tire o trabalho pesado do loop\n", ms,
            cast(int) m.length, m.ptr, cast(int) w.req.path.length, w.req.path.ptr);
    }

    /// O handler voltou (ou foi cancelado): decide o que enviar.
    private void finish(Worker w)
    {
        Conn c = w.conn;
        if (w.cancelled)
        {
            if (w.timedOut)
            {
                timedOutN++;
                w.output.clear();
                static immutable body504 = `{"detail":"tempo limite da requisição excedido"}`;
                writeResponseHead(w.output, 504, "application/json", body504.length, null, false);
                w.output.put(body504);
                w.closeAfter = true;
            }
            else
            {
                cancelledN++;
                closeConn(c); // cliente já foi embora
                return;
            }
        }
        else if (w.failed)
        {
            w.output.clear();
            writeResponseHead(w.output, 500, "text/plain; charset=utf-8", 21, null, false);
            w.output.put("Internal Server Error");
            w.closeAfter = true;
        }
        c.phase = Phase.writing;
        c.sent = 0;
        c.deadlineMs = nowMs + cfg.writeTimeoutMs;
        trySend(c);
    }

    private void trySend(Conn c)
    {
        auto w = c.worker;
        auto data = w.output.data;
        while (c.sent < data.length)
        {
            immutable n = send(c.fd, data.ptr + c.sent, data.length - c.sent, MSG_NOSIGNAL);
            if (n > 0)
            {
                c.sent += n;
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && errno == EAGAIN)
                return; // espera o próximo EPOLLOUT
            closeConn(c);
            return;
        }
        completeResponse(c);
    }

    private void completeResponse(Conn c)
    {
        auto w = c.worker;
        immutable keep = w.req.keepAlive && !w.closeAfter && !stopping;
        c.worker = null;
        releaseWorker(w);
        if (!keep)
        {
            closeConn(c);
            return;
        }
        c.buf.compact(c.total); // o que sobrou é a próxima requisição (pipelining)
        c.haveHead = false;
        c.sent100 = false;
        c.headLen = c.total = c.sent = 0;
        if (c.buf.len == 0)
            pool.release(c.buf); // ocioso: não segura buffer
        c.phase = Phase.reading;
        c.deadlineMs = nowMs + cfg.idleTimeoutMs;
    }

    // ------------------------------------------------------------------ cancelamento

    /// Cliente foi embora (`timeout = false`) ou o prazo estourou (`true`).
    private void cancelRequest(Conn c, bool timeout)
    {
        auto w = c.worker;
        if (w is null || c.phase != Phase.running)
            return;
        w.cancelled = true;
        w.timedOut = timeout;
        if (w.waiting)
        {
            wake(w);
            resume(w); // a espera lança RequestCancelled; a pilha desce e o fiber termina
        }
    }

    // ------------------------------------------------------------------ Scheduler

    override bool inRequest() nothrow
    {
        return cast(Worker) Fiber.getThis() !is null;
    }

    override uint awaitFd(int fd, uint events, long timeoutMs)
    {
        auto w = cast(Worker) Fiber.getThis();
        assert(w !is null, "vela: awaitFd fora de um fiber de requisição");
        if (w.cancelled)
            throw cancelledEx;

        epoll_event ev;
        ev.events = events | EPOLLONESHOT;
        ev.data.ptr = cast(void*) w.item;
        if (epoll_ctl(ep, EPOLL_CTL_MOD, fd, &ev) < 0)
        {
            if (errno != ENOENT || epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev) < 0)
                return IoEvent.error;
        }
        w.waitFd = fd;
        beginWait(w, timeoutMs);
        Fiber.yield();
        if (w.cancelled)
            throw cancelledEx;
        return w.wakeEvents;
    }

    override void sleepMs(long ms)
    {
        auto w = cast(Worker) Fiber.getThis();
        assert(w !is null, "vela: sleep fora de um fiber de requisição");
        if (w.cancelled)
            throw cancelledEx;
        beginWait(w, ms);
        Fiber.yield();
        if (w.cancelled)
            throw cancelledEx;
    }

    private void beginWait(Worker w, long timeoutMs)
    {
        w.waiting = true;
        w.wakeEvents = 0;
        w.timerPending = false;
        w.waitGen++;
        if (timeoutMs >= 0)
        {
            heapPush(Timer(nowMs + timeoutMs, w, w.waitGen));
            w.timerPending = true;
        }
    }

    /// Encerra a espera de `w` (fd pronto, timer ou cancelamento).
    private void wake(Worker w)
    {
        w.waiting = false;
        if (w.timerPending)
            staleTimers++; // o Timer continua no heap até vencer; já não vale mais
        w.timerPending = false;
        w.waitGen++;
        w.waitFd = -1;
    }

    // ------------------------------------------------------------------ timers (heap mínimo)

    private void heapPush(Timer t)
    {
        if (heapN == heap.length)
            heap.length = heap.length ? heap.length * 2 : 64;
        size_t i = heapN++;
        heap[i] = t;
        while (i > 0)
        {
            immutable p = (i - 1) / 2;
            if (heap[p].dl <= heap[i].dl)
                break;
            auto tmp = heap[p]; heap[p] = heap[i]; heap[i] = tmp;
            i = p;
        }
    }

    private Timer heapPop()
    {
        auto top = heap[0];
        heap[0] = heap[--heapN];
        heap[heapN] = Timer.init;
        siftDown(0);
        return top;
    }

    private void siftDown(size_t i)
    {
        for (;;)
        {
            size_t l = 2 * i + 1, r = l + 1, m = i;
            if (l < heapN && heap[l].dl < heap[m].dl) m = l;
            if (r < heapN && heap[r].dl < heap[m].dl) m = r;
            if (m == i)
                return;
            auto tmp = heap[m]; heap[m] = heap[i]; heap[i] = tmp;
            i = m;
        }
    }

    private void fireTimers()
    {
        while (heapN && heap[0].dl <= nowMs)
        {
            auto t = heapPop();
            auto w = t.w;
            if (t.gen != w.waitGen || !w.waiting)
            {
                if (staleTimers) staleTimers--;
                continue;
            }
            w.timerPending = false;
            w.wakeEvents = 0;
            wake(w);
            Conn c = w.conn;
            resume(w);
            if (c.fd >= 0 && c.phase == Phase.reading)
                drive(c);
        }
        // espera que acaba cedo deixa Timers mortos no heap: limpa quando passam da metade
        if (heapN > 1024 && staleTimers * 2 > heapN)
            compactHeap();
    }

    private void compactHeap()
    {
        size_t k = 0;
        foreach (i; 0 .. heapN)
            if (heap[i].gen == heap[i].w.waitGen && heap[i].w.waiting)
                heap[k++] = heap[i];
        foreach (i; k .. heapN)
            heap[i] = Timer.init;
        heapN = k;
        staleTimers = 0;
        if (k > 1)
            for (size_t i = k / 2; i-- > 0;)
                siftDown(i);
    }

    // ------------------------------------------------------------------ prazos de conexão

    /// Varre as conexões a cada 250 ms. Com 10 mil conexões são ~40 mil
    /// comparações por segundo; uma timer wheel só entra se o perfil pedir (M4).
    private void sweep()
    {
        foreach (c; conns)
        {
            if (c is null || c.fd < 0 || c.deadlineMs == 0 || c.deadlineMs > nowMs)
                continue;
            final switch (c.phase)
            {
                case Phase.reading:
                    if (c.buf.isNull || c.buf.len == 0)
                        closeConn(c); // keep-alive ocioso demais
                    else
                        sendErrorAndClose(c, 408); // head/corpo lento demais
                    break;
                case Phase.running:
                    cancelRequest(c, true);
                    break;
                case Phase.writing:
                    closeConn(c); // cliente não lê
                    break;
                case Phase.closed:
                    break;
            }
        }
    }

    // ------------------------------------------------------------------ fechamento

    private void sendRaw(Conn c, const(char)[] data)
    {
        // respostas de erro são curtas: um send não bloqueante basta
        send(c.fd, data.ptr, data.length, MSG_NOSIGNAL);
    }

    private void sendErrorAndClose(Conn c, int status)
    {
        errOut.clear();
        writeResponseHead(errOut, status, null, 0, null, false);
        sendRaw(c, errOut.data);
        closeConn(c);
    }

    private void closeConn(Conn c)
    {
        if (c.fd < 0)
            return;
        close(c.fd); // o kernel remove o fd do epoll
        conns[c.fd] = null;
        c.fd = -1;
        connCount--;
        if (!c.buf.isNull)
            pool.release(c.buf);
        if (c.worker !is null)
        {
            auto w = c.worker;
            c.worker = null;
            releaseWorker(w);
        }
        c.phase = Phase.closed;
        dead.push(c);
    }

    /// Objetos Conn fechados só voltam ao pool no fim do lote de eventos: um
    /// evento atrasado do mesmo lote ainda aponta para eles (e vê fd < 0).
    private void flushDead()
    {
        while (!dead.empty)
        {
            auto c = dead.pop();
            if (spare.n < 1024)
                spare.push(c);
        }
    }

    // ------------------------------------------------------------------ memória depois de rajada

    /// Passada uma rajada (>= trimBurst fibers criados) e 1 s sem nenhuma requisição em
    /// andamento, devolve memória ao SO: sem isso o RSS fica no pico, porque os Contexts
    /// e Workers desfeitos viram lixo que ninguém coleta enquanto o servidor está parado.
    /// A coleta para os outros workers por alguns ms, uma vez por rajada.
    private void trimIfQuiet()
    {
        if (!cfg.trimAfterBurst)
            return;
        if (inFlight != 0)
        {
            quietSinceMs = 0;
            return;
        }
        if (quietSinceMs == 0)
        {
            quietSinceMs = nowMs;
            return;
        }
        if (nowMs - quietSinceMs < 1000 || workersCreated - createdAtTrim < trimBurst)
            return;
        createdAtTrim = workersCreated;
        trims++;
        import core.memory : GC;

        GC.collect();
        GC.minimize();
        version (CRuntime_Glibc)
        {
            mallocTrim(0);
        }
    }

    private enum trimBurst = 128;

    // ------------------------------------------------------------------ parada

    private void beginStop()
    {
        stopping = true;
        stopDeadlineMs = nowMs + cfg.shutdownGraceMs;
        if (listenFd >= 0)
        {
            epoll_ctl(ep, EPOLL_CTL_DEL, listenFd, null);
            close(listenFd);
            listenFd = -1;
        }
    }

    private void closeIdleConns()
    {
        foreach (c; conns)
            if (c !is null && c.fd >= 0 && c.phase == Phase.reading && (c.buf.isNull || c.buf.len == 0))
                closeConn(c);
    }

    private void teardown()
    {
        // desfaz o que ainda estiver suspenso: cada handler recebe RequestCancelled
        foreach (c; conns)
            if (c !is null && c.fd >= 0 && c.phase == Phase.running)
                cancelRequest(c, false);
        foreach (c; conns)
            if (c !is null && c.fd >= 0)
                closeConn(c);
        flushDead();
        while (!idle.empty)
        {
            auto w = idle.pop();
            w.retiring = true;
            w.call();
            destroy(w);
        }
        if (listenFd >= 0)
        {
            close(listenFd);
            listenFd = -1;
        }
        atomicStore(ready, false);
    }
}

// ======================================================================= vários workers

private __gshared EpollLoop[] gLoops;

private extern (C) void onSignal(int) nothrow @nogc
{
    foreach (l; gLoops)
        l.stop();
}

private Thread startWorker(EpollLoop lp, ServerConfig cfg, HandlerFactory f)
{
    auto t = new Thread({ lp.run(cfg, f); });
    t.start();
    return t;
}

/// Sobe `cfg.workers` loops (um por núcleo se 0) e bloqueia até SIGINT/SIGTERM.
void runEpollServer(ServerConfig cfg, HandlerFactory factory)
{
    uint n = cfg.workers;
    if (n == 0)
    {
        immutable cpus = sysconf(_SC_NPROCESSORS_ONLN);
        n = cpus > 0 ? cast(uint) cpus : 1;
    }
    foreach (_; 0 .. n)
        gLoops ~= new EpollLoop;

    sigaction_t sa;
    sa.sa_handler = &onSignal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, null);
    sigaction(SIGTERM, &sa, null);

    printf("vela (epoll, %u worker%s) em http://%.*s:%d\n", n, n == 1 ? "".ptr : "s".ptr,
        cast(int) cfg.host.length, cfg.host.ptr, cast(int) cfg.port);

    Thread[] threads;
    foreach (i; 1 .. n)
        threads ~= startWorker(gLoops[i], cfg, factory);
    gLoops[0].run(cfg, factory); // o worker 0 roda na thread principal
    foreach (t; threads)
        t.join();
}
