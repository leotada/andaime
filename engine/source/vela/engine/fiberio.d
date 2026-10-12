/// E/S cooperativa para handlers.
///
/// Dentro de uma requisição, `sleep` e `awaitFd` suspendem o fiber do handler
/// e devolvem o worker ao loop, que segue atendendo outras conexões. Fora de
/// um fiber do vela (testes, dev server) caem num fallback bloqueante, então o
/// mesmo código funciona nos dois mundos.
///
/// Regra de ouro: toda espera de I/O num handler passa por aqui (ou por uma
/// biblioteca construída sobre isto). Uma chamada bloqueante qualquer (um
/// `sleep` de verdade, uma lib C síncrona) trava o worker inteiro.
module vela.engine.fiberio;

import core.time : Duration;

/// Lançada DENTRO do handler quando a requisição foi cancelada (o cliente
/// desconectou ou o prazo estourou). Não é `Exception` de propósito: um
/// `catch (Exception)` do usuário não a engole por acidente, e `scope(exit)`
/// e destrutores rodam normalmente na descida da pilha. Quem capturar
/// `Throwable` e continuar só consegue mais um `awaitFd`, que lança de novo.
final class RequestCancelled : Throwable
{
    this() @nogc nothrow @safe
    {
        super("vela: requisição cancelada (cliente desconectou ou prazo estourou)");
    }
}

/// Eventos de `awaitFd`. Os valores coincidem com EPOLLIN/EPOLLOUT e POLLIN/POLLOUT.
enum IoEvent : uint
{
    readable = 0x1,
    writable = 0x4,
    error = 0x8,   /// só no resultado
    hangup = 0x10, /// só no resultado
}

/// Implementado pelo loop de cada worker.
interface Scheduler
{
    /// Verdadeiro quando chamado de dentro do fiber de uma requisição.
    bool inRequest() nothrow;
    /// Devolve a máscara de eventos prontos, ou 0 se o prazo venceu. `timeoutMs < 0` = sem prazo.
    uint awaitFd(int fd, uint events, long timeoutMs);
    void sleepMs(long ms);
}

/// O scheduler do worker desta thread (variável de módulo = thread-local).
Scheduler currentScheduler;

private long toMs(Duration d) nothrow @nogc @safe
{
    immutable us = d.total!"usecs";
    return us <= 0 ? 0 : (us + 999) / 1000;
}

/// Espera `d` sem bloquear o worker (dentro de uma requisição).
void sleep(Duration d)
{
    if (currentScheduler !is null && currentScheduler.inRequest)
        currentScheduler.sleepMs(toMs(d));
    else
    {
        import core.thread : Thread;

        Thread.sleep(d);
    }
}

/// Espera `fd` ficar pronto para os `events` pedidos (`IoEvent.readable`,
/// `IoEvent.writable`). Devolve a máscara de eventos prontos, ou 0 se `timeout`
/// venceu. O fd precisa estar em modo não bloqueante. Lança `RequestCancelled`
/// se a requisição foi cancelada enquanto esperava.
uint awaitFd(int fd, uint events, Duration timeout = Duration.max)
{
    immutable long ms = timeout == Duration.max ? -1 : toMs(timeout);
    if (currentScheduler !is null && currentScheduler.inRequest)
        return currentScheduler.awaitFd(fd, events, ms);

    // fallback bloqueante (fora do loop)
    import core.sys.posix.poll : poll, pollfd;

    pollfd p = pollfd(fd, cast(short) events, 0);
    immutable r = poll(&p, 1, cast(int)(ms < 0 ? -1 : ms));
    return r > 0 ? cast(uint) p.revents : 0;
}
