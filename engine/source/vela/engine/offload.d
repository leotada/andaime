/// Pool de threads limitado para o que NÃO dá para fazer cooperativamente:
/// DNS (`getaddrinfo`), CPU pesada, bibliotecas C síncronas.
///
/// `offload(() => trabalhoPesado())` roda o delegate numa thread do pool e
/// suspende só o fiber que chamou: o worker segue atendendo outras conexões.
/// O resultado volta por um eventfd que o fiber espera com `awaitFd`.
///
/// Limites (nada cresce sem teto): `threads` fixas e fila de `queueMax`
/// tarefas; cheia, `offload` lança `PoolSaturated` na hora (o handler decide
/// se vira 503). Se a requisição é cancelada enquanto o trabalho roda, o
/// trabalho termina sozinho e o resultado é descartado.
///
/// Fora de um fiber do vela (testes, dev server) o delegate roda inline.
module vela.engine.offload;

import core.atomic : atomicFetchSub, atomicStore, atomicLoad;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.sys.linux.sys.eventfd : eventfd;
import core.sys.posix.unistd : close, write;
import core.thread : Thread;

import vela.engine.fiberio : awaitFd, currentScheduler, IoEvent;

/// A fila do pool está cheia: há trabalho demais pendente.
final class PoolSaturated : Exception
{
    this() @safe pure nothrow { super("vela: pool de threads saturado (fila cheia)"); }
}

private alias Job = void delegate();

/// Pool com threads fixas e fila circular de tamanho fixo.
final class ThreadPool
{
    private Mutex mu;
    private Condition cv;
    private Job[] ring;
    private size_t head, count;
    private bool closing;
    private Thread[] threads;

    this(uint nThreads, uint queueMax)
    {
        assert(nThreads > 0 && queueMax > 0, "vela: ThreadPool precisa de threads e fila > 0");
        mu = new Mutex;
        cv = new Condition(mu);
        ring = new Job[queueMax];
        foreach (i; 0 .. nThreads)
        {
            auto t = new Thread(&loop);
            t.isDaemon = true;
            t.start();
            threads ~= t;
        }
    }

    /// Enfileira; devolve false se a fila está cheia.
    bool submit(Job j)
    {
        synchronized (mu)
        {
            if (closing || count == ring.length)
                return false;
            ring[(head + count) % ring.length] = j;
            count++;
        }
        cv.notify();
        return true;
    }

    /// Tarefas esperando numa thread livre (métrica).
    size_t pending()
    {
        synchronized (mu)
            return count;
    }

    /// Termina as tarefas já enfileiradas e encerra as threads.
    void shutdown()
    {
        synchronized (mu)
            closing = true;
        cv.notifyAll();
        foreach (t; threads)
            t.join();
        threads = null;
    }

    private void loop()
    {
        for (;;)
        {
            Job j;
            synchronized (mu)
            {
                while (count == 0 && !closing)
                    cv.wait();
                if (count == 0)
                    return;
                j = ring[head];
                ring[head] = null;
                head = (head + 1) % ring.length;
                count--;
            }
            j();
        }
    }
}

private __gshared ThreadPool gPool;
private __gshared Mutex gPoolMu;
private __gshared uint gThreads = 4, gQueue = 256;

shared static this()
{
    gPoolMu = new Mutex;
}

/// Define o tamanho do pool padrão. Chame antes de `serve`; depois que o pool
/// existe, a chamada é ignorada (devolve false).
bool configureOffload(uint threads, uint queueMax)
{
    synchronized (gPoolMu)
    {
        if (gPool !is null)
            return false;
        gThreads = threads;
        gQueue = queueMax;
        return true;
    }
}

/// O pool padrão (criado no primeiro uso).
ThreadPool offloadPool()
{
    synchronized (gPoolMu)
    {
        if (gPool is null)
            gPool = new ThreadPool(gThreads, gQueue);
        return gPool;
    }
}

/// Estado compartilhado entre o fiber e a thread do pool. Dono do eventfd:
/// quem decrementar `refs` até zero fecha o fd.
private final class Call(T)
{
    int efd = -1;
    shared int refs = 2;
    Throwable err;
    static if (!is(T == void))
        T value;

    void release() nothrow @nogc
    {
        if (atomicFetchSub(refs, 1) == 1)
            close(efd);
    }
}

/// Roda `work` numa thread do pool e devolve o resultado, suspendendo só o fiber.
/// Exceções do `work` são relançadas aqui.
T offload(T)(T delegate() work)
{
    if (currentScheduler is null || !currentScheduler.inRequest)
        return work(); // fora de um fiber: inline

    auto call = new Call!T;
    call.efd = eventfd(0, 0x800 /*EFD_NONBLOCK*/ | 0x80000 /*EFD_CLOEXEC*/);
    if (call.efd < 0)
        throw new Exception("vela: eventfd falhou em offload");

    auto job = delegate() {
        try
        {
            static if (is(T == void))
                work();
            else
                call.value = work();
        }
        catch (Throwable t)
            call.err = t;
        ulong one = 1;
        write(call.efd, &one, one.sizeof);
        call.release();
    };

    if (!offloadPool().submit(job))
    {
        close(call.efd);
        throw new PoolSaturated;
    }

    // Se awaitFd lançar RequestCancelled, o job ainda vai escrever no eventfd
    // e fechá-lo; aqui só soltamos a nossa referência.
    scope (exit)
        call.release();
    awaitFd(call.efd, IoEvent.readable);

    if (call.err !is null)
        throw call.err;
    static if (!is(T == void))
        return call.value;
}

unittest
{
    // fora de fiber: inline
    assert(offload(() => 40 + 2) == 42);
    int x;
    offload(() { x = 7; });
    assert(x == 7);
    bool threw;
    try
        offload(() { throw new Exception("boom"); });
    catch (Exception e)
        threw = e.msg == "boom";
    assert(threw);

    auto p = new ThreadPool(2, 2);
    shared int n;
    foreach (i; 0 .. 2)
        assert(p.submit(() { import core.atomic : atomicOp; atomicOp!"+="(n, 1); }));
    p.shutdown();
    assert(atomicLoad(n) == 2);
}
