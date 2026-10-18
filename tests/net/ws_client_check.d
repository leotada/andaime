/// andaime's WebSocket client against another implementation's server (tools/ws_interop.sh runs python's `websockets` echo
/// server, which negotiates permessage-deflate). Runs outside a request fiber, so every wait blocks. Usage: ws_client_check <port>
module ws_client_check 2025;

import andaime;
import std.conv : to;
import std.stdio : writeln;

int failures;

void check(bool cond, string label)
{
    writeln(cond ? "ok  " : "FAILED: ", label);
    if (!cond)
        failures++;
}

int main(string[] args)
{
    immutable url = "ws://127.0.0.1:" ~ args[1] ~ "/";
    foreach (compression; [false, true])
    {
        immutable mode = compression ? "with permessage-deflate" : "uncompressed";
        WsClientOptions opts;
        opts.compression = compression;
        opts.maxMessageBytes = 8 << 20;
        auto ws = wsConnect(url, null, opts);
        ws.send("hello");
        check(ws.receive().text == "hello", "andaime client (" ~ mode ~ "): text echo");
        auto big = new ubyte[2 << 20];
        foreach (i, ref b; big)
            b = cast(ubyte)(i % 251);
        ws.sendBinary(big);
        auto m = ws.receive();
        check(m.isBinary && m.data == big, "andaime client (" ~ mode ~ "): 2 MiB binary echo");
        foreach (i; 0 .. 20)
            ws.send("n" ~ i.to!string ~ " " ~ "abc".idup ~ "abc");
        bool inOrder = true;
        foreach (i; 0 .. 20)
            inOrder &= ws.receive().text == "n" ~ i.to!string ~ " abcabc";
        check(inOrder, "andaime client (" ~ mode ~ "): 20 messages in order");
        ws.close(1000, "bye");
        m = ws.receive();
        check(m.isClose && m.closeCode == 1000, "andaime client (" ~ mode ~ "): close handshake (" ~ m.closeCode.to!string ~ ")");
        ws.disconnect();
    }
    return failures ? 1 : 0;
}
