/// AES-128-GCM authenticated encryption (the `aes128gcm` content coding of RFC 8188, Web Push).
module andaime.crypto.aead 2025;

@safe:

import andaime.crypto.common;
import andaime.crypto.libcrypto;

/// Encrypts `plaintext` with a 16-byte `key` and a 12-byte `nonce` (never reuse a nonce with the same key). Returns the
/// ciphertext followed by the 16-byte authentication tag. `aad` is authenticated but not encrypted.
ubyte[] aes128GcmSeal(scope const(ubyte)[] key, scope const(ubyte)[] nonce, scope const(ubyte)[] plaintext,
    scope const(ubyte)[] aad = null)
{
    need(key.length == 16, "AES-128-GCM needs a 16-byte key");
    need(nonce.length == 12, "AES-128-GCM needs a 12-byte nonce");
    need(plaintext.length <= int.max && aad.length <= int.max, "AES-128-GCM input too large");
    needLibcrypto();
    auto o = new ubyte[plaintext.length + 16];
    immutable ok = gcmSeal(key, nonce, plaintext, aad, o);
    need(ok, "AES-128-GCM encryption failed");
    return o;
}

// @trusted: every length handed to OpenSSL is the length of the slice it goes with; `o` holds the ciphertext (the same
// length as the plaintext, GCM is a stream mode) plus the 16-byte tag; the context is freed on every path
private bool gcmSeal(scope const(ubyte)[] key, scope const(ubyte)[] nonce, scope const(ubyte)[] pt,
    scope const(ubyte)[] aad, ubyte[] o) @trusted
{
    auto ctx = lc.EVP_CIPHER_CTX_new();
    if (ctx is null)
        return false;
    scope (exit)
        lc.EVP_CIPHER_CTX_free(ctx);
    int n, fin;
    if (lc.EVP_EncryptInit_ex(ctx, lc.EVP_aes_128_gcm(), null, key.ptr, nonce.ptr) != 1)
        return false;
    if (aad.length && lc.EVP_EncryptUpdate(ctx, null, &n, aad.ptr, cast(int) aad.length) != 1)
        return false;
    n = 0;
    if (pt.length && lc.EVP_EncryptUpdate(ctx, o.ptr, &n, pt.ptr, cast(int) pt.length) != 1)
        return false;
    if (lc.EVP_EncryptFinal_ex(ctx, o.ptr + n, &fin) != 1 || n + fin != pt.length)
        return false;
    return lc.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, o.ptr + pt.length) == 1;
}

/// Decrypts and authenticates what `aes128GcmSeal` produced (ciphertext followed by the tag). False when the tag does
/// not match (wrong key, nonce or aad, or tampered data); `plaintext` is then empty.
bool aes128GcmOpen(scope const(ubyte)[] key, scope const(ubyte)[] nonce, scope const(ubyte)[] sealed,
    out ubyte[] plaintext, scope const(ubyte)[] aad = null)
{
    need(key.length == 16, "AES-128-GCM needs a 16-byte key");
    need(nonce.length == 12, "AES-128-GCM needs a 12-byte nonce");
    need(sealed.length <= int.max && aad.length <= int.max, "AES-128-GCM input too large");
    if (sealed.length < 16)
        return false;
    needLibcrypto();
    auto o = new ubyte[sealed.length - 16];
    if (!gcmOpen(key, nonce, sealed, aad, o))
        return false;
    plaintext = o;
    return true;
}

// @trusted: as gcmSeal; the tag is the last 16 bytes of `sealed`, OpenSSL copies it (SET_TAG) and does not write to it
private bool gcmOpen(scope const(ubyte)[] key, scope const(ubyte)[] nonce, scope const(ubyte)[] sealed,
    scope const(ubyte)[] aad, ubyte[] o) @trusted
{
    auto ctx = lc.EVP_CIPHER_CTX_new();
    if (ctx is null)
        return false;
    scope (exit)
        lc.EVP_CIPHER_CTX_free(ctx);
    immutable ctLen = sealed.length - 16;
    int n, fin;
    if (lc.EVP_DecryptInit_ex(ctx, lc.EVP_aes_128_gcm(), null, key.ptr, nonce.ptr) != 1)
        return false;
    if (aad.length && lc.EVP_DecryptUpdate(ctx, null, &n, aad.ptr, cast(int) aad.length) != 1)
        return false;
    n = 0;
    if (ctLen && lc.EVP_DecryptUpdate(ctx, o.ptr, &n, sealed.ptr, cast(int) ctLen) != 1)
        return false;
    if (lc.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, cast(void*)(sealed.ptr + ctLen)) != 1)
        return false;
    immutable ok = lc.EVP_DecryptFinal_ex(ctx, o.ptr + n, &fin) == 1;
    lc.ERR_clear_error(); // a failed tag check leaves an error on the thread's queue
    return ok;
}
