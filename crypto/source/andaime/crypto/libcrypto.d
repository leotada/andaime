module andaime.crypto.libcrypto;

@system:

import andaime.engine.os : dlOpen, dlSym;

package struct EVP_MD;
package struct EVP_CIPHER;
package struct EVP_CIPHER_CTX;
package struct EVP_PKEY;
package struct EVP_PKEY_CTX;
package struct EVP_MD_CTX;
package struct BIGNUM;
package struct EC_GROUP;
package struct EC_POINT;
package struct ECDSA_SIG;
package struct OSSL_PARAM;
package struct OSSL_PARAM_BLD;

package enum int EVP_CTRL_GCM_SET_IVLEN = 0x9;
package enum int EVP_CTRL_GCM_GET_TAG = 0x10;
package enum int EVP_CTRL_GCM_SET_TAG = 0x11;
package enum int EVP_PKEY_PUBLIC_KEY = 0x86; // OSSL_KEYMGMT_SELECT_ALL_PARAMETERS | PUBLIC_KEY
package enum int EVP_PKEY_KEYPAIR = 0x87;    // ... | PRIVATE_KEY
package enum int NID_X9_62_prime256v1 = 415;
package enum int POINT_CONVERSION_UNCOMPRESSED = 4;

/// Function table in a struct held by a `__gshared` instance: loose `extern (C)` variables would become global symbols
/// named like libcrypto's own functions (see AGENTS.md, Pitfalls).
package struct CryptoApi
{
    extern (C) nothrow @nogc:
    // digests and MACs
    const(EVP_MD)* function() EVP_sha256;
    int function(const(void)*, size_t, ubyte*, uint*, const(EVP_MD)*, void*) EVP_Digest;
    ubyte* function(const(EVP_MD)*, const(void)*, int, const(ubyte)*, size_t, ubyte*, uint*) HMAC;
    // AES-GCM
    EVP_CIPHER_CTX* function() EVP_CIPHER_CTX_new;
    void function(EVP_CIPHER_CTX*) EVP_CIPHER_CTX_free;
    const(EVP_CIPHER)* function() EVP_aes_128_gcm;
    int function(EVP_CIPHER_CTX*, int, int, void*) EVP_CIPHER_CTX_ctrl;
    int function(EVP_CIPHER_CTX*, const(EVP_CIPHER)*, void*, const(ubyte)*, const(ubyte)*) EVP_EncryptInit_ex;
    int function(EVP_CIPHER_CTX*, ubyte*, int*, const(ubyte)*, int) EVP_EncryptUpdate;
    int function(EVP_CIPHER_CTX*, ubyte*, int*) EVP_EncryptFinal_ex;
    int function(EVP_CIPHER_CTX*, const(EVP_CIPHER)*, void*, const(ubyte)*, const(ubyte)*) EVP_DecryptInit_ex;
    int function(EVP_CIPHER_CTX*, ubyte*, int*, const(ubyte)*, int) EVP_DecryptUpdate;
    int function(EVP_CIPHER_CTX*, ubyte*, int*) EVP_DecryptFinal_ex;
    // keys
    EVP_PKEY_CTX* function(void*, const(char)*, const(char)*) EVP_PKEY_CTX_new_from_name;
    EVP_PKEY_CTX* function(void*, EVP_PKEY*, const(char)*) EVP_PKEY_CTX_new_from_pkey;
    void function(EVP_PKEY_CTX*) EVP_PKEY_CTX_free;
    int function(EVP_PKEY_CTX*) EVP_PKEY_keygen_init;
    int function(EVP_PKEY_CTX*, const(char)*) EVP_PKEY_CTX_set_group_name;
    int function(EVP_PKEY_CTX*, EVP_PKEY**) EVP_PKEY_generate;
    void function(EVP_PKEY*) EVP_PKEY_free;
    int function(EVP_PKEY_CTX*) EVP_PKEY_fromdata_init;
    int function(EVP_PKEY_CTX*, EVP_PKEY**, int, OSSL_PARAM*) EVP_PKEY_fromdata;
    int function(const(EVP_PKEY)*, const(char)*, BIGNUM**) EVP_PKEY_get_bn_param;
    int function(const(EVP_PKEY)*, const(char)*, ubyte*, size_t, size_t*) EVP_PKEY_get_octet_string_param;
    int function(EVP_PKEY_CTX*) EVP_PKEY_public_check;
    int function(EVP_PKEY_CTX*) EVP_PKEY_derive_init;
    int function(EVP_PKEY_CTX*, EVP_PKEY*) EVP_PKEY_derive_set_peer;
    int function(EVP_PKEY_CTX*, ubyte*, size_t*) EVP_PKEY_derive;
    OSSL_PARAM_BLD* function() OSSL_PARAM_BLD_new;
    void function(OSSL_PARAM_BLD*) OSSL_PARAM_BLD_free;
    int function(OSSL_PARAM_BLD*, const(char)*, const(char)*, size_t) OSSL_PARAM_BLD_push_utf8_string;
    int function(OSSL_PARAM_BLD*, const(char)*, const(void)*, size_t) OSSL_PARAM_BLD_push_octet_string;
    int function(OSSL_PARAM_BLD*, const(char)*, const(BIGNUM)*) OSSL_PARAM_BLD_push_BN;
    OSSL_PARAM* function(OSSL_PARAM_BLD*) OSSL_PARAM_BLD_to_param;
    void function(OSSL_PARAM*) OSSL_PARAM_free;
    // big numbers and points (the public key of an imported private key)
    BIGNUM* function(const(ubyte)*, int, BIGNUM*) BN_bin2bn;
    int function(const(BIGNUM)*, ubyte*, int) BN_bn2binpad;
    void function(BIGNUM*) BN_free;
    void function(BIGNUM*) BN_clear_free;
    EC_GROUP* function(int) EC_GROUP_new_by_curve_name;
    void function(EC_GROUP*) EC_GROUP_free;
    EC_POINT* function(const(EC_GROUP)*) EC_POINT_new;
    void function(EC_POINT*) EC_POINT_free;
    int function(const(EC_GROUP)*, EC_POINT*, const(BIGNUM)*, const(EC_POINT)*, const(BIGNUM)*, void*) EC_POINT_mul;
    size_t function(const(EC_GROUP)*, const(EC_POINT)*, int, ubyte*, size_t, void*) EC_POINT_point2oct;
    // signatures
    EVP_MD_CTX* function() EVP_MD_CTX_new;
    void function(EVP_MD_CTX*) EVP_MD_CTX_free;
    int function(EVP_MD_CTX*, EVP_PKEY_CTX**, const(EVP_MD)*, void*, EVP_PKEY*) EVP_DigestSignInit;
    int function(EVP_MD_CTX*, ubyte*, size_t*, const(ubyte)*, size_t) EVP_DigestSign;
    int function(EVP_MD_CTX*, EVP_PKEY_CTX**, const(EVP_MD)*, void*, EVP_PKEY*) EVP_DigestVerifyInit;
    int function(EVP_MD_CTX*, const(ubyte)*, size_t, const(ubyte)*, size_t) EVP_DigestVerify;
    ECDSA_SIG* function(ECDSA_SIG**, const(ubyte)**, long) d2i_ECDSA_SIG;
    int function(const(ECDSA_SIG)*, ubyte**) i2d_ECDSA_SIG;
    ECDSA_SIG* function() ECDSA_SIG_new;
    void function(ECDSA_SIG*) ECDSA_SIG_free;
    void function(const(ECDSA_SIG)*, const(BIGNUM)**, const(BIGNUM)**) ECDSA_SIG_get0;
    int function(ECDSA_SIG*, BIGNUM*, BIGNUM*) ECDSA_SIG_set0;
    // errors and wiping
    void function() ERR_clear_error;
    void function(void*, size_t) OPENSSL_cleanse;
}

package __gshared CryptoApi lc;

private __gshared bool loaded;
private __gshared string loadError;
private __gshared Object gLock;

shared static this() @trusted
{
    gLock = new Object;
}

/// Loads libcrypto (OpenSSL 3). Returns null on success, or the error message. Thread-safe; loads once.
package string loadLibcrypto() @trusted
{
    // @trusted: dlopen/dlsym with NUL-terminated literals; each pointer is cast to its declared prototype
    synchronized (gLock)
    {
        if (loaded)
            return null;
        if (loadError !is null)
            return loadError;

        version (linux)
            immutable string[] names = ["libcrypto.so.3\0", "libcrypto.so\0"];
        else version (OSX)
            immutable string[] names = [
                "libcrypto.3.dylib\0",
                "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib\0",
                "/usr/local/opt/openssl@3/lib/libcrypto.3.dylib\0",
                "libcrypto.dylib\0"
            ];
        else version (Windows)
            immutable string[] names = [
                "libcrypto-3-x64.dll\0",
                "libcrypto-3.dll\0",
                "libcrypto.dll\0"
            ];

        void* h;
        foreach (n; names)
        {
            h = dlOpen(n.ptr);
            // a libcrypto without the OpenSSL 3 key API (LibreSSL, OpenSSL 1.1) is not usable
            if (h !is null && dlSym(h, "EVP_PKEY_fromdata\0".ptr) !is null)
                break;
            h = null;
        }
        if (h is null)
            return loadError = "andaime.crypto: OpenSSL 3 (libcrypto) not found; install libssl3 / openssl";
        static foreach (m; __traits(allMembers, CryptoApi))
        {{
            auto p = dlSym(h, (m ~ "\0").ptr);
            if (p is null)
                return loadError = "andaime.crypto: missing symbol in libcrypto: " ~ m;
            __traits(getMember, lc, m) = cast(typeof(__traits(getMember, lc, m))) p;
        }}
        loaded = true;
        return null;
    }
}
