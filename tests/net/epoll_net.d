/// Testes pela rede do EpollLoop: sobe o servidor numa thread e fala HTTP
/// cru por sockets bloqueantes. Cobre o que o M2 promete: fibers por
/// requisição, cancelamento, teto de requisições em voo, prazos, escrita
/// parcial, encolhimento dos pools e parada graciosa.
module epoll_net;

version (linux):

import vela;
import vela.engine;
import vela.server : handlerFactory;

import core.atomic : atomicOp, atomicLoad;
import core.thread : Thread;
import core.time;
import core.stdc.stdio : printf, fflush, stdout;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.time : timeval;
import core.sys.posix.unistd : close, read, write, pipe;
import core.sys.posix.fcntl : fcntl, F_SETFL, O_NONBLOCK;

// ---------------------------------------------------------------- app de teste

shared int cleanups; // shared: o handler roda na thread do servidor
__gshared int[2] stuckPipe;

string fast() => "ok";

string nap(int ms)
{
    sleep(msecs(ms));
    return "slept";
}

string cancelMe()
{
    scope (exit)
        atomicOp!"+="(cleanups, 1);
    sleep(seconds(10));
    return "nunca";
}

string stuck()
{
    awaitFd(stuckPipe[0], IoEvent.readable); // sem prazo: só o prazo da requisição salva
    return "nunca";
}

string block()
{
    import core.thread : Thread;

    Thread.sleep(120.msecs); // bloqueante de propósito: trava o worker
    return "bloqueou";
}

string off(int ms)
{
    import core.thread : Thread;

    return offload(() { Thread.sleep(ms.msecs); return "off"; });
}

string bodyLen(Context c)
{
    import core.stdc.stdio : snprintf;

    char[24] t;
    auto n = snprintf(t.ptr, t.length, "%zu", c.request.body.length);
    return t[0 .. n].idup;
}

string big()
{
    auto s = new char[8 << 20];
    s[] = 'x';
    return cast(string) s;
}

App buildApp()
{
    auto app = new App;
    app.get!("/fast", fast);
    app.get!("/nap/{ms}", nap);
    app.get!("/cancel", cancelMe);
    app.get!("/stuck", stuck);
    app.get!("/big", big);
    app.get!("/block", block);
    app.get!("/off/{ms}", off);
    app.post!("/len", bodyLen);
    return app;
}

// ---------------------------------------------------------------- servidor de teste

struct Server
{
    EpollLoop loop;
    Thread thread;
    ushort port;
}

Server start(ServerConfig cfg, ushort port = 0, bool reusePort = false)
{
    cfg.port = port;
    cfg.workers = 1;
    cfg.host = "127.0.0.1";
    cfg.reusePort = reusePort;
    auto loop = new EpollLoop;
    auto app = buildApp();
    auto factory = handlerFactory(app);
    auto t = new Thread({ loop.run(cfg, factory); });
    t.start();
    foreach (_; 0 .. 400)
    {
        if (atomicLoad(loop.ready))
            return Server(loop, t, loop.boundPort);
        Thread.sleep(5.msecs);
    }
    assert(0, "servidor não ficou pronto");
}

void stop(ref Server s)
{
    s.loop.stop();
    s.thread.join();
}

// ---------------------------------------------------------------- cliente cru

// O GC do D suspende as threads com sinais, o que interrompe read/send bloqueantes
// com EINTR. O servidor já trata isso; o cliente de teste também precisa.
ptrdiff_t rd(int fd, void* p, size_t n)
{
    import core.stdc.errno : errno, EINTR;

    for (;;)
    {
        auto r = read(fd, p, n);
        if (r >= 0 || errno != EINTR)
            return r;
    }
}

ptrdiff_t sd(int fd, const(void)* p, size_t n)
{
    import core.stdc.errno : errno, EINTR;

    for (;;)
    {
        auto r = send(fd, p, n, 0x4000);
        if (r >= 0 || errno != EINTR)
            return r;
    }
}

struct Client
{
    int fd = -1;
    string pending;
}

Client dial(ushort port, int rcvTimeoutMs = 5000)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    assert(connect(fd, cast(sockaddr*)&a, a.sizeof) == 0, "connect falhou");
    timeval tv = timeval(rcvTimeoutMs / 1000, (rcvTimeoutMs % 1000) * 1000);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tv.sizeof);
    return Client(fd);
}

void tx(ref Client c, string s)
{
    while (s.length)
    {
        auto n = sd(c.fd, s.ptr, s.length);
        assert(n > 0, "send falhou");
        s = s[n .. $];
    }
}

void hang(ref Client c)
{
    close(c.fd);
    c.fd = -1;
}

struct Resp
{
    int status; /// 0 = conexão fechada/expirada sem resposta
    string head, body;
    bool closed;
}

Resp rx(ref Client c)
{
    import std.algorithm : canFind;
    import std.string : indexOf;
    import std.conv : to;

    Resp r;
    char[65536] tmp;
    while (c.pending.indexOf("\r\n\r\n") < 0)
    {
        auto n = rd(c.fd, tmp.ptr, tmp.length);
        if (n <= 0)
        {
            r.closed = true;
            return r;
        }
        c.pending ~= tmp[0 .. n].idup;
    }
    auto he = c.pending.indexOf("\r\n\r\n") + 4;
    r.head = c.pending[0 .. he];
    r.status = r.head[9 .. 12].to!int;
    size_t want = 0;
    auto cl = r.head.indexOf("Content-Length: ");
    if (cl >= 0)
    {
        auto e = r.head.indexOf("\r\n", cl);
        want = r.head[cl + 16 .. e].to!size_t;
    }
    while (c.pending.length < he + want)
    {
        auto n = rd(c.fd, tmp.ptr, tmp.length);
        if (n <= 0)
        {
            r.closed = true;
            return r;
        }
        c.pending ~= tmp[0 .. n].idup;
    }
    r.body = c.pending[he .. he + want];
    c.pending = c.pending[he + want .. $];
    r.closed = r.head.canFind("Connection: close");
    return r;
}

Resp request(ushort port, string path)
{
    auto c = dial(port);
    c.tx("GET " ~ path ~ " HTTP/1.1\r\nHost: t\r\n\r\n");
    auto r = c.rx();
    c.hang();
    return r;
}

bool waitFor(scope bool delegate() cond, int ms)
{
    foreach (_; 0 .. ms / 5)
    {
        if (cond())
            return true;
        Thread.sleep(5.msecs);
    }
    return cond();
}

void ok(string name)
{
    printf("ok  %.*s\n", cast(int) name.length, name.ptr);
    fflush(stdout);
}

// ---------------------------------------------------------------- testes

void testBasico()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto r = request(s.port, "/fast");
    assert(r.status == 200 && r.body == "ok", r.head);
    r = request(s.port, "/nao-existe");
    assert(r.status == 404, r.head);
    ok("GET simples e 404");
}

void testKeepAliveEPipelining()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    auto c = dial(s.port);
    foreach (_; 0 .. 3)
    {
        c.tx("GET /fast HTTP/1.1\r\nHost: t\r\n\r\n");
        auto r = c.rx();
        assert(r.status == 200 && !r.closed, r.head);
    }
    ok("keep-alive: 3 requisições na mesma conexão");

    // pipelining com um handler que suspende no meio: a ordem se mantém
    c.tx("GET /fast HTTP/1.1\r\nHost: t\r\n\r\nGET /nap/50 HTTP/1.1\r\nHost: t\r\n\r\n"
        ~ "GET /fast HTTP/1.1\r\nHost: t\r\n\r\n");
    assert(c.rx().body == "ok");
    assert(c.rx().body == "slept");
    assert(c.rx().body == "ok");
    c.hang();
    ok("pipelining com handler suspenso no meio, ordem preservada");
}

void testHeadLento()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto c = dial(s.port);
    foreach (ch; "GET /fast HTTP/1.1\r\nHost: t\r\n\r\n")
    {
        c.tx([ch].idup);
        Thread.sleep(2.msecs);
    }
    auto r = c.rx();
    assert(r.status == 200 && r.body == "ok", r.head);
    c.hang();
    ok("head chegando byte a byte");
}

void testConcorrencia()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    enum N = 300;
    Client[N] cs;
    immutable t0 = MonoTime.currTime;
    foreach (ref c; cs)
    {
        c = dial(s.port, 8000);
        c.tx("GET /nap/300 HTTP/1.1\r\nHost: t\r\n\r\n");
    }
    foreach (ref c; cs)
    {
        auto r = c.rx();
        assert(r.status == 200 && r.body == "slept", r.head);
        c.hang();
    }
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    auto st = s.loop.stats();
    assert(ms < 1500, "300 requisições de 300 ms deveriam levar ~300 ms, levaram mais");
    assert(st.peakInFlight >= 250, "deveria haver ~300 requisições em voo ao mesmo tempo");
    printf("ok  %d requisições de 300 ms em %ld ms numa thread (pico em voo: %zu)\n", N, ms, st.peakInFlight);
}

void testCancelamento()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    auto c = dial(s.port);
    c.tx("GET /cancel HTTP/1.1\r\nHost: t\r\n\r\n");
    assert(waitFor(() => s.loop.stats().inFlight == 1, 1000), "handler não começou");
    c.hang(); // o cliente vai embora com o fiber suspenso
    assert(waitFor(() => s.loop.stats().inFlight == 0, 1000), "fiber não foi cancelado");
    assert(atomicLoad(cleanups) == 1, "scope(exit) do handler não rodou");
    assert(s.loop.stats().cancelled == 1);
    ok("cliente desconecta com fiber suspenso: RequestCancelled, scope(exit) roda, fiber volta ao pool");
}

void testTetoDeRequisicoes()
{
    ServerConfig cfg;
    cfg.maxInFlight = 4;
    auto s = start(cfg);
    scope (exit) stop(s);

    Client[6] cs;
    foreach (ref c; cs)
    {
        c = dial(s.port);
        c.tx("GET /nap/400 HTTP/1.1\r\nHost: t\r\n\r\n");
        Thread.sleep(2.msecs); // chegada em ordem
    }
    int n200, n503;
    bool retryAfter;
    foreach (ref c; cs)
    {
        auto r = c.rx();
        if (r.status == 200) n200++;
        if (r.status == 503) { n503++; retryAfter = r.head.indexOfS("Retry-After: 1"); }
        c.hang();
    }
    assert(n200 == 4 && n503 == 2, "esperava 4x200 e 2x503");
    assert(retryAfter, "503 sem Retry-After");
    assert(s.loop.stats().rejected == 2);
    ok("teto de 4 em voo: 4x200 e 2x503 com Retry-After");
}

bool indexOfS(string h, string needle)
{
    import std.string : indexOf;

    return h.indexOf(needle) >= 0;
}

void testPrazoDaRequisicao()
{
    pipe(stuckPipe);
    fcntl(stuckPipe[0], F_SETFL, O_NONBLOCK);
    scope (exit) { close(stuckPipe[0]); close(stuckPipe[1]); }

    ServerConfig cfg;
    cfg.requestTimeoutMs = 300;
    auto s = start(cfg);
    scope (exit) stop(s);

    immutable t0 = MonoTime.currTime;
    auto r = request(s.port, "/stuck");
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(r.status == 504, r.head);
    assert(ms >= 250 && ms < 1500, "prazo de 300 ms");
    assert(waitFor(() => s.loop.stats().inFlight == 0, 500));
    assert(s.loop.stats().timedOut == 1);
    ok("handler preso em awaitFd sem prazo: 504 pelo prazo da requisição");
}

void testEscritaParcial()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);
    auto c = dial(s.port, 10_000);
    c.tx("GET /big HTTP/1.1\r\nHost: t\r\n\r\n");
    Thread.sleep(300.msecs); // o cliente não lê: o send do servidor enche e dá EAGAIN
    assert(s.loop.stats().inFlight == 1, "a resposta grande deveria estar pendente (EPOLLOUT)");
    auto r = c.rx();
    assert(r.status == 200 && r.body.length == (8 << 20), "corpo incompleto");
    foreach (ch; r.body)
        assert(ch == 'x');
    c.hang();
    assert(waitFor(() => s.loop.stats().inFlight == 0, 500));
    ok("resposta de 8 MiB com cliente lento (escrita parcial + EPOLLOUT)");
}

void testEncolherPools()
{
    ServerConfig cfg;
    cfg.maxIdleWorkers = 8;
    auto s = start(cfg);
    scope (exit) stop(s);

    enum N = 200;
    Client[N] cs;
    foreach (ref c; cs)
    {
        c = dial(s.port, 8000);
        c.tx("GET /nap/100 HTTP/1.1\r\nHost: t\r\n\r\n");
    }
    foreach (ref c; cs)
    {
        assert(c.rx().status == 200);
        c.hang();
    }
    assert(waitFor(() => s.loop.stats().inFlight == 0, 1000));
    auto st = s.loop.stats();
    assert(st.workersCreated >= 150, "a rajada deveria ter criado ~200 fibers");
    assert(st.idleWorkers <= 8, "fibers ociosos acima do teto não foram desfeitos");
    assert(st.workersRetired >= st.workersCreated - 8);
    assert(waitFor(() => s.loop.trimCount() == 1, 3500), "a limpeza de memória pós-rajada não rodou");
    printf("ok  rajada de %d: %zu fibers criados, %zu desfeitos, %zu ociosos no pool\n",
        N, st.workersCreated, st.workersRetired, st.idleWorkers);
}

void testEntradaInvalida()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    static struct Case { string raw; int status; }
    static immutable cases = [
        Case("FOO / HTTP/1.1\r\nHost: t\r\n\r\n", 501),
        Case("GET / HTTP/2.0\r\nHost: t\r\n\r\n", 505),
        Case("POST /x HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n", 400),
        Case("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", 501),
        Case("GET /x HTTP/1.1\r\nA: b\r\n c\r\n\r\n", 400),
    ];
    foreach (cs; cases)
    {
        auto c = dial(s.port);
        c.tx(cs.raw);
        auto r = c.rx();
        assert(r.status == cs.status, cs.raw);
        c.hang();
    }
    // head maior que o limite
    auto c = dial(s.port);
    string h = "GET /fast HTTP/1.1\r\nHost: t\r\nX: ";
    foreach (_; 0 .. 9000)
        h ~= 'a';
    c.tx(h ~ "\r\n\r\n");
    assert(c.rx().status == 431);
    c.hang();
    // headers demais (acima da tabela de 32 do fiber)
    c = dial(s.port);
    string many = "GET /fast HTTP/1.1\r\nHost: t\r\n";
    foreach (i; 0 .. 40)
        many ~= "X-H" ~ cast(char)('a' + i % 26) ~ cast(char)('a' + i / 26) ~ ": v\r\n";
    c.tx(many ~ "\r\n");
    assert(c.rx().status == 431);
    c.hang();
    // corpo maior que o limite (Limits.maxBodyBytes)
    c = dial(s.port);
    c.tx("POST /fast HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n");
    assert(c.rx().status == 413);
    c.hang();
    ok("entradas inválidas: 501, 505, 400 (smuggling e obs-fold), 431, 413");
}

void testPrazosDeConexao()
{
    ServerConfig cfg;
    cfg.headerTimeoutMs = 300;
    cfg.idleTimeoutMs = 300;
    auto s = start(cfg);
    scope (exit) stop(s);

    // slowloris: começa o head e para
    auto c = dial(s.port);
    c.tx("GET /fast HTTP/1.1\r\nHost");
    auto r = c.rx();
    assert(r.status == 408 || r.closed, "head lento deveria ser cortado");
    c.hang();

    // keep-alive ocioso: conecta e não manda nada
    c = dial(s.port);
    r = c.rx();
    assert(r.closed && r.status == 0, "conexão ociosa deveria ser fechada");
    c.hang();
    assert(waitFor(() => s.loop.stats().connections == 0, 500));
    ok("prazos: head lento (408) e conexão ociosa fechada");
}

void testPararComGentileza()
{
    auto s = start(ServerConfig.init);
    auto c = dial(s.port);
    c.tx("GET /nap/300 HTTP/1.1\r\nHost: t\r\n\r\n");
    assert(waitFor(() => s.loop.stats().inFlight == 1, 1000));
    s.loop.stop(); // pede parada com uma requisição em curso
    auto r = c.rx();
    assert(r.status == 200 && r.body == "slept", "a requisição em curso deveria terminar");
    char[1] b;
    assert(rd(c.fd, b.ptr, 1) == 0, "durante a parada, o servidor fecha a conexão depois da resposta");
    c.hang();
    s.thread.join();
    ok("parada graciosa: termina a requisição em curso e encerra o loop");
}

void testDoisWorkers()
{
    // dois loops na mesma porta (SO_REUSEPORT), compartilhando o mesmo App
    auto a = start(ServerConfig.init, 0, true);
    auto b = start(ServerConfig.init, a.port, true);
    scope (exit) { stop(a); stop(b); }
    foreach (i; 0 .. 60)
    {
        auto r = request(a.port, "/nap/20");
        assert(r.status == 200 && r.body == "slept");
    }
    ok("dois workers com SO_REUSEPORT na mesma porta");
}

void testDateEDetector()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    auto r = request(s.port, "/fast");
    import std.string : indexOf;

    auto d = r.head.indexOf("Date: ");
    assert(d >= 0, "resposta sem header Date");
    auto line = r.head[d + 6 .. d + 6 + 29];
    assert(line[$ - 4 .. $] == " GMT" && line[3] == ',' && line[7] == ' ', line);

    // esperar com sleep NÃO é travar o worker; Thread.sleep é
    assert(request(s.port, "/nap/200").status == 200);
    assert(s.loop.stats().stalls == 0, "sleep cooperativo foi tratado como travamento");
    assert(request(s.port, "/block").status == 200);
    auto st = s.loop.stats();
    assert(st.stalls == 1 && st.maxStallMs >= 100, "o handler bloqueante deveria ser detectado");
    ok("header Date presente; detector de loop travado conta só o handler que bloqueia");
}

void testExpectContinue()
{
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    // o cliente manda só o head e espera o 100 antes de mandar o corpo
    auto c = dial(s.port);
    c.tx("POST /len HTTP/1.1\r\nHost: t\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n");
    auto r = c.rx();
    assert(r.status == 100, r.head);
    c.tx("hello");
    r = c.rx();
    assert(r.status == 200 && r.body == "5", r.head);

    // a mesma conexão (keep-alive) serve outra requisição com Expect
    c.tx("POST /len HTTP/1.1\r\nHost: t\r\nContent-Length: 3\r\nExpect: 100-Continue\r\n\r\n");
    assert(c.rx().status == 100);
    c.tx("abc");
    r = c.rx();
    assert(r.status == 200 && r.body == "3");

    // corpo já junto com o head: não precisa do 100
    c.tx("POST /len HTTP/1.1\r\nHost: t\r\nContent-Length: 2\r\nExpect: 100-continue\r\n\r\nhi");
    r = c.rx();
    assert(r.status == 200 && r.body == "2", r.head);
    c.hang();

    // outras expectativas: 417; corpo grande demais: 413 sem prometer 100
    c = dial(s.port);
    c.tx("POST /len HTTP/1.1\r\nHost: t\r\nContent-Length: 1\r\nExpect: algo-estranho\r\n\r\n");
    assert(c.rx().status == 417);
    c.hang();
    c = dial(s.port);
    c.tx("POST /len HTTP/1.1\r\nHost: t\r\nContent-Length: 99999999\r\nExpect: 100-continue\r\n\r\n");
    assert(c.rx().status == 413);
    c.hang();
    ok("Expect: 100-continue: aval antes do corpo, 417 para outras expectativas, 413 sem 100");
}

void testOffload()
{
    // pool configurado em main: 2 threads, fila de 2
    auto s = start(ServerConfig.init);
    scope (exit) stop(s);

    Client[4] cs;
    immutable t0 = MonoTime.currTime;
    foreach (ref c; cs)
    {
        c = dial(s.port, 8000);
        c.tx("GET /off/200 HTTP/1.1\r\nHost: t\r\n\r\n");
        Thread.sleep(20.msecs); // dá tempo de uma thread do pool tirar a tarefa da fila
    }
    assert(waitFor(() => s.loop.stats().inFlight == 4, 1000));

    // com o pool inteiro ocupado, o worker continua livre
    immutable t1 = MonoTime.currTime;
    auto f = request(s.port, "/fast");
    assert(f.status == 200 && (MonoTime.currTime - t1).total!"msecs" < 50, "o worker ficou preso pelo offload");

    // 5ª tarefa: 2 rodando + 2 na fila = cheio
    auto sat = request(s.port, "/off/200");
    assert(sat.status == 500, sat.head);

    foreach (ref c; cs)
    {
        auto r = c.rx();
        assert(r.status == 200 && r.body == "off", r.head);
        c.hang();
    }
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    assert(ms >= 380 && ms < 900, "4 tarefas de 200 ms em 2 threads deveriam levar ~400 ms");
    ok("offload: pool de 2 threads, fila de 2, worker livre durante o trabalho, saturação vira erro");

    // cliente some enquanto o trabalho roda: o fiber é cancelado na hora, o trabalho termina sozinho
    auto c = dial(s.port);
    c.tx("GET /off/300 HTTP/1.1\r\nHost: t\r\n\r\n");
    assert(waitFor(() => s.loop.stats().inFlight == 1, 1000));
    c.hang();
    assert(waitFor(() => s.loop.stats().inFlight == 0, 200), "fiber deveria ser cancelado sem esperar o trabalho");
    Thread.sleep(400.msecs); // o job termina e fecha o eventfd sem estragar nada
    auto again = request(s.port, "/off/10");
    assert(again.status == 200, again.head);
    ok("offload: cancelamento solta o fiber e o trabalho termina sozinho");
}

void main()
{
    configureOffload(2, 2);
    testBasico();
    testKeepAliveEPipelining();
    testHeadLento();
    testConcorrencia();
    testCancelamento();
    testTetoDeRequisicoes();
    testPrazoDaRequisicao();
    testEscritaParcial();
    testEncolherPools();
    testEntradaInvalida();
    testPrazosDeConexao();
    testPararComGentileza();
    testDoisWorkers();
    testDateEDetector();
    testOffload();
    testExpectContinue();
    printf("todos os testes de rede passaram\n");
}
