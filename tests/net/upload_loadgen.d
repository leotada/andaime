/// Upload load for the memory test (tools/check.sh): N connections POST a body of K KiB at the same time to /len and
/// check the answer. Bodies above 64 KiB use the buffer pool's exact-size path. Exit code 1 if any upload fails.
/// Usage: upload_loadgen <port> <connections> <KiB> [path]   (path /spooled sends a multipart form, others a raw body)
module upload_loadgen 2025;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread : Thread;
import core.time;
import core.stdc.stdio : printf;
import core.stdc.errno : errno, EINTR;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.unistd : close, read;

shared bool go;
shared int failures, finished;

ptrdiff_t sendAll(int fd, const(ubyte)[] b)
{
    size_t done;
    while (done < b.length)
    {
        auto n = send(fd, b.ptr + done, b.length - done, 0x4000);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return -1;
        done += n;
    }
    return done;
}

__gshared string path = "/len"; // set in main before the threads start

void upload(ushort port, size_t bytes)
{
    scope (exit)
        atomicOp!"+="(finished, 1);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    if (connect(fd, cast(sockaddr*)&a, a.sizeof) != 0)
    {
        atomicOp!"+="(failures, 1);
        return;
    }
    while (!atomicLoad(go))
        Thread.sleep(1.msecs);
    // /spooled takes a multipart form with one file part of `bytes` bytes; the other routes take the raw body
    immutable form = path == "/spooled";
    enum string partHead = "--b0und\r\nContent-Disposition: form-data; name=\"file\"; filename=\"x.bin\"\r\n\r\n";
    enum string partTail = "\r\n--b0und--\r\n";
    auto body_ = new ubyte[bytes + (form ? partHead.length + partTail.length : 0)];
    body_[] = 'x';
    if (form)
    {
        body_[0 .. partHead.length] = cast(const(ubyte)[]) partHead;
        body_[$ - partTail.length .. $] = cast(const(ubyte)[]) partTail;
    }
    char[256] h;
    import core.stdc.stdio : snprintf;
    auto hn = snprintf(h.ptr, h.length, "POST %.*s HTTP/1.1\r\nHost: t\r\nConnection: close\r\nContent-Length: %zu\r\n%s\r\n",
        cast(int) path.length, path.ptr, body_.length,
        form ? "Content-Type: multipart/form-data; boundary=b0und\r\n".ptr : "".ptr);
    if (sendAll(fd, cast(const(ubyte)[]) h[0 .. hn]) < 0 || sendAll(fd, body_) < 0)
    {
        atomicOp!"+="(failures, 1);
        close(fd);
        return;
    }
    char[512] buf;
    char[] all;
    for (;;)
    {
        auto n = read(fd, buf.ptr, buf.length);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            break;
        all ~= buf[0 .. n];
    }
    close(fd);
    import std.algorithm : canFind;
    import std.conv : to;
    if (!(all.canFind("HTTP/1.1 200") && all.canFind(bytes.to!string)))
        atomicOp!"+="(failures, 1);
}

int main(string[] args)
{
    if (args.length < 4)
        return 2;
    import std.conv : to;

    immutable port = args[1].to!ushort;
    immutable n = args[2].to!int;
    immutable bytes = args[3].to!size_t * 1024;
    if (args.length > 4)
        path = args[4];
    Thread[] ts;
    foreach (i; 0 .. n)
    {
        auto t = new Thread({ upload(port, bytes); });
        t.start();
        ts ~= t;
    }
    Thread.sleep(500.msecs); // everyone is connected
    atomicStore(go, true);
    foreach (t; ts)
        t.join();
    printf("%d uploads of %d KiB, %d failures\n", n, cast(int) (bytes / 1024), atomicLoad(failures));
    return atomicLoad(failures) ? 1 : 0;
}
