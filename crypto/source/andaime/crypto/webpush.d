/// Web Push message encryption (RFC 8291) in the `aes128gcm` content coding (RFC 8188): what a push service expects in
/// the body of a push message, with `Content-Encoding: aes128gcm`. The VAPID `Authorization` header (RFC 8292) is a
/// JWT signed with `es256Sign`.
module andaime.crypto.webpush 2025;

@safe:

import andaime.crypto.common;
import andaime.crypto.hash : hkdfExtract, hkdfExpand;
import andaime.crypto.aead : aes128GcmSeal, aes128GcmOpen;
import andaime.crypto.ec : EcKeyP256, ecdhP256;

/// The largest payload one push message carries: a push service accepts 4096 bytes of body, of which 86 are the header,
/// 16 the authentication tag and 1 the padding delimiter.
enum size_t webPushMaxPayload = 4096 - 86 - 16 - 1;

/// Encrypts `payload` for a subscription: `uaPublic` is its `p256dh` key (65 bytes, base64url-decoded) and
/// `authSecret` its `auth` secret (16 bytes). Uses a fresh key pair and salt; returns the request body.
ubyte[] webPushEncrypt(scope const(ubyte)[] payload, scope const(ubyte)[] uaPublic, scope const(ubyte)[] authSecret)
{
    return webPushEncrypt(payload, uaPublic, authSecret, EcKeyP256.generate(), randomBytes(16));
}

/// ditto, with a given sender key pair and salt (16 bytes). Only for tests and known-answer vectors: reusing either
/// breaks the encryption's guarantees.
ubyte[] webPushEncrypt(scope const(ubyte)[] payload, scope const(ubyte)[] uaPublic, scope const(ubyte)[] authSecret,
    EcKeyP256 asKey, scope const(ubyte)[] salt)
{
    need(payload.length <= webPushMaxPayload, "a Web Push payload holds at most 3993 bytes");
    need(authSecret.length == 16, "the Web Push auth secret is 16 bytes");
    need(salt.length == 16, "the Web Push salt is 16 bytes");
    auto asPub = asKey.publicKey;
    ubyte[16] cek;
    ubyte[12] nonce;
    deriveKeys(ecdhP256(asKey, uaPublic), authSecret, uaPublic, asPub[], salt, cek, nonce);

    auto record = new ubyte[payload.length + 1];
    record[0 .. payload.length] = payload[];
    record[$ - 1] = 2; // the last (and only) record: delimiter 0x02, no padding
    auto sealed = aes128GcmSeal(cek[], nonce[], record);

    // header: salt (16) | record size (4, big-endian) | key id length (1) | key id: our public key (65)
    auto body_ = new ubyte[86 + sealed.length];
    body_[0 .. 16] = salt[];
    body_[16 .. 20] = [0, 0, 0x10, 0]; // 4096
    body_[20] = 65;
    body_[21 .. 86] = asPub[];
    body_[86 .. $] = sealed[];
    return body_;
}

/// The user agent's side: decrypts a body from `webPushEncrypt` with the subscription's key pair and auth secret. False
/// when the body is malformed or does not authenticate. (For tests, and for servers that receive push messages.)
bool webPushDecrypt(scope const(ubyte)[] body_, EcKeyP256 uaKey, scope const(ubyte)[] authSecret, out ubyte[] payload)
{
    need(authSecret.length == 16, "the Web Push auth secret is 16 bytes");
    if (body_.length < 86 + 16 + 1 || body_[20] != 65)
        return false;
    immutable rs = cast(size_t) body_[16] << 24 | body_[17] << 16 | body_[18] << 8 | body_[19];
    if (rs < 18 || body_.length - 86 > rs) // one record only
        return false;
    auto salt = body_[0 .. 16];
    auto asPub = body_[21 .. 86];
    EcKeyP256 asKey;
    try
        asKey = EcKeyP256.fromPublicKey(asPub);
    catch (CryptoError)
        return false;
    auto uaPub = uaKey.publicKey;
    ubyte[16] cek;
    ubyte[12] nonce;
    deriveKeys(ecdhP256(uaKey, asKey), authSecret, uaPub[], asPub, salt, cek, nonce);
    ubyte[] record;
    if (!aes128GcmOpen(cek[], nonce[], body_[86 .. $], record))
        return false;
    // strip the padding: zeros after the delimiter (0x02 for the last record)
    size_t end = record.length;
    while (end > 0 && record[end - 1] == 0)
        end--;
    if (end == 0 || record[end - 1] != 2)
        return false;
    payload = record[0 .. end - 1];
    return true;
}

/// RFC 8291 §3.3-3.4 and RFC 8188 §2.2: the content encryption key and the nonce.
private void deriveKeys(scope const(ubyte)[] ecdhSecret, scope const(ubyte)[] authSecret, scope const(ubyte)[] uaPub,
    scope const(ubyte)[] asPub, scope const(ubyte)[] salt, ref ubyte[16] cek, ref ubyte[12] nonce)
{
    static immutable ubyte[] webPushInfo = cast(immutable(ubyte)[]) "WebPush: info\0";
    static immutable ubyte[] cekInfo = cast(immutable(ubyte)[]) "Content-Encoding: aes128gcm\0";
    static immutable ubyte[] nonceInfo = cast(immutable(ubyte)[]) "Content-Encoding: nonce\0";

    auto prkKey = hkdfExtract(authSecret, ecdhSecret);
    auto ikm = hkdfExpand(prkKey[], webPushInfo ~ uaPub ~ asPub, 32);
    auto prk = hkdfExtract(salt, ikm);
    cek[] = hkdfExpand(prk[], cekInfo, 16)[];
    nonce[] = hkdfExpand(prk[], nonceInfo, 12)[];
}
