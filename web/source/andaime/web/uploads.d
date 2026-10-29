/// Request bodies read as they arrive: `BodyStream` (the raw body) and `SpooledFile` (a file part of a `Form!T` that
/// goes to a temporary file once it is too large to keep in memory).
///
/// The engine buffers a body up to `ServerConfig.bufferBodyBytes` (256 KiB by default) and hands a larger one to the
/// handler unread. A route whose handler takes a `BodyStream`, or a `Form!T` with a `SpooledFile` field, reads it as it
/// arrives, so an upload costs a 64 KiB window and at most `SpoolConfig.memoryBytes` per file part instead of its size;
/// any other route gets the body read whole first, as before.
///
///     struct Upload { Optional!string folder; SpooledFile[] files; }
///     @Post("/files") void send(Form!Upload form) { foreach (f; form.files) f.moveTo(store.pathFor(f.filename)); }
///
///     @Put("/blobs/{id}") void put(string id, BodyStream body) { ubyte[64 << 10] buf; size_t n; while ((n = body.read(buf)) > 0) ... }
///
/// File I/O here is plain blocking `read`/`write` on the worker thread: to the page cache it costs microseconds per
/// 64 KiB, which is cheaper than a hop to another thread.
module andaime.web.uploads 2025;

@safe:

import andaime.http.types : BodySource;
import andaime.web.context : Context;
import andaime.web.params : HttpError;

/// The request body as a stream, for a handler that consumes it as it arrives (to a file, another service, a hash): a
/// handler parameter. The engine does not buffer it (above `ServerConfig.bufferBodyBytes`), so memory stays at the
/// caller's buffer whatever the size. A smaller body, or one over HTTP/2, is already in memory and is read from there
/// the same way. Not with `JsonBody` or `Form` in the same handler (there is one body).
///
/// A body the handler does not read to the end cannot be skipped: the connection closes after the response.
struct BodyStream
{
    package(andaime) Context ctx;

    /// Copies up to `into.length` bytes of the body into `into`; 0 = the end. Waits while the client sends.
    size_t read(scope ubyte[] into) => ctx.readBodyInto(into);

    /// Bytes not read yet (`Content-Length` minus what `read` returned), or `unknownLength` while a chunked body has not
    /// reached its last chunk.
    ulong unread() const => ctx.bodyUnread;

    /// The rest of the body in one buffer of its size: for a handler that decides, after looking at the request, that
    /// it wants it in memory after all.
    const(ubyte)[] readAll() => ctx.readBody();
}

/// Where `SpooledFile` keeps uploads (`App.spoolUploads`).
struct SpoolConfig
{
    /// A file part up to this size stays in memory; a larger one goes to a temporary file.
    size_t memoryBytes = 256 << 10;
    /// Directory of the temporary files; empty = `$TMPDIR`, else `/tmp`. Put it on the file system the uploads end up in
    /// and `SpooledFile.moveTo` is a rename instead of a copy.
    string directory;
}

/// One file part of a multipart body, for uploads of any size: a `Form!T` field (`SpooledFile`, `SpooledFile[]`,
/// `Optional!SpooledFile`). The content stays in memory up to `SpoolConfig.memoryBytes` and is written to a temporary
/// file past that; the file is removed when the request ends unless `moveTo` took it. A form with such a field makes
/// its route read the body as it arrives (see `BodyStream`). `@minLength`/`@maxLength` count bytes, as on `UploadedFile`.
struct SpooledFile
{
    string filename;    /// the client's name for it (not a path), or ""
    string contentType; /// as the part sent it, or ""
    ulong size;         /// bytes of content
    /// The content, when it is in memory; empty when it is on disk. A view into request memory, like `UploadedFile.bytes`.
    const(ubyte)[] memory;
    /// The temporary file that holds the content when it is not in memory; "" otherwise.
    string path;

    bool onDisk() const pure nothrow @nogc => path.length != 0;

    /// The whole content in one buffer (reads the file in when it is on disk: `size` bytes of memory).
    const(ubyte)[] bytes() const
    {
        if (!onDisk)
            return memory;
        auto r = open();
        auto all = new ubyte[cast(size_t) size];
        size_t got;
        while (got < all.length)
        {
            immutable n = r.read(all[got .. $]);
            if (n == 0)
                break;
            got += n;
        }
        return all[0 .. got];
    }

    /// A reader over the content, from the start: `while ((n = r.read(buf)) > 0)`.
    SpooledReader open() const
    {
        SpooledReader r;
        if (onDisk)
            r.fd = openForReading(path);
        else
            r.mem = memory;
        return r;
    }

    /// The content as a request body for the HTTP client, read from the start each time it is sent, in 64 KiB pieces:
    /// `httpClient().put(url, upload.bodySource())`. Use it within the request (the temporary file goes away after).
    BodySource bodySource() const
    {
        const self = this; // the delegate outlives `this`, which may be on the caller's stack
        return BodySource(size, (scope sink) {
            auto r = self.open();
            auto buf = new ubyte[64 << 10];
            size_t n;
            while ((n = r.read(buf)) > 0)
                sink(buf[0 .. n]);
        });
    }

    /// Puts the content in the file `dest` (replacing it): a rename when the temporary file is on the same file system,
    /// else a copy. The file is then the caller's. Throws on an I/O error.
    void moveTo(string dest) const
    {
        if (!onDisk)
            return writeWhole(dest, memory);
        if (renameFile(path, dest))
            return;
        copyFile(path, dest);
        removeFile(path);
    }
}

/// Reads a `SpooledFile` in pieces (`SpooledFile.open`). Closes its file when it goes out of scope.
struct SpooledReader
{
    private int fd = -1;
    private const(ubyte)[] mem;

    @disable this(this);

    ~this() { closeFd(fd); }

    /// Copies up to `into.length` bytes; 0 = the end.
    size_t read(scope ubyte[] into)
    {
        if (fd < 0)
        {
            immutable n = into.length < mem.length ? into.length : mem.length;
            into[0 .. n] = mem[0 .. n];
            mem = mem[n .. $];
            return n;
        }
        return readFd(fd, into);
    }
}

// ---- package: what Form!T needs while it spools a part

version (Posix)
    private enum bool canSpool = true;
else
    private enum bool canSpool = false; // no temporary files: every part stays in memory

/// A part being written: kept in memory up to the limit, then in a temporary file of `ctx`.
package(andaime) struct Spooler
{
    private SpoolConfig cfg;
    private ubyte[] mem;
    private int fd = -1;
    private string path;
    private ulong size;

    @disable this(this);

    this(ref const SpoolConfig cfg)
    {
        this.cfg = cfg;
    }

    ~this() { closeFd(fd); }

    void put(Context ctx, scope const(ubyte)[] data)
    {
        size += data.length;
        if (fd < 0 && (mem.length + data.length <= cfg.memoryBytes || !canSpool))
        {
            mem ~= data;
            return;
        }
        if (fd < 0)
        {
            path = makeTempFile(cfg.directory, fd);
            ctx.bodyState.spooledFiles ~= path; // removed when the request ends
            writeFd(fd, mem);
            mem = null;
        }
        writeFd(fd, data);
    }

    /// The finished part (the file is closed; it stays until the request ends).
    SpooledFile finish(string filename, string contentType)
    {
        closeFd(fd);
        fd = -1;
        return SpooledFile(filename, contentType, size, mem, path);
    }
}

/// Removes the temporary files of the request in `ctx` (the ones `moveTo` took are already gone).
package(andaime) void removeSpooled(Context ctx) nothrow
{
    auto st = ctx.bodyState;
    foreach (p; st.spooledFiles)
        removeFile(p);
    st.spooledFiles = null;
}

// ---- POSIX file calls: small @trusted bodies; every pointer handed to the C call comes from a slice of the right length

version (Posix)
{
    import core.stdc.errno : errno, EINTR, EXDEV;
    import core.sys.posix.fcntl : O_RDONLY, O_WRONLY, O_CREAT, O_TRUNC, F_SETFD, FD_CLOEXEC, fcntl,
        posixOpen = open;
    import core.sys.posix.stdlib : mkstemp;
    import core.sys.posix.unistd : posixRead = read, posixWrite = write, posixClose = close, unlink;
    import core.stdc.stdio : posixRename = rename;
    import core.stdc.stdlib : getenv;

    private char[] cString(scope const(char)[] s) pure nothrow
    {
        auto z = new char[s.length + 1];
        z[0 .. s.length] = s[];
        z[$ - 1] = '\0';
        return z;
    }

    private string tempDirectory(string configured) @trusted
    {
        if (configured.length)
            return configured;
        // sound: getenv returns a NUL-terminated string owned by the environment; it is copied before anything else runs
        auto p = getenv("TMPDIR");
        if (p is null || p[0] == '\0')
            return "/tmp";
        size_t n;
        while (p[n] != '\0')
            n++;
        return p[0 .. n].idup;
    }

    private string makeTempFile(string directory, out int fd) @trusted
    {
        auto dir = tempDirectory(directory);
        auto z = cString(dir ~ "/andaime-upload-XXXXXX");
        // sound: z is a writable, NUL-terminated buffer that mkstemp fills in place
        fd = mkstemp(z.ptr);
        if (fd < 0)
            throw new HttpError(500, "andaime: cannot create a temporary file in " ~ dir);
        fcntl(fd, F_SETFD, FD_CLOEXEC); // not inherited by a child process the application starts
        return z[0 .. $ - 1].idup;
    }

    private void writeFd(int fd, scope const(ubyte)[] data) @trusted
    {
        while (data.length)
        {
            // sound: writes at most data.length bytes from data.ptr
            immutable n = posixWrite(fd, data.ptr, data.length);
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0)
                throw new HttpError(500, "andaime: cannot write a temporary upload file");
            data = data[n .. $];
        }
    }

    private size_t readFd(int fd, scope ubyte[] into) @trusted
    {
        for (;;)
        {
            // sound: reads at most into.length bytes into into.ptr
            immutable n = posixRead(fd, into.ptr, into.length);
            if (n >= 0)
                return cast(size_t) n;
            if (errno != EINTR)
                throw new Exception("andaime: cannot read an uploaded file");
        }
    }

    /// `open` with the descriptor closed on exec (druntime has no O_CLOEXEC on every system); -1 on failure.
    private int openFile(string path, int flags) @trusted
    {
        auto z = cString(path);
        // sound: z is NUL-terminated
        immutable fd = posixOpen(z.ptr, flags, 384 /* 0600 */);
        if (fd >= 0)
            fcntl(fd, F_SETFD, FD_CLOEXEC);
        return fd;
    }

    private int openForReading(string path)
    {
        immutable fd = openFile(path, O_RDONLY);
        if (fd < 0)
            throw new Exception("andaime: cannot open the uploaded file " ~ path);
        return fd;
    }

    private void closeFd(int fd) nothrow @nogc @trusted
    {
        if (fd >= 0)
            posixClose(fd);
    }

    private void removeFile(string path) nothrow @trusted
    {
        auto z = cString(path);
        // sound: z is NUL-terminated; a file already moved away is simply not found
        unlink(z.ptr);
    }

    /// False when `from` and `to` are on different file systems (the caller copies instead).
    private bool renameFile(string from, string to) @trusted
    {
        auto a = cString(from), b = cString(to);
        // sound: both are NUL-terminated
        if (posixRename(a.ptr, b.ptr) == 0)
            return true;
        if (errno == EXDEV)
            return false;
        throw new Exception("andaime: cannot move the uploaded file to " ~ to);
    }

    private void writeWhole(string dest, scope const(ubyte)[] data)
    {
        immutable fd = openFile(dest, O_WRONLY | O_CREAT | O_TRUNC);
        if (fd < 0)
            throw new Exception("andaime: cannot create " ~ dest);
        scope (exit)
            closeFd(fd);
        writeFd(fd, data);
    }

    private void copyFile(string from, string dest)
    {
        immutable src = openForReading(from);
        scope (exit)
            closeFd(src);
        immutable fd = openFile(dest, O_WRONLY | O_CREAT | O_TRUNC);
        if (fd < 0)
            throw new Exception("andaime: cannot create " ~ dest);
        scope (exit)
            closeFd(fd);
        auto buf = new ubyte[64 << 10];
        size_t n;
        while ((n = readFd(src, buf)) > 0)
            writeFd(fd, buf[0 .. n]);
    }
}
else
{
    // Without POSIX files every part stays in memory (`Spooler` never reaches these).
    private string makeTempFile(string, out int fd) { fd = -1; throw new HttpError(500, "andaime: no temporary files here"); }
    private void writeFd(int, scope const(ubyte)[]) { }
    private size_t readFd(int, scope ubyte[]) => 0;
    private int openForReading(string) => -1;
    private void closeFd(int) nothrow @nogc { }
    private void removeFile(string) nothrow { }
    private bool renameFile(string, string) => false;
    private void writeWhole(string, scope const(ubyte)[]) { }
    private void copyFile(string, string) { }
}
