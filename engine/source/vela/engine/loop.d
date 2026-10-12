/// Contrato do event loop. A implementação do Linux está em `vela.engine.epoll`;
/// kqueue (M5) e io_uring (M6) implementam a mesma interface.
///
/// Modelo: um worker por núcleo, cada um com seu loop, seu BufferPool e seu
/// socket de escuta (SO_REUSEPORT). Nenhum estado mutável compartilhado entre
/// workers. Cada requisição roda num fiber do próprio worker: esperar I/O
/// (`vela.engine.fiberio`) suspende o fiber e o loop atende outras conexões.
module vela.engine.loop;

import vela.http.types : Request;
import vela.http.buffer : ByteBuffer;
import vela.http.parser : Limits;

/// O engine chama isto com uma requisição completa (head + corpo) e
/// espera a resposta inteira (head + corpo) serializada em `output`.
/// Roda dentro de um fiber, então pode chamar `sleep`/`awaitFd`.
alias RequestCallback = void delegate(ref Request req, ref ByteBuffer output);

/// Chamada uma vez por fiber (não por requisição) para criar o estado que o
/// callback reaproveita (Context, buffers...). Pode ser chamada de várias
/// threads, uma por worker, então precisa ser segura para isso.
alias HandlerFactory = RequestCallback delegate();

struct ServerConfig
{
    string host = "0.0.0.0";
    ushort port = 8080;
    uint workers = 0;                /// 0 = número de núcleos
    uint backlog = 1024;
    uint maxConnections = 10_000;    /// por worker
    uint maxInFlight = 1024;         /// requisições em andamento por worker; acima, 503
    uint maxIdleWorkers = 64;        /// fibers ociosos mantidos em pool; o resto é desfeito
    uint fiberStackBytes = 128 << 10; /// stack virtual de cada fiber (só o usado vira RSS)
    uint headerTimeoutMs = 10_000;   /// do primeiro byte ao fim do head (slowloris)
    uint idleTimeoutMs = 60_000;     /// keep-alive ocioso
    uint requestTimeoutMs = 30_000;  /// handler passou disso: cancelado, 504
    uint writeTimeoutMs = 30_000;    /// cliente que não lê a resposta
    uint shutdownGraceMs = 10_000;   /// espera pelas requisições em curso no stop
    uint stallWarnMs = 50;           /// aviso quando um handler segura o worker mais que isso sem ceder; 0 desliga
    bool reusePort = true;           /// SO_REUSEPORT: um listener por worker
    bool trimAfterBurst = true;      /// devolve memória ao SO 1 s depois de uma rajada (coleta o GC)
    Limits limits;
}

/// Contadores de um worker (leitura sem lock: só para métricas e testes).
struct LoopStats
{
    size_t inFlight;       /// fibers em uso agora (executando, suspensos ou enviando)
    size_t peakInFlight;
    size_t workersCreated; /// fibers criados desde o início
    size_t workersRetired; /// fibers desfeitos por excesso de ociosos
    size_t idleWorkers;
    size_t connections;
    size_t rejected;       /// 503 por teto de requisições em voo
    size_t cancelled;      /// requisições canceladas (cliente foi embora)
    size_t timedOut;       /// requisições canceladas por prazo (504)
    size_t stalls;         /// handlers que seguraram o worker além de stallWarnMs
    long maxStallMs;       /// o maior trecho sem ceder visto até agora
}

/// Backend de I/O. Implementações previstas:
/// - EpollLoop  (Linux, M2)    edge-triggered, accept4, fiber por requisição
/// - KqueueLoop (macOS/BSD, M5)
/// - UringLoop  (Linux 6.0+, M6)  multishot accept/recv, buffer rings
interface EventLoop
{
    /// Bloqueia a thread atual servindo conexões até `stop`.
    void run(ref const ServerConfig cfg, HandlerFactory factory);

    /// Pede parada graciosa: para de aceitar, drena requisições em curso.
    /// Pode ser chamada de outra thread ou de um signal handler.
    void stop() nothrow @nogc;
}

/// Estados de uma conexão no loop.
enum ConnState : ubyte
{
    idle,        /// sem buffer emprestado; esperando bytes
    readingHead, /// buffer emprestado; head incompleto
    readingBody, /// head ok; faltam bytes do corpo
    running,     /// handler no fiber (executando ou suspenso esperando I/O)
    writing,     /// resposta pronta; enviando
    closing,
}
