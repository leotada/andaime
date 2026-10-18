/// Server for tools/crash_check.sh: a handler that overflows its fiber stack, to check what the process says when it
/// dies. Usage: stack_overflow <port>
module stack_overflow;

import andaime;
import std.conv : to;

@safe:

int deep(int n)
{
    char[1024] pad = void;
    pad[0] = cast(char) n;
    return n <= 0 ? pad[0] : deep(n - 1) + pad[0];
}

string recurse(int n) => deep(n) > 0 ? "deep" : "shallow";
string fast() => "ok";

void main(string[] args) @trusted
{
    ServerConfig cfg;
    cfg.port = args[1].to!ushort;
    cfg.workers = 1;
    serve(() {
        auto app = new App;
        app.get!("/recurse/{n}", recurse);
        app.get!("/fast", fast);
        return app;
    }, cfg);
}
