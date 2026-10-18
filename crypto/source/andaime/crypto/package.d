/// `andaime:crypto` — cryptographic primitives for applications, over OpenSSL 3's libcrypto and libxcrypt, both loaded at
/// run time: an application that does not call them does not need either library. Everything is `@safe`; failures to
/// load a library or misuse (a key of the wrong size) throw `CryptoError` (`andaime.crypto: ...`).
///
/// - random bytes and constant-time comparison: `randomBytes`, `constantTimeEquals`
/// - base64url without padding: `base64UrlEncode`, `base64UrlDecode` (from `andaime:http`)
/// - hashing: `sha256`, `hmacSha256`, `hkdfSha256` (`hkdfExtract`, `hkdfExpand`)
/// - AES-128-GCM: `aes128GcmSeal`, `aes128GcmOpen`
/// - P-256: `EcKeyP256`, `es256Sign`/`es256Verify` (JWS ES256, raw `r||s`), `ecdhP256`
/// - Web Push (RFC 8291): `webPushEncrypt`, `webPushDecrypt`
/// - passwords: `bcryptHash`, `bcryptVerify` (CPU-heavy: from a handler use `bcryptHashOffload`, `bcryptVerifyOffload`)
module andaime.crypto 2025;

public import andaime.crypto.common : CryptoError, cryptoAvailable, randomBytes, constantTimeEquals;
public import andaime.http.base64url : base64UrlEncode, base64UrlDecode;
public import andaime.crypto.hash;
public import andaime.crypto.aead;
public import andaime.crypto.ec;
public import andaime.crypto.webpush;
public import andaime.crypto.bcrypt;
