/// TLS client over OpenSSL loaded at run time (dlopen), in
/// non-blocking mode. No headers and no `-lssl` at build time: only whoever does
/// HTTPS needs libssl.so.3 installed (`libssl3` / `openssl`).
module vela.engine.tls;

@safe:

version (linux):

import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW, RTLD_GLOBAL;

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
}

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

/// Loads libssl/libcrypto. Returns null on success, or the error message.
string loadOpenSsl() @trusted
{
    synchronized (gLock)
    {
        if (loaded)
            return null;
        if (loadError !is null)
            return loadError;

        // libcrypto first and GLOBAL: libssl depends on it and ERR_* come from it
        void* crypto, ssl;
        foreach (n; ["libcrypto.so.3\0", "libcrypto.so\0"])
            if ((crypto = dlopen(n.ptr, RTLD_NOW | RTLD_GLOBAL)) !is null)
                break;
        foreach (n; ["libssl.so.3\0", "libssl.so\0"])
            if ((ssl = dlopen(n.ptr, RTLD_NOW | RTLD_GLOBAL)) !is null)
                break;
        if (ssl is null || crypto is null)
            return loadError = "vela.http: OpenSSL 3 not found (install libssl3 / openssl)";

        static foreach (m; __traits(allMembers, Api))
        {
            {
                auto zname = (m ~ "\0").ptr;
                auto p = dlsym(ssl, zname);
                if (p is null)
                    p = dlsym(crypto, zname);
                if (p is null)
                    return loadError = "vela.http: missing symbol in OpenSSL: " ~ m;
                __traits(getMember, tls, m) = cast(typeof(__traits(getMember, tls, m))) p;
            }
        }
        loaded = true;
        return null;
    }
}
