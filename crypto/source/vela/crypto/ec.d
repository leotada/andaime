/// ECDSA and ECDH on P-256 (prime256v1, secp256r1): keys, JWS ES256 signatures (raw `r||s`), and the ECDH shared
/// secret of Web Push (RFC 8291).
module vela.crypto.ec;

@safe:

import vela.crypto.common;
import vela.crypto.libcrypto;

/// A P-256 key: a key pair (generated or imported from its 32-byte private scalar), or only a public key (imported from
/// its 65-byte uncompressed point, which is checked to be on the curve). The OpenSSL key it wraps never leaves it.
final class EcKeyP256
{
    private EVP_PKEY* pkey;
    private bool priv;

    private this(EVP_PKEY* p, bool hasPrivate) @system
    {
        pkey = p;
        priv = hasPrivate;
    }

    ~this() @trusted
    {
        // @trusted: pkey is owned by this object alone and freed once
        if (pkey !is null)
            lc.EVP_PKEY_free(pkey);
        pkey = null;
    }

    /// A new random key pair.
    static EcKeyP256 generate()
    {
        needLibcrypto();
        auto p = generateP256();
        need(p !is null, "P-256 key generation failed");
        return (() @trusted => new EcKeyP256(p, true))();
    }

    /// The key pair whose private scalar is `d` (32 bytes, big-endian, 1 <= d < n).
    static EcKeyP256 fromPrivateKey(scope const(ubyte)[] d)
    {
        need(d.length == 32, "a P-256 private key is 32 bytes");
        need(scalarInRange(d), "the P-256 private key is out of range");
        needLibcrypto();
        ubyte[65] pub;
        need(publicFromPrivate(d, pub), "deriving the P-256 public key failed");
        auto p = importKey(d, pub[]);
        need(p !is null, "importing the P-256 private key failed");
        return (() @trusted => new EcKeyP256(p, true))();
    }

    /// A public key from its uncompressed point (65 bytes: 0x04, X, Y), checked to be on the curve.
    static EcKeyP256 fromPublicKey(scope const(ubyte)[] point)
    {
        need(point.length == 65 && point[0] == 4, "a P-256 public key is a 65-byte uncompressed point (0x04 || X || Y)");
        needLibcrypto();
        auto p = importKey(null, point);
        need(p !is null, "the P-256 public key is not a point on the curve");
        return (() @trusted => new EcKeyP256(p, false))();
    }

    /// Whether this key has its private part.
    bool hasPrivateKey() const nothrow @nogc => priv;

    /// The private scalar (32 bytes, big-endian). Throws `CryptoError` for a public-only key.
    ubyte[32] privateKey() const
    {
        need(priv, "this P-256 key has no private part");
        ubyte[32] o;
        need(exportPrivate(pkey, o), "exporting the P-256 private key failed");
        return o;
    }

    /// The public key as an uncompressed point (65 bytes: 0x04, X, Y): the form Web Push and JWK `x`/`y` use.
    ubyte[65] publicKey() const
    {
        ubyte[65] o;
        need(exportPublic(pkey, o), "exporting the P-256 public key failed");
        return o;
    }
}

/// Signs `data` with ES256 (ECDSA P-256 over SHA-256) and returns the raw 64-byte `r||s` that JWS uses (not DER).
ubyte[64] es256Sign(EcKeyP256 key, scope const(ubyte)[] data)
{
    need(key !is null && key.priv, "ES256 signing needs a P-256 key with its private part");
    ubyte[64] sig;
    need(signRaw(key.pkey, data, sig), "ES256 signing failed");
    return sig;
}

/// ditto, for text (a JWS signing input: `base64url(header) ~ "." ~ base64url(payload)`).
ubyte[64] es256Sign(EcKeyP256 key, scope const(char)[] data) => es256Sign(key, cast(const(ubyte)[]) data);

/// Verifies a raw 64-byte `r||s` ES256 signature of `data`. False when it does not match (or is not 64 bytes).
bool es256Verify(EcKeyP256 key, scope const(ubyte)[] data, scope const(ubyte)[] signature)
{
    need(key !is null, "ES256 verification needs a key");
    if (signature.length != 64)
        return false;
    return verifyRaw(key.pkey, data, signature);
}

/// ditto, for text.
bool es256Verify(EcKeyP256 key, scope const(char)[] data, scope const(ubyte)[] signature)
    => es256Verify(key, cast(const(ubyte)[]) data, signature);

/// The ECDH shared secret (the X coordinate, 32 bytes) of our key pair and the peer's public key.
ubyte[32] ecdhP256(EcKeyP256 ours, EcKeyP256 peer)
{
    need(ours !is null && ours.priv, "ECDH needs our P-256 key with its private part");
    need(peer !is null, "ECDH needs the peer's public key");
    ubyte[32] o;
    need(derive(ours.pkey, peer.pkey, o), "P-256 ECDH failed");
    return o;
}

/// ditto, with the peer's public key as an uncompressed point (65 bytes).
ubyte[32] ecdhP256(EcKeyP256 ours, scope const(ubyte)[] peerPoint) => ecdhP256(ours, EcKeyP256.fromPublicKey(peerPoint));

// ------------------------------------------------------------ OpenSSL calls (raw pointers stay below this line)

/// The order n of P-256, big-endian.
private static immutable ubyte[32] order = [
    0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51];

private bool scalarInRange(scope const(ubyte)[] d) pure nothrow @nogc
{
    bool nonZero;
    foreach (b; d)
        nonZero |= b != 0;
    if (!nonZero)
        return false;
    foreach (i; 0 .. 32)
        if (d[i] != order[i])
            return d[i] < order[i];
    return false; // d == n
}

// @trusted: the context and the generated key are checked for null; the context is freed; the key goes to the caller
private EVP_PKEY* generateP256() @trusted
{
    auto ctx = lc.EVP_PKEY_CTX_new_from_name(null, "EC", null);
    if (ctx is null)
        return null;
    scope (exit)
        lc.EVP_PKEY_CTX_free(ctx);
    EVP_PKEY* p;
    if (lc.EVP_PKEY_keygen_init(ctx) != 1 || lc.EVP_PKEY_CTX_set_group_name(ctx, "prime256v1") != 1
        || lc.EVP_PKEY_generate(ctx, &p) != 1)
        return null;
    return p;
}

// @trusted: d is 32 bytes (checked by the caller) and out is 65 bytes, the size of an uncompressed P-256 point;
// every object created here is freed here (the scalar with BN_clear_free)
private bool publicFromPrivate(scope const(ubyte)[] d, ref ubyte[65] o) @trusted
{
    auto g = lc.EC_GROUP_new_by_curve_name(NID_X9_62_prime256v1);
    if (g is null)
        return false;
    scope (exit)
        lc.EC_GROUP_free(g);
    auto bn = lc.BN_bin2bn(d.ptr, 32, null);
    if (bn is null)
        return false;
    scope (exit)
        lc.BN_clear_free(bn);
    auto pt = lc.EC_POINT_new(g);
    if (pt is null)
        return false;
    scope (exit)
        lc.EC_POINT_free(pt);
    if (lc.EC_POINT_mul(g, pt, bn, null, null, null) != 1)
        return false;
    return lc.EC_POINT_point2oct(g, pt, POINT_CONVERSION_UNCOMPRESSED, o.ptr, o.length, null) == 65;
}

/// A key from its parts: the private scalar (null for a public-only key) and the uncompressed public point.
// @trusted: the parameter builder copies the bytes it is given (with their lengths); builder, params, scalar and
// context are freed here; the key goes to the caller
private EVP_PKEY* importKey(scope const(ubyte)[] d, scope const(ubyte)[] pub) @trusted
{
    auto bld = lc.OSSL_PARAM_BLD_new();
    if (bld is null)
        return null;
    scope (exit)
        lc.OSSL_PARAM_BLD_free(bld);
    BIGNUM* bn;
    scope (exit)
        if (bn !is null)
            lc.BN_clear_free(bn);
    if (lc.OSSL_PARAM_BLD_push_utf8_string(bld, "group", "prime256v1", 0) != 1
        || lc.OSSL_PARAM_BLD_push_octet_string(bld, "pub", pub.ptr, pub.length) != 1)
        return null;
    if (d.length)
    {
        bn = lc.BN_bin2bn(d.ptr, cast(int) d.length, null);
        if (bn is null || lc.OSSL_PARAM_BLD_push_BN(bld, "priv", bn) != 1)
            return null;
    }
    auto params = lc.OSSL_PARAM_BLD_to_param(bld);
    if (params is null)
        return null;
    scope (exit)
        lc.OSSL_PARAM_free(params);
    auto ctx = lc.EVP_PKEY_CTX_new_from_name(null, "EC", null);
    if (ctx is null)
        return null;
    scope (exit)
        lc.EVP_PKEY_CTX_free(ctx);
    EVP_PKEY* p;
    if (lc.EVP_PKEY_fromdata_init(ctx) != 1
        || lc.EVP_PKEY_fromdata(ctx, &p, d.length ? EVP_PKEY_KEYPAIR : EVP_PKEY_PUBLIC_KEY, params) != 1)
    {
        lc.ERR_clear_error();
        return null;
    }
    // the point must be on the curve (an invalid-curve point would leak our private key through ECDH)
    auto check = lc.EVP_PKEY_CTX_new_from_pkey(null, p, null);
    immutable ok = check !is null && lc.EVP_PKEY_public_check(check) == 1;
    if (check !is null)
        lc.EVP_PKEY_CTX_free(check);
    if (!ok)
    {
        lc.ERR_clear_error();
        lc.EVP_PKEY_free(p);
        return null;
    }
    return p;
}

// @trusted: pkey is a live key owned by the calling EcKeyP256; the scalar is written with BN_bn2binpad into the 32
// bytes of o and freed with BN_clear_free
private bool exportPrivate(const(EVP_PKEY)* pkey, ref ubyte[32] o) @trusted
{
    BIGNUM* bn;
    if (lc.EVP_PKEY_get_bn_param(pkey, "priv", &bn) != 1)
        return false;
    scope (exit)
        lc.BN_clear_free(bn);
    return lc.BN_bn2binpad(bn, o.ptr, 32) == 32;
}

// @trusted: OpenSSL writes at most o.length (65) bytes into o and the length into n
private bool exportPublic(const(EVP_PKEY)* pkey, ref ubyte[65] o) @trusted
{
    size_t n;
    return lc.EVP_PKEY_get_octet_string_param(pkey, "pub", o.ptr, o.length, &n) == 1 && n == 65 && o[0] == 4;
}

// @trusted: the DER signature fits 72 bytes (two 33-byte integers and headers); d2i reads at most n bytes of it; r and s
// are owned by sig (get0) and written with BN_bn2binpad into the two halves of the 64-byte out; all objects freed here
private bool signRaw(EVP_PKEY* pkey, scope const(ubyte)[] data, ref ubyte[64] o) @trusted
{
    auto md = lc.EVP_MD_CTX_new();
    if (md is null)
        return false;
    scope (exit)
        lc.EVP_MD_CTX_free(md);
    ubyte[80] der;
    size_t n = der.length;
    if (lc.EVP_DigestSignInit(md, null, lc.EVP_sha256(), null, pkey) != 1
        || lc.EVP_DigestSign(md, der.ptr, &n, data.ptr, data.length) != 1)
        return false;
    const(ubyte)* p = der.ptr;
    auto sig = lc.d2i_ECDSA_SIG(null, &p, cast(long) n);
    if (sig is null)
        return false;
    scope (exit)
        lc.ECDSA_SIG_free(sig);
    const(BIGNUM)* r, s;
    lc.ECDSA_SIG_get0(sig, &r, &s);
    return lc.BN_bn2binpad(r, o.ptr, 32) == 32 && lc.BN_bn2binpad(s, o.ptr + 32, 32) == 32;
}

// @trusted: r and s are read from the two 32-byte halves of the 64-byte signature; ECDSA_SIG_set0 takes ownership of
// both numbers (freed with sig); i2d writes at most 72 bytes into der (asked for the length first); all freed here
private bool verifyRaw(EVP_PKEY* pkey, scope const(ubyte)[] data, scope const(ubyte)[] signature) @trusted
{
    auto sig = lc.ECDSA_SIG_new();
    if (sig is null)
        return false;
    scope (exit)
        lc.ECDSA_SIG_free(sig);
    auto r = lc.BN_bin2bn(signature.ptr, 32, null);
    auto s = lc.BN_bin2bn(signature.ptr + 32, 32, null);
    if (r is null || s is null || lc.ECDSA_SIG_set0(sig, r, s) != 1)
    {
        if (r !is null) lc.BN_free(r);
        if (s !is null) lc.BN_free(s);
        return false;
    }
    ubyte[80] der;
    immutable len = lc.i2d_ECDSA_SIG(sig, null);
    if (len <= 0 || len > der.length)
        return false;
    ubyte* dp = der.ptr;
    lc.i2d_ECDSA_SIG(sig, &dp);
    auto md = lc.EVP_MD_CTX_new();
    if (md is null)
        return false;
    scope (exit)
        lc.EVP_MD_CTX_free(md);
    immutable ok = lc.EVP_DigestVerifyInit(md, null, lc.EVP_sha256(), null, pkey) == 1
        && lc.EVP_DigestVerify(md, der.ptr, len, data.ptr, data.length) == 1;
    lc.ERR_clear_error();
    return ok;
}

// @trusted: both keys are live (owned by their EcKeyP256); out is 32 bytes and OpenSSL writes at most n = 32
private bool derive(EVP_PKEY* ours, EVP_PKEY* peer, ref ubyte[32] o) @trusted
{
    auto ctx = lc.EVP_PKEY_CTX_new_from_pkey(null, ours, null);
    if (ctx is null)
        return false;
    scope (exit)
        lc.EVP_PKEY_CTX_free(ctx);
    size_t n = o.length;
    immutable ok = lc.EVP_PKEY_derive_init(ctx) == 1 && lc.EVP_PKEY_derive_set_peer(ctx, peer) == 1
        && lc.EVP_PKEY_derive(ctx, o.ptr, &n) == 1 && n == 32;
    if (!ok)
        lc.ERR_clear_error();
    return ok;
}
