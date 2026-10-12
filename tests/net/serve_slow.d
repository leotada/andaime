/// Servidor de carga: uma rota que "espera uma API externa" por N ms (padrão 3000).
/// Uso: serve_slow [porta] [esperaMs] — veja o teste de memória em tools/check.sh.
module serve_slow;

import vela;
import core.time : msecs;

__gshared long waitMs = 3000;

string slow()
{
    sleep(msecs(waitMs));
    return "ok";
}

void main(string[] args)
{
    import std.conv : to;

    if (args.length > 2)
        waitMs = args[2].to!long;
    auto app = new App;
    app.get!("/slow", slow);
    ServerConfig cfg;
    cfg.port = args.length > 1 ? args[1].to!ushort : 18090;
    cfg.workers = 1;
    cfg.maxConnections = 15_000;
    cfg.maxInFlight = 15_000;
    app.serve(cfg);
}
