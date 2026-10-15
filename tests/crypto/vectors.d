/// Known-answer tests for `vela:crypto`: SHA-256 (FIPS 180-2 examples), HMAC-SHA256 (RFC 4231), HKDF (RFC 5869 cases
/// 1-3), AES-128-GCM (the GCM specification's test cases 2-4, used by NIST's validation), P-256 keys, ES256 signatures
/// checked against the `openssl` command in both directions (skipped when it is not installed), and ECDH.
/// Exits 77 (skip) when OpenSSL 3 cannot be loaded.
module crypto_vectors;

import vela.crypto;
import core.stdc.stdio : fprintf, printf, stderr;
import std.conv : hexString;
import std.string : representation;

ubyte[] hex(string s)
{
    ubyte[] r;
    string t;
    foreach (c; s)
        if (c != ' ')
            t ~= c;
    assert(t.length % 2 == 0, s);
    foreach (i; 0 .. t.length / 2)
    {
        ubyte v;
        foreach (c; t[2 * i .. 2 * i + 2])
            v = cast(ubyte)(v << 4 | (c <= '9' ? c - '0' : c - 'a' + 10));
        r ~= v;
    }
    return r;
}

ubyte[] rep(ubyte b, size_t n)
{
    auto r = new ubyte[n];
    r[] = b;
    return r;
}

void testSha256()
{
    assert(sha256("")[] == hex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
    assert(sha256("abc")[] == hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    assert(sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")[]
        == hex("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"));
}

void testHmac()
{
    // RFC 4231 test cases 1-7 (case 5 is truncated to 128 bits)
    assert(hmacSha256(rep(0x0b, 20), "Hi There".representation)[]
        == hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"));
    assert(hmacSha256("Jefe", "what do ya want for nothing?")[]
        == hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"));
    assert(hmacSha256(rep(0xaa, 20), rep(0xdd, 50))[]
        == hex("773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"));
    assert(hmacSha256(hex("0102030405060708090a0b0c0d0e0f10111213141516171819"), rep(0xcd, 50))[]
        == hex("82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"));
    assert(hmacSha256(rep(0x0c, 20), "Test With Truncation".representation)[0 .. 16]
        == hex("a3b6167473100ee06e0c796c2955552b"));
    assert(hmacSha256(rep(0xaa, 131), "Test Using Larger Than Block-Size Key - Hash Key First".representation)[]
        == hex("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"));
    assert(hmacSha256(rep(0xaa, 131), ("This is a test using a larger than block-size key and a larger than block-size "
        ~ "data. The key needs to be hashed before being used by the HMAC algorithm.").representation)[]
        == hex("9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"));
}

void testHkdf()
{
    // RFC 5869 A.1
    auto ikm = rep(0x0b, 22);
    auto salt = hex("000102030405060708090a0b0c");
    auto info = hex("f0f1f2f3f4f5f6f7f8f9");
    assert(hkdfExtract(salt, ikm)[] == hex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"));
    assert(hkdfSha256(salt, ikm, info, 42)
        == hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"));

    // A.2: longer inputs and outputs
    ubyte[] seq(ubyte from)
    {
        ubyte[] r;
        foreach (i; 0 .. 80)
            r ~= cast(ubyte)(from + i);
        return r;
    }
    assert(hkdfExtract(seq(0x60), seq(0x00))[] == hex("06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244"));
    assert(hkdfSha256(seq(0x60), seq(0x00), seq(0xb0), 82)
        == hex("b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09"
            ~ "da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87"));

    // A.3: empty salt and info
    assert(hkdfExtract(null, ikm)[] == hex("19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04"));
    assert(hkdfSha256(null, ikm, null, 42)
        == hex("8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"));

    bool threw;
    try
        hkdfSha256(salt, ikm, info, 255 * 32 + 1);
    catch (CryptoError)
        threw = true;
    assert(threw, "HKDF output is bounded");
}

void testGcm()
{
    // test case 2: zero key and nonce, one zero block; and the empty message (test case 1)
    auto z16 = new ubyte[16], z12 = new ubyte[12];
    assert(aes128GcmSeal(z16, z12, z16) == hex("0388dace60b6a392f328c2b971b2fe78ab6e47d42cec13bdf53a67b21257bddf"));
    assert(aes128GcmSeal(z16, z12, null) == hex("58e2fccefa7e3061367f1d57a4e7455a"));

    // test cases 3 and 4 (4: with additional data, 60-byte plaintext)
    auto key = hex("feffe9928665731c6d6a8f9467308308");
    auto nonce = hex("cafebabefacedbaddecaf888");
    auto pt = hex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255");
    auto ct = hex("42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985");
    assert(aes128GcmSeal(key, nonce, pt) == ct ~ hex("4d5c2af327cd64a62cf35abd2ba6fab4"));
    auto aad = hex("feedfacedeadbeeffeedfacedeadbeefabaddad2");
    auto sealed = aes128GcmSeal(key, nonce, pt[0 .. 60], aad);
    assert(sealed == ct[0 .. 60] ~ hex("5bc94fbc3221a5db94fae95ae7121a47"));

    // opening: the right inputs give the plaintext; any change fails the tag
    ubyte[] got;
    assert(aes128GcmOpen(key, nonce, sealed, got, aad) && got == pt[0 .. 60]);
    assert(!aes128GcmOpen(key, nonce, sealed, got) && got.length == 0, "missing aad");
    auto bad = sealed.dup;
    bad[3] ^= 1;
    assert(!aes128GcmOpen(key, nonce, bad, got, aad));
    bad = sealed.dup;
    bad[$ - 1] ^= 1;
    assert(!aes128GcmOpen(key, nonce, bad, got, aad));
    assert(!aes128GcmOpen(key, nonce, sealed[0 .. 10], got, aad), "shorter than a tag");
    assert(aes128GcmOpen(z16, z12, hex("58e2fccefa7e3061367f1d57a4e7455a"), got) && got.length == 0);

    bool threw;
    try
        aes128GcmSeal(key[0 .. 15], nonce, pt);
    catch (CryptoError e)
        threw = e.msg == "vela.crypto: AES-128-GCM needs a 16-byte key";
    assert(threw);
}

void testKeys()
{
    auto k = EcKeyP256.generate();
    assert(k.hasPrivateKey);
    auto again = EcKeyP256.fromPrivateKey(k.privateKey);
    assert(again.publicKey == k.publicKey && again.privateKey == k.privateKey);
    auto pub = EcKeyP256.fromPublicKey(k.publicKey);
    assert(!pub.hasPrivateKey && pub.publicKey == k.publicKey);

    void rejects(void delegate() f, string why)
    {
        bool threw;
        try
            f();
        catch (CryptoError)
            threw = true;
        assert(threw, why);
    }
    rejects({ pub.privateKey; }, "a public key has no private part");
    rejects({ es256Sign(pub, "x"); }, "signing needs the private part");
    rejects({ EcKeyP256.fromPrivateKey(new ubyte[32]); }, "zero scalar");
    rejects({ EcKeyP256.fromPrivateKey(rep(0xff, 32)); }, "scalar above the order");
    rejects({ EcKeyP256.fromPrivateKey(new ubyte[31]); }, "short scalar");
    auto off = k.publicKey;
    off[64] ^= 1; // no longer on the curve
    rejects({ EcKeyP256.fromPublicKey(off[]); }, "point off the curve");
    rejects({ EcKeyP256.fromPublicKey(k.publicKey[0 .. 33]); }, "compressed points are not accepted");

    // ECDH: both sides agree; a third key does not
    auto a = EcKeyP256.generate(), b = EcKeyP256.generate();
    assert(ecdhP256(a, b.publicKey) == ecdhP256(b, a.publicKey));
    assert(ecdhP256(a, b) != ecdhP256(a, EcKeyP256.generate()));
}

void testEs256()
{
    auto k = EcKeyP256.generate();
    auto input = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0";
    auto sig = es256Sign(k, input);
    assert(es256Verify(k, input, sig[]));
    assert(es256Verify(EcKeyP256.fromPublicKey(k.publicKey), input, sig[]), "with the public key only");
    assert(!es256Verify(k, input ~ "x", sig[]));
    auto bad = sig;
    bad[10] ^= 1;
    assert(!es256Verify(k, input, bad[]));
    assert(!es256Verify(k, input, sig[0 .. 63]));
    assert(!es256Verify(EcKeyP256.generate(), input, sig[]), "another key");
    assert(es256Sign(k, input) != sig, "ECDSA signatures are randomized");
    opensslCrossCheck(k, input, sig);
}

/// Our signature verifies with the openssl command, and openssl's verifies with ours.
void opensslCrossCheck(EcKeyP256 k, string input, ubyte[64] sig)
{
    import std.file : write, read, tempDir, mkdirRecurse, rmdirRecurse;
    import std.process : execute;
    import std.path : buildPath;
    import std.conv : to;

    auto probe = execute(["openssl", "version"]);
    if (probe.status != 0)
    {
        fprintf(stderr, "note: openssl command not found; ES256 cross-check skipped\n");
        return;
    }
    auto dir = buildPath(tempDir, "vela_es256_" ~ (cast(size_t) &k).to!string);
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    // SubjectPublicKeyInfo and SEC1 ECPrivateKey for P-256, in DER
    auto spki = hex("3059301306072a8648ce3d020106082a8648ce3d030107034200") ~ k.publicKey[];
    auto sec1 = hex("30770201010420") ~ k.privateKey[] ~ hex("a00a06082a8648ce3d030107a144034200") ~ k.publicKey[];
    write(buildPath(dir, "pub.der"), spki);
    write(buildPath(dir, "key.der"), sec1);
    write(buildPath(dir, "data"), input);
    write(buildPath(dir, "ours.sig"), derSignature(sig[]));
    auto v = execute(["openssl", "dgst", "-sha256", "-verify", buildPath(dir, "pub.der"), "-keyform", "DER",
        "-signature", buildPath(dir, "ours.sig"), buildPath(dir, "data")]);
    assert(v.status == 0, "openssl does not verify our ES256 signature: " ~ v.output);
    auto s = execute(["openssl", "dgst", "-sha256", "-sign", buildPath(dir, "key.der"), "-keyform", "DER",
        "-out", buildPath(dir, "theirs.sig"), buildPath(dir, "data")]);
    assert(s.status == 0, "openssl dgst -sign: " ~ s.output);
    auto raw = rawSignature(cast(ubyte[]) read(buildPath(dir, "theirs.sig")));
    assert(es256Verify(k, input, raw[]), "openssl's signature does not verify with es256Verify");
}

/// r||s -> DER ECDSA-Sig-Value.
ubyte[] derSignature(scope const(ubyte)[] rs)
{
    ubyte[] integer(const(ubyte)[] x)
    {
        size_t i;
        while (i < x.length - 1 && x[i] == 0)
            i++;
        auto v = x[i .. $].dup;
        if (v[0] & 0x80)
            v = [cast(ubyte) 0] ~ v;
        return [cast(ubyte) 2, cast(ubyte) v.length] ~ v;
    }
    auto body_ = integer(rs[0 .. 32]) ~ integer(rs[32 .. 64]);
    return [cast(ubyte) 0x30, cast(ubyte) body_.length] ~ body_;
}

/// DER ECDSA-Sig-Value -> r||s.
ubyte[64] rawSignature(scope const(ubyte)[] der)
{
    ubyte[64] o;
    size_t p = 2;
    foreach (half; 0 .. 2)
    {
        assert(der[p] == 2);
        auto len = der[p + 1];
        auto v = der[p + 2 .. p + 2 + len];
        while (v.length > 32)
            v = v[1 .. $];
        o[half * 32 + 32 - v.length .. half * 32 + 32] = v[];
        p += 2 + len;
    }
    return o;
}

void testMisc()
{
    assert(base64UrlEncode(hex("fbffbf")) == "-_-_");
    assert(constantTimeEquals(sha256("a")[], sha256("a")[]) && !constantTimeEquals(sha256("a")[], sha256("b")[]));
}

int main()
{
    if (!cryptoAvailable())
    {
        fprintf(stderr, "skip: OpenSSL 3 (libcrypto.so.3) not available\n");
        return 77;
    }
    testSha256();
    testHmac();
    testHkdf();
    testGcm();
    testKeys();
    testEs256();
    testMisc();
    printf("crypto vectors: SHA-256, HMAC (RFC 4231), HKDF (RFC 5869), AES-128-GCM, P-256 keys, ES256, ECDH pass\n");
    return 0;
}
