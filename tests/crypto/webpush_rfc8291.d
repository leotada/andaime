/// RFC 8291 Appendix A end to end: ECDH with the fixed keys, HKDF for every intermediate value, AES-128-GCM, the header;
/// the body must match the RFC byte for byte, and the receiver's side must decrypt it.
/// Exits 77 (skip) when OpenSSL 3 cannot be loaded.
module webpush_rfc8291;

import vela.crypto;
import vela.crypto.hash : hkdfExtract, hkdfExpand;
import core.stdc.stdio : fprintf, printf, stderr;

ubyte[] b64(string s)
{
    string t;
    foreach (c; s)
        if (c != ' ' && c != '\n')
            t ~= c;
    ubyte[] r;
    if (!base64UrlDecode(t, r))
        throw new Exception("bad base64url in the test: " ~ s);
    return r;
}

int main()
{
    if (!cryptoAvailable())
    {
        fprintf(stderr, "skip: OpenSSL 3 (libcrypto.so.3) not available\n");
        return 77;
    }

    auto plaintext = b64("V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24");
    assert(cast(string) plaintext == "When I grow up, I want to be a watermelon");
    auto asPublic = b64("BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8");
    auto asPrivate = b64("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw");
    auto uaPublic = b64("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4");
    auto uaPrivate = b64("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94");
    auto salt = b64("DGv6ra1nlYgDCS1FRnbzlw");
    auto authSecret = b64("BTBZMqHH6r4Tts7J_aSIgg");

    // keys: importing a private scalar gives back the RFC's public point
    auto asKey = EcKeyP256.fromPrivateKey(asPrivate);
    auto uaKey = EcKeyP256.fromPrivateKey(uaPrivate);
    assert(asKey.publicKey[] == asPublic, "as_public from as_private");
    assert(uaKey.publicKey[] == uaPublic, "ua_public from ua_private");
    assert(asKey.privateKey[] == asPrivate);

    // intermediate values
    auto ecdh = ecdhP256(asKey, uaPublic);
    assert(ecdh[] == b64("kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs"), "ecdh_secret");
    assert(ecdhP256(uaKey, asPublic) == ecdh, "ECDH is symmetric");
    auto prkKey = hkdfExtract(authSecret, ecdh[]);
    assert(prkKey[] == b64("Snr3JMxaHVDXHWJn5wdC52WjpCtd2EIEGBykDcZW32k"), "PRK_key");
    auto keyInfo = cast(const(ubyte)[]) "WebPush: info\0" ~ uaPublic ~ asPublic;
    assert(keyInfo == b64("V2ViUHVzaDogaW5mbwAEJXGyvs3942BVGq8e0PTNNmwR zr5VX4m8t7GGpTM5FzFo7OLr4BhZe9MEebhuPI-OztV3"
        ~ "ylkYfpJGmQ22ggCLDgT-M_SrDepxkU21WCP3O1SUj0EwbZIHMtu5pZpTKGSCIA5Zent7wmC6HCJ5mFgJkuk5cwAv MBKiiujwa7t45ewP"),
        "key_info");
    auto ikm = hkdfExpand(prkKey[], keyInfo, 32);
    assert(ikm == b64("S4lYMb_L0FxCeq0WhDx813KgSYqU26kOyzWUdsXYyrg"), "IKM");
    auto prk = hkdfExtract(salt, ikm);
    assert(prk[] == b64("09_eUZGrsvxChDCGRCdkLiDXrReGOEVeSCdCcPBSJSc"), "PRK");
    auto cek = hkdfExpand(prk[], cast(const(ubyte)[]) "Content-Encoding: aes128gcm\0", 16);
    assert(cek == b64("oIhVW04MRdy2XN9CiKLxTg"), "CEK");
    auto nonce = hkdfExpand(prk[], cast(const(ubyte)[]) "Content-Encoding: nonce\0", 12);
    assert(nonce == b64("4h_95klXJ5E_qnoN"), "NONCE");

    // the whole body (Section 5): header and ciphertext
    auto expected = b64("DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml"
        ~ "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT"
        ~ "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN");
    // 86 (header) + 41 (plaintext) + 1 (delimiter) + 16 (tag); the RFC's example says Content-Length: 145, but its body
    // decodes to 144 bytes
    assert(expected.length == 144);
    auto body_ = webPushEncrypt(plaintext, uaPublic, authSecret, asKey, salt);
    assert(body_ == expected, "the RFC 8291 body: " ~ base64UrlEncode(body_));

    // the receiver decrypts it; a tampered body or the wrong secret does not authenticate
    ubyte[] got;
    assert(webPushDecrypt(body_, uaKey, authSecret, got) && got == plaintext);
    auto bad = body_.dup;
    bad[$ - 1] ^= 1;
    assert(!webPushDecrypt(bad, uaKey, authSecret, got));
    auto wrongAuth = authSecret.dup;
    wrongAuth[0] ^= 1;
    assert(!webPushDecrypt(body_, uaKey, wrongAuth, got));

    // a fresh key and salt each time: different bodies, both decrypt
    auto r1 = webPushEncrypt(plaintext, uaPublic, authSecret);
    auto r2 = webPushEncrypt(plaintext, uaPublic, authSecret);
    assert(r1 != r2 && r1.length == 144);
    assert(webPushDecrypt(r1, uaKey, authSecret, got) && got == plaintext);
    assert(webPushDecrypt(r2, uaKey, authSecret, got) && got == plaintext);

    printf("RFC 8291 Appendix A: body matches byte for byte; decrypt, tamper and fresh-key checks pass\n");
    return 0;
}
