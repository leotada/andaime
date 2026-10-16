/// OpenSSL loaded at run time (dlopen), used in non-blocking mode by the HTTP client and by the
/// server's TLS listener (`vela.engine.tlsserver`). No headers and no `-lssl` at build time: only
/// whoever does HTTPS needs libssl.so.3 installed (`libssl3` / `openssl`).
module vela.engine.tls;

@safe:

import vela.http.optional : Optional;
import vela.engine.os : dlOpen, dlSym, dlError;

package:

struct SSL_CTX;
struct SSL;
struct SSL_METHOD;

enum : int
{
    SSL_ERROR_SSL = 1,
    SSL_ERROR_WANT_READ = 2,
    SSL_ERROR_WANT_WRITE = 3,
    SSL_ERROR_SYSCALL = 5,
    SSL_ERROR_ZERO_RETURN = 6,
    SSL_VERIFY_NONE = 0,
    SSL_VERIFY_PEER = 1,
    SSL_CTRL_SET_TLSEXT_HOSTNAME = 55,
    SSL_CTRL_SET_MIN_PROTO_VERSION = 123,
    TLS1_2_VERSION = 0x0303,
    TLSEXT_NAMETYPE_host_name = 0,
    // server side (values from OpenSSL 3's ssl.h / tls1.h)
    SSL_FILETYPE_PEM = 1,
    SSL_CTRL_MODE = 33,
    SSL_CTRL_SET_SESS_CACHE_MODE = 44,
    SSL_CTRL_SET_TLSEXT_TICKET_KEYS = 59,
    SSL_SESS_CACHE_OFF = 0,
    SSL_TLSEXT_ERR_OK = 0,
    SSL_TLSEXT_ERR_NOACK = 3,
}

enum : uint
{
    SSL_MODE_ENABLE_PARTIAL_WRITE = 0x1,
    SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER = 0x2,
    SSL_MODE_RELEASE_BUFFERS = 0x10,
}

enum : ulong
{
    SSL_OP_NO_COMPRESSION = 1UL << 17,
    SSL_OP_CIPHER_SERVER_PREFERENCE = 1UL << 22,
    SSL_OP_NO_RENEGOTIATION = 1UL << 30,
}

/// ALPN selection callback (SSL_CTX_alpn_select_cb_func).
alias AlpnSelect = extern (C) int function(SSL*, const(ubyte)** out_, ubyte* outLen, const(ubyte)* in_,
    uint inLen, void* arg) nothrow @nogc @system;

/// Function table in a struct: loose `extern (C)` variables would become global symbols
/// named like OpenSSL's functions and libssl itself would end up calling our pointers.
struct Api
{
    extern (C) nothrow @nogc:
    const(SSL_METHOD)* function() TLS_client_method;
    SSL_CTX* function(const(SSL_METHOD)*) SSL_CTX_new;
    void function(SSL_CTX*) SSL_CTX_free;
    void function(SSL_CTX*, int, void*) SSL_CTX_set_verify;
    int function(SSL_CTX*) SSL_CTX_set_default_verify_paths;
    int function(SSL_CTX*, const(char)*, const(char)*) SSL_CTX_load_verify_locations;
    long function(SSL_CTX*, int, long, void*) SSL_CTX_ctrl;
    SSL* function(SSL_CTX*) SSL_new;
    void function(SSL*) SSL_free;
    int function(SSL*, int) SSL_set_fd;
    long function(SSL*, int, long, void*) SSL_ctrl;
    int function(SSL*, const(char)*) SSL_set1_host;
    void function(SSL*) SSL_set_connect_state;
    int function(SSL*) SSL_connect;
    int function(SSL*, void*, int) SSL_read;
    int function(SSL*, const(void)*, int) SSL_write;
    int function(const(SSL)*, int) SSL_get_error;
    int function(SSL*) SSL_shutdown;
    long function(const(SSL)*) SSL_get_verify_result;
    ulong function() ERR_get_error;
    // server side
    const(SSL_METHOD)* function() TLS_server_method;
    int function(SSL_CTX*, const(char)*) SSL_CTX_use_certificate_chain_file;
    int function(SSL_CTX*, const(char)*, int) SSL_CTX_use_PrivateKey_file;
    int function(const(SSL_CTX)*) SSL_CTX_check_private_key;
    int function(SSL_CTX*, const(char)*) SSL_CTX_set_cipher_list;
    ulong function(SSL_CTX*, ulong) SSL_CTX_set_options;
    void function(SSL_CTX*, AlpnSelect, void*) SSL_CTX_set_alpn_select_cb;
    void function(const(SSL)*, const(ubyte)**, uint*) SSL_get0_alpn_selected;
    int function(SSL*, const(ubyte)*, uint) SSL_set_alpn_protos;
    void function(SSL*) SSL_set_accept_state;
    int function(SSL*) SSL_do_handshake;
    void function(ulong, char*, size_t) ERR_error_string_n;
    void function() ERR_clear_error;
}

__gshared Api tls;

private __gshared bool loaded;
private __gshared string loadError;
private __gshared Object gLock;

shared static this() @trusted
{
    gLock = new Object;
}

/// OpenSSL writes to sockets with write(2), not send(MSG_NOSIGNAL): a peer that resets the
/// connection would raise SIGPIPE and kill the whole server. Ignored, unless the application
/// installed a handler of its own.
private void ignoreSigpipe() @system nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.signal : sigaction, sigaction_t, sigemptyset, SIGPIPE, SIG_DFL, SIG_IGN;

        sigaction_t current;
        if (sigaction(SIGPIPE, null, &current) != 0 || current.sa_handler != SIG_DFL)
            return;
        sigaction_t ign;
        ign.sa_handler = SIG_IGN;
        sigemptyset(&ign.sa_mask);
        sigaction(SIGPIPE, &ign, null);
    }
}

/// The text of the last failed `dlopen` (null when there is none), for load error messages.
string dlDetail() @trusted nothrow
{
    return dlError();
}

/// Loads libssl/libcrypto. Returns null on success, or the error message.
string loadOpenSsl() @trusted
{
    synchronized (gLock)
    {
        ignoreSigpipe();
        return loadLocked();
    }
}

/// Why OpenSSL 3 cannot be used, or none when it loaded. Loads the library on the first call, prints nothing and
/// changes no signal handling: for a startup check (`if (!tlsAvailable) ...`) that must not have side effects.
public Optional!string tlsLoadError() @trusted
{
    synchronized (gLock)
    {
        auto err = loadLocked();
        return err is null ? Optional!string.none : Optional!string(err);
    }
}

/// True when OpenSSL 3 (libssl.so.3 and libcrypto.so.3) is installed and has every symbol vela uses. HTTPS calls
/// (the HTTP client) and `ServerConfig.tls` need it.
public bool tlsAvailable() => !tlsLoadError().has;

// Called with `gLock` held.
private string loadLocked() @trusted nothrow
{
    if (loaded)
        return null;
    if (loadError !is null)
        return loadError;

    version (linux)
    {
        static immutable string[] cryptoNames = ["libcrypto.so.3\0", "libcrypto.so\0"];
        static immutable string[] sslNames = ["libssl.so.3\0", "libssl.so\0"];
    }
    else version (OSX)
    {
        static immutable string[] cryptoNames = [
            "libcrypto.3.dylib\0",
            "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib\0",
            "/usr/local/opt/openssl@3/lib/libcrypto.3.dylib\0",
            "libcrypto.dylib\0"
        ];
        static immutable string[] sslNames = [
            "libssl.3.dylib\0",
            "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib\0",
            "/usr/local/opt/openssl@3/lib/libssl.3.dylib\0",
            "libssl.dylib\0"
        ];
    }
    else version (Windows)
    {
        static immutable string[] cryptoNames = ["libcrypto-3-x64.dll\0", "libcrypto-3.dll\0", "libcrypto.dll\0"];
        static immutable string[] sslNames = ["libssl-3-x64.dll\0", "libssl-3.dll\0", "libssl.dll\0"];
    }
    else
    {
        static immutable string[] cryptoNames = ["libcrypto.so.3\0", "libcrypto.so\0"];
        static immutable string[] sslNames = ["libssl.so.3\0", "libssl.so\0"];
    }

    // libcrypto first and GLOBAL: libssl depends on it and ERR_* come from it
    void* crypto, ssl;
    string detail;
    foreach (n; cryptoNames)
        if ((crypto = dlOpen(n.ptr)) !is null)
            break;
        else if (detail is null)
            detail = dlDetail();
    foreach (n; sslNames)
        if ((ssl = dlOpen(n.ptr)) !is null)
            break;
        else if (detail is null)
            detail = dlDetail();
    if (ssl is null || crypto is null)
        return loadError = "vela.http: OpenSSL 3 not found (install libssl3 / openssl)"
            ~ (detail is null ? "" : ": " ~ detail);

    static foreach (m; __traits(allMembers, Api))
    {
        {
            auto zname = (m ~ "\0").ptr;
            auto p = dlSym(ssl, zname);
            if (p is null)
                p = dlSym(crypto, zname);
            if (p is null)
                return loadError = "vela.http: missing symbol in OpenSSL: " ~ m;
            __traits(getMember, tls, m) = cast(typeof(__traits(getMember, tls, m))) p;
        }
    }
    loaded = true;
    return null;
}
