/// The process: serves what `app.d` builds. `dub test` leaves this module out.
module main;

import andaime;
import app : buildApp;

void main()
{
    ServerConfig cfg;
    cfg.workers = 1; // the items live in memory, in one worker
    serve(&buildApp, cfg);
}
