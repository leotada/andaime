/// The process: reads the configuration, then serves what `app.d` builds. `dub test` leaves this module out.
module main 2025;

@safe:

import andaime;
import app : buildApp;
import config : config, loadConfig, setConfig{{#pg}}, Store{{/pg}};

void main(string[] args)
{
    auto c = loadConfig();
    (() @trusted => setConfig(c))(); // sound: once, on the main thread, before any worker exists
    ServerConfig cfg;
    cfg.port = config.port;
{{#pg}}
    if (config.store == Store.memory)
        cfg.workers = 1; // in-memory data lives in one worker
{{/pg}}
{{^pg}}
    cfg.workers = 1; // the data lives in memory, in one worker
{{/pg}}
    serve(&buildApp, cfg);
}
