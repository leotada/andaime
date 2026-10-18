/// Internal OS abstraction for andaime.engine: dynamic loading, notification descriptors,
/// portable non-blocking socket operations, and CPU count.
module andaime.engine.os 2025;

@safe:

import core.stdc.errno;

// =============================================================================
// Dynamic library loading (dlopen on Posix, LoadLibraryA on Windows)
// =============================================================================

alias LibHandle = void*;

/// Loads a shared library by null-terminated name.
LibHandle dlOpen(const(char)* name) nothrow @nogc @system
{
    version (Posix)
    {
        import core.sys.posix.dlfcn : dlopen, RTLD_NOW, RTLD_GLOBAL;
        return dlopen(name, RTLD_NOW | RTLD_GLOBAL);
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : LoadLibraryA;
        return cast(LibHandle) LoadLibraryA(name);
    }
    else
    {
        return null;
    }
}

/// Looks up a symbol by null-terminated name in a loaded library.
void* dlSym(LibHandle lib, const(char)* sym) nothrow @nogc @system
{
    if (lib is null)
        return null;
    version (Posix)
    {
        import core.sys.posix.dlfcn : dlsym;
        return dlsym(lib, sym);
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : GetProcAddress;
        import core.sys.windows.windef : HMODULE;
        return cast(void*) GetProcAddress(cast(HMODULE) lib, sym);
    }
    else
    {
        return null;
    }
}

/// Returns the last dynamic loading error message, or null.
// @trusted: dlerror/snprintf writes to or returns a valid NUL-terminated buffer that is copied into GC memory.
string dlError() nothrow @trusted
{
    version (Posix)
    {
        import core.sys.posix.dlfcn : dlerror;
        import core.stdc.string : strlen;

        auto e = dlerror();
        return e is null ? null : e[0 .. strlen(e)].idup;
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : GetLastError;
        import core.stdc.stdio : snprintf;

        auto err = GetLastError();
        if (err == 0)
            return null;
        char[32] buf;
        auto n = snprintf(buf.ptr, buf.length, "Windows error %u", err);
        return buf[0 .. n > 0 ? n : 0].idup;
    }
    else
    {
        return null;
    }
}

// =============================================================================
// Cross-platform Wakeup / Notification Descriptor (NotifyFd)
// =============================================================================

/// A non-blocking wakeup descriptor. On Linux it wraps eventfd(2) directly;
/// on macOS it wraps a non-blocking pipe(2); on Windows it wraps a non-blocking
/// loopback TCP socket pair so readFd is a native socket polled by WSAPoll / awaitFd.
struct NotifyFd
{
    int readFd = -1;
    int writeFd = -1;

    // @trusted: eventfd/pipe/socket calls operate only on stack locals and integer descriptors.
    bool open() nothrow @nogc @trusted
    {
        version (linux)
        {
            import core.sys.linux.sys.eventfd : eventfd;
            readFd = eventfd(0, 0x800 /*EFD_NONBLOCK*/ | 0x80000 /*EFD_CLOEXEC*/);
            writeFd = readFd;
            return readFd >= 0;
        }
        else version (Posix)
        {
            import core.sys.posix.unistd : pipe, close;
            import core.sys.posix.fcntl : fcntl, F_SETFL, F_SETFD, O_NONBLOCK, FD_CLOEXEC;

            int[2] p;
            if (pipe(p) != 0)
                return false;
            fcntl(p[0], F_SETFL, O_NONBLOCK);
            fcntl(p[0], F_SETFD, FD_CLOEXEC);
            fcntl(p[1], F_SETFL, O_NONBLOCK);
            fcntl(p[1], F_SETFD, FD_CLOEXEC);
            readFd = p[0];
            writeFd = p[1];
            return true;
        }
        else version (Windows)
        {
            return openLoopbackPair();
        }
        else
        {
            return false;
        }
    }

    // @trusted: writes the 8-byte stack local `one` to the owned descriptor.
    void notify() nothrow @nogc @trusted
    {
        if (writeFd < 0)
            return;
        ulong one = 1;
        version (Posix)
        {
            import core.sys.posix.unistd : write;
            write(writeFd, &one, one.sizeof);
        }
        else version (Windows)
        {
            sockSend(writeFd, &one, one.sizeof);
        }
    }
    alias wake = notify;

    // @trusted: reads at most buf.length bytes into the stack buffer `buf`.
    void drain() nothrow @nogc @trusted
    {
        if (readFd < 0)
            return;
        ubyte[64] buf;
        version (Posix)
        {
            import core.sys.posix.unistd : read;
            read(readFd, buf.ptr, buf.length);
        }
        else version (Windows)
        {
            sockRead(readFd, buf.ptr, buf.length);
        }
    }

    // @trusted: closes owned file/socket descriptors and resets them to -1.
    void close() nothrow @nogc @trusted
    {
        if (readFd >= 0)
        {
            version (Posix)
            {
                import core.sys.posix.unistd : close;
                close(readFd);
                if (writeFd >= 0 && writeFd != readFd)
                    close(writeFd);
            }
            else version (Windows)
            {
                sockClose(readFd);
                if (writeFd >= 0 && writeFd != readFd)
                    sockClose(writeFd);
            }
            readFd = writeFd = -1;
        }
    }

    version (Windows)
    private bool openLoopbackPair() nothrow @nogc @trusted
    {
        import core.sys.windows.winsock2;

        initSockets();
        SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (listener == INVALID_SOCKET)
            return false;
        scope (exit) closesocket(listener);

        sockaddr_in addr;
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0; // ephemeral
        if (bind(listener, cast(sockaddr*)&addr, addr.sizeof) != 0)
            return false;
        if (listen(listener, 1) != 0)
            return false;
        socklen_t len = addr.sizeof;
        if (getsockname(listener, cast(sockaddr*)&addr, &len) != 0)
            return false;

        SOCKET w = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (w == INVALID_SOCKET)
            return false;

        if (connect(w, cast(sockaddr*)&addr, addr.sizeof) != 0)
        {
            closesocket(w);
            return false;
        }

        SOCKET r = accept(listener, null, null);
        if (r == INVALID_SOCKET)
        {
            closesocket(w);
            return false;
        }

        uint mode = 1;
        ioctlsocket(r, FIONBIO, &mode);
        ioctlsocket(w, FIONBIO, &mode);

        readFd = cast(int) r;
        writeFd = cast(int) w;
        return true;
    }
}

// =============================================================================
// Socket utilities
// =============================================================================

version (Windows)
{
    import core.sys.windows.winsock2;
    pragma(lib, "ws2_32");

    struct WSAPOLLFD
    {
        SOCKET fd;
        short events;
        short revents;
    }

    enum short POLLRDNORM = 0x0100;
    enum short POLLWRNORM = 0x0010;
    enum short POLLIN = POLLRDNORM;
    enum short POLLOUT = POLLWRNORM;
    enum short POLLERR = 0x0001;
    enum short POLLHUP = 0x0002;
    enum short POLLNVAL = 0x0004;

    extern (Windows) nothrow @nogc int WSAPoll(WSAPOLLFD* fds, uint nfds, int timeout);

    private __gshared bool wsaReady;

    // @trusted: WSAStartup writes only to stack local `wsa`; `wsaReady` is set once at module startup.
    package void initSockets() nothrow @nogc @trusted
    {
        if (!wsaReady)
        {
            WSADATA wsa;
            if (WSAStartup(0x0202, &wsa) == 0)
                wsaReady = true;
        }
    }

    shared static this() nothrow @nogc @trusted
    {
        initSockets();
    }
}
else
{
    package void initSockets() nothrow @nogc @safe {}
}

/// Opens a non-blocking stream socket with close-on-exec set.
// @trusted: creates a socket and configures non-blocking / close-on-exec flags using only integer descriptors and stack locals.
int sockOpenNonBlock(int family) nothrow @nogc @trusted
{
    initSockets();
    version (linux)
    {
        import core.sys.posix.sys.socket : socket, AF_INET, SOCK_STREAM;
        enum SOCK_NONBLOCK = 0x800, SOCK_CLOEXEC = 0x80000;
        return socket(family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    }
    else version (OSX)
    {
        import core.sys.posix.sys.socket : socket, setsockopt, SOL_SOCKET, SOCK_STREAM;
        import core.sys.posix.fcntl : fcntl, F_SETFL, F_SETFD, O_NONBLOCK, FD_CLOEXEC;
        enum SO_NOSIGPIPE = 0x1022;

        immutable fd = socket(family, SOCK_STREAM, 0);
        if (fd >= 0)
        {
            fcntl(fd, F_SETFL, O_NONBLOCK);
            fcntl(fd, F_SETFD, FD_CLOEXEC);
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, one.sizeof);
        }
        return fd;
    }
    else version (Posix)
    {
        import core.sys.posix.sys.socket : socket, SOCK_STREAM;
        import core.sys.posix.fcntl : fcntl, F_SETFL, F_SETFD, O_NONBLOCK, FD_CLOEXEC;

        immutable fd = socket(family, SOCK_STREAM, 0);
        if (fd >= 0)
        {
            fcntl(fd, F_SETFL, O_NONBLOCK);
            fcntl(fd, F_SETFD, FD_CLOEXEC);
        }
        return fd;
    }
    else version (Windows)
    {
        SOCKET s = socket(family, SOCK_STREAM, IPPROTO_TCP);
        if (s == INVALID_SOCKET)
            return -1;
        uint mode = 1;
        ioctlsocket(s, FIONBIO, &mode);
        return cast(int) s;
    }
    else
    {
        return -1;
    }
}

version (linux)
{
    import core.sys.posix.sys.socket : sockaddr, socklen_t;
    private extern (C) int accept4(int, sockaddr*, socklen_t*, int) nothrow @nogc;
}

/// Accepts a connection, returning a non-blocking close-on-exec descriptor.
int sockAcceptNonBlock(int listenFd, void* peer, uint* peerLen) nothrow @nogc @system
{
    version (linux)
    {
        enum SOCK_NONBLOCK = 0x800, SOCK_CLOEXEC = 0x80000;
        return accept4(listenFd, cast(sockaddr*) peer, cast(socklen_t*) peerLen, SOCK_NONBLOCK | SOCK_CLOEXEC);
    }
    else version (OSX)
    {
        import core.sys.posix.sys.socket : accept, setsockopt, sockaddr, socklen_t, SOL_SOCKET;
        import core.sys.posix.fcntl : fcntl, F_SETFL, F_SETFD, O_NONBLOCK, FD_CLOEXEC;
        enum SO_NOSIGPIPE = 0x1022;

        immutable fd = accept(listenFd, cast(sockaddr*) peer, cast(socklen_t*) peerLen);
        if (fd >= 0)
        {
            fcntl(fd, F_SETFL, O_NONBLOCK);
            fcntl(fd, F_SETFD, FD_CLOEXEC);
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, one.sizeof);
        }
        return fd;
    }
    else version (Posix)
    {
        import core.sys.posix.sys.socket : accept, sockaddr, socklen_t;
        import core.sys.posix.fcntl : fcntl, F_SETFL, F_SETFD, O_NONBLOCK, FD_CLOEXEC;

        immutable fd = accept(listenFd, cast(sockaddr*) peer, cast(socklen_t*) peerLen);
        if (fd >= 0)
        {
            fcntl(fd, F_SETFL, O_NONBLOCK);
            fcntl(fd, F_SETFD, FD_CLOEXEC);
        }
        return fd;
    }
    else version (Windows)
    {
        SOCKET s = accept(cast(SOCKET) listenFd, cast(sockaddr*) peer, cast(int*) peerLen);
        if (s == INVALID_SOCKET)
        {
            setErrnoFromWsa();
            return -1;
        }
        uint mode = 1;
        ioctlsocket(s, FIONBIO, &mode);
        return cast(int) s;
    }
    else
    {
        return -1;
    }
}

/// Reads from a socket descriptor.
ptrdiff_t sockRead(int fd, void* p, size_t n) nothrow @nogc @system
{
    version (Posix)
    {
        import core.sys.posix.unistd : read;
        return read(fd, p, n);
    }
    else version (Windows)
    {
        int r = recv(cast(SOCKET) fd, cast(char*) p, cast(int)(n > int.max ? int.max : n), 0);
        if (r < 0)
        {
            setErrnoFromWsa();
            return -1;
        }
        return r;
    }
    else
    {
        return -1;
    }
}

/// Sends data to a socket descriptor without raising SIGPIPE.
ptrdiff_t sockSend(int fd, const(void)* p, size_t n) nothrow @nogc @system
{
    version (linux)
    {
        import core.sys.posix.sys.socket : send;
        enum MSG_NOSIGNAL = 0x4000;
        return send(fd, p, n, MSG_NOSIGNAL);
    }
    else version (Posix)
    {
        import core.sys.posix.sys.socket : send;
        return send(fd, p, n, 0); // SO_NOSIGPIPE is set on the socket
    }
    else version (Windows)
    {
        int r = send(cast(SOCKET) fd, cast(const(char)*) p, cast(int)(n > int.max ? int.max : n), 0);
        if (r < 0)
        {
            setErrnoFromWsa();
            return -1;
        }
        return r;
    }
    else
    {
        return -1;
    }
}

/// Closes a socket descriptor.
// @trusted: closes an integer socket descriptor; negative descriptors are ignored.
void sockClose(int fd) nothrow @nogc @trusted
{
    if (fd < 0)
        return;
    version (Posix)
    {
        import core.sys.posix.unistd : close;
        close(fd);
    }
    else version (Windows)
    {
        closesocket(cast(SOCKET) fd);
    }
}

/// Shuts down the writing end of a socket.
// @trusted: calls shutdown on an integer socket descriptor.
int sockShutdownWr(int fd) nothrow @nogc @trusted
{
    version (Posix)
    {
        import core.sys.posix.sys.socket : shutdown, SHUT_WR;
        return shutdown(fd, SHUT_WR);
    }
    else version (Windows)
    {
        return shutdown(cast(SOCKET) fd, SD_SEND);
    }
    else
    {
        return -1;
    }
}

/// Sets TCP_NODELAY on a socket descriptor.
// @trusted: setsockopt reads only the stack local `one`.
void sockSetTcpNoDelay(int fd) nothrow @nogc @trusted
{
    int one = 1;
    version (Windows)
        setsockopt(cast(SOCKET) fd, IPPROTO_TCP, TCP_NODELAY, cast(const(char)*)&one, one.sizeof);
    else
    {
        import core.sys.posix.netinet.in_ : IPPROTO_TCP;
        import core.sys.posix.netinet.tcp : TCP_NODELAY;
        import core.sys.posix.sys.socket : setsockopt;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, one.sizeof);
    }
}

/// Retrieves and clears the socket error status (SO_ERROR).
// @trusted: getsockopt writes only into the stack local `err`.
int sockGetError(int fd) nothrow @nogc @trusted
{
    int err;
    version (Windows)
    {
        int len = err.sizeof;
        getsockopt(cast(SOCKET) fd, SOL_SOCKET, SO_ERROR, cast(char*)&err, &len);
    }
    else
    {
        import core.sys.posix.sys.socket : getsockopt, SOL_SOCKET, SO_ERROR, socklen_t;
        socklen_t len = err.sizeof;
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
    }
    return err;
}

/// Checks if an asynchronous connect call returned in progress / would block.
// @trusted: reads thread-local errno / WSAGetLastError without pointer operations.
bool sockConnectInProgress() nothrow @nogc @trusted
{
    version (Windows)
    {
        import core.sys.windows.winsock2 : WSAGetLastError, WSAEWOULDBLOCK, WSAEINPROGRESS;
        immutable err = WSAGetLastError();
        return err == WSAEWOULDBLOCK || err == WSAEINPROGRESS;
    }
    else
    {
        import core.stdc.errno : errno, EINPROGRESS, EWOULDBLOCK;
        return errno == EINPROGRESS || errno == EWOULDBLOCK;
    }
}

/// Connects a socket to an address.
int sockConnect(int fd, const(void)* addr, uint addrLen) nothrow @nogc @system
{
    version (Windows)
    {
        int r = connect(cast(SOCKET) fd, cast(const(sockaddr)*) addr, cast(int) addrLen);
        if (r < 0)
            setErrnoFromWsa();
        return r;
    }
    else
    {
        import core.sys.posix.sys.socket : connect, sockaddr, socklen_t;
        return connect(fd, cast(const(sockaddr)*) addr, cast(socklen_t) addrLen);
    }
}

version (Windows)
{
    // @trusted: translates thread-local Winsock error to thread-local C errno.
    private void setErrnoFromWsa() nothrow @nogc @trusted
    {
        import core.stdc.errno : errno;
        static import err = core.stdc.errno;

        auto e = WSAGetLastError();
        switch (e)
        {
            case WSAEWOULDBLOCK: errno = err.EAGAIN; break;
            case WSAEINPROGRESS: errno = err.EINPROGRESS; break;
            case WSAECONNRESET: errno = err.ECONNRESET; break;
            case WSAEINTR: errno = err.EINTR; break;
            case WSAENOTCONN: errno = err.ENOTCONN; break;
            case WSAEADDRINUSE: errno = err.EADDRINUSE; break;
            case WSAECONNABORTED: errno = err.ECONNABORTED; break;
            default: errno = err.EIO; break;
        }
    }
}

// =============================================================================
// CPU count
// =============================================================================

/// Number of available online processor cores.
// @trusted: sysconf/GetSystemInfo reads system configuration into a stack local.
uint cpuCount() nothrow @nogc @trusted
{
    version (Posix)
    {
        import core.sys.posix.unistd : sysconf, _SC_NPROCESSORS_ONLN;
        immutable cpus = sysconf(_SC_NPROCESSORS_ONLN);
        return cpus > 0 ? cast(uint) cpus : 1;
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : GetSystemInfo, SYSTEM_INFO;
        SYSTEM_INFO si;
        GetSystemInfo(&si);
        return si.dwNumberOfProcessors > 0 ? cast(uint) si.dwNumberOfProcessors : 1;
    }
    else
    {
        return 1;
    }
}

unittest
{
    assert(cpuCount() >= 1);

    NotifyFd nfd;
    assert(nfd.open());
    assert(nfd.readFd >= 0 && nfd.writeFd >= 0);
    nfd.notify();
    nfd.drain();
    nfd.close();
    assert(nfd.readFd == -1 && nfd.writeFd == -1);
}
