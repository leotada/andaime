/// andaime.log on the real server: requests whose fibers interleave on one worker thread each log with their own request id
/// (the id lives in the request fiber's slot, not in a per-thread variable that the next fiber would overwrite).
module log_net 2025;

version (linux):

import andaime;

import core.thread : Thread;
import core.time : msecs, MonoTime;
import core.stdc.stdio : printf, fflush, stdout;
import core.sys.posix.signal : kill, SIGTERM;
import core.sys.posix.unistd : getpid, pipe, dup, dup2, close, read;
import core.sys.posix.fcntl : fcntl, F_SETFL, O_NONBLOCK;
import std.socket : TcpSocket, InternetAddress, SocketShutdown;
import std.json : parseJSON;
import std.string : splitLines, indexOf;
import std.conv : to;

enum ushort port = 18_437;

string work(int ms) @safe
{
    logInfo("before", "ms", ms);
    sleep(ms.msecs); // the fiber yields: another request runs on this thread meanwhile
    logInfo("after", "ms", ms);
    return "slept";
}

App build()
{
    auto app = new App;
    app.use(requestId());
    app.get!("/work/{ms}", work);
    return app;
}

string fetch(string path, string rid)
{
    foreach (attempt; 0 .. 100) // the server may still be starting
    {
        try
        {
            auto s = new TcpSocket(new InternetAddress("127.0.0.1", port));
            scope (exit) s.close();
            s.send("GET " ~ path ~ " HTTP/1.1\r\nHost: x\r\nX-Request-Id: " ~ rid ~ "\r\nConnection: close\r\n\r\n");
            char[] all;
            char[1024] buf;
            for (;;)
            {
                import core.stdc.errno : errno, EINTR;

                auto n = s.receive(buf[]);
                if (n < 0 && errno == EINTR) // the server's GC stops every thread with signals
                    continue;
                if (n <= 0)
                    break;
                all ~= buf[0 .. n];
            }
            return all.idup;
        }
        catch (Exception)
            Thread.sleep(20.msecs);
    }
    assert(0, "server did not answer");
}

void main()
{
    configureLog(LogLevel.info, LogFormat.json);
    int[2] p;
    pipe(p);
    fcntl(p[0], F_SETFL, O_NONBLOCK);
    immutable saved = dup(2);
    dup2(p[1], 2);

    ServerConfig cfg;
    cfg.port = port;
    cfg.workers = 1; // both requests on the same thread
    auto server = new Thread({ tryServe(&build, cfg); });
    server.start();

    string slow, fast;
    auto t1 = new Thread({ slow = fetch("/work/300", "slow-req"); });
    t1.start();
    Thread.sleep(100.msecs); // the slow one is asleep in its fiber
    auto t2 = new Thread({ fast = fetch("/work/20", "fast-req"); });
    t2.start();
    t1.join();
    t2.join();
    kill(getpid(), SIGTERM);
    server.join();

    dup2(saved, 2);
    close(saved);
    close(p[1]);
    char[] all;
    char[4096] buf;
    for (;;)
    {
        auto n = read(p[0], buf.ptr, buf.length);
        if (n <= 0)
            break;
        all ~= buf[0 .. n];
    }
    close(p[0]);

    assert(slow.indexOf("200 OK") > 0 && fast.indexOf("200 OK") > 0, slow ~ fast);
    string[] order;
    foreach (line; (cast(string) all).splitLines)
    {
        if (line.length == 0 || line[0] != '{')
            continue; // the server's own startup lines
        auto j = parseJSON(line);
        if ("request_id" !in j.object)
            continue;
        auto ms = j["ms"].integer;
        auto rid = j["request_id"].str;
        assert((ms == 300 && rid == "slow-req") || (ms == 20 && rid == "fast-req"), "wrong request id: " ~ line);
        order ~= j["msg"].str ~ ":" ~ rid;
    }
    // the fibers really interleaved: the fast request started and finished while the slow one slept
    assert(order == ["before:slow-req", "before:fast-req", "after:fast-req", "after:slow-req"], order.to!string);
    printf("ok  andaime.log: interleaved request fibers on one worker each log their own request id\n");
    fflush(stdout);
}
