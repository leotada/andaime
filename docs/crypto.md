# Cryptography: `andaime:crypto`

`andaime:crypto` has the primitives web applications usually need: password hashes, signed tokens, Web Push. It is a
separate subpackage. An application that uses it adds `dependency "andaime:crypto" version="*"` and `import andaime.crypto;`;
the rest of andaime does not depend on it.

It calls OpenSSL 3's libcrypto and libxcrypt (for bcrypt), both loaded at run time like the TLS code: the build never
needs them, and a function whose library is missing throws `CryptoError` ("andaime.crypto: OpenSSL 3 (libcrypto.so.3) not
found..."). Debian and Ubuntu: `libssl3` and `libcrypt1`; Fedora and openSUSE: `openssl-libs`/`libopenssl3` and
`libxcrypt`. Everything is `@safe`.

```d
// check
import andaime;
import andaime.crypto;
import std.datetime.systime : Clock;
import std.conv : to;

struct SignUp { @minLength(3) string email; @minLength(8) string password; }
struct Login { string email; string password; }
struct Token { string token; }
struct Subscription { string endpoint; string p256dh; string auth; }

string[string] passwordHashes; // email -> bcrypt hash (a database in a real app)
EcKeyP256 vapidKey;            // load it from your secrets: EcKeyP256.fromPrivateKey(base64url-decoded bytes)

@status(201) void signUp(JsonBody!SignUp b)
{
    // bcrypt costs ~250 ms of CPU: the Offload variants run it on the thread pool, not on the event loop
    passwordHashes[b.email] = bcryptHashOffload(b.password);
}

Token login(JsonBody!Login b)
{
    auto hash = b.email in passwordHashes;
    if (hash is null || !bcryptVerifyOffload(b.password, *hash))
        throw new HttpError(401, "wrong email or password");
    return Token(base64UrlEncode(randomBytes(32)));
}

/// The VAPID JWT (RFC 8292) for a push service: ES256 over "header.claims", signature as raw r||s in base64url.
string vapidJwt(string audience)
{
    auto header = base64UrlEncode(cast(const(ubyte)[]) `{"typ":"JWT","alg":"ES256"}`);
    auto exp = (Clock.currTime.toUnixTime + 12 * 3600).to!string;
    auto claims = base64UrlEncode(cast(const(ubyte)[]) (`{"aud":"` ~ audience ~ `","exp":` ~ exp
        ~ `,"sub":"mailto:ops@example.com"}`));
    auto input = header ~ "." ~ claims;
    return input ~ "." ~ base64UrlEncode(es256Sign(vapidKey, input)[]);
}

/// The body and headers of one push message (POST them to `s.endpoint` with httpClient).
ubyte[] pushBody(Subscription s, string message)
{
    ubyte[] uaPublic, auth;
    if (!base64UrlDecode(s.p256dh, uaPublic) || !base64UrlDecode(s.auth, auth))
        throw new HttpError(400, "bad subscription keys");
    return webPushEncrypt(cast(const(ubyte)[]) message, uaPublic, auth);
    // headers: Content-Encoding: aes128gcm, TTL: 60,
    //          Authorization: vapid t=<vapidJwt(origin of endpoint)>, k=<base64UrlEncode(vapidKey.publicKey[])>
}

void main()
{
    serve(() {
        auto app = new App;
        app.post!("/signup", signUp);
        app.post!("/login", login);
        return app;
    });
}
```

## What is there

| Function | What it does |
|----------|--------------|
| `randomBytes(n)` | `n` bytes from the kernel's CSPRNG (getrandom): tokens, salts, keys. Needs no library. |
| `constantTimeEquals(a, b)` | Compares bytes or text in time that does not depend on where they differ (MACs, tokens). Needs no library. |
| `base64UrlEncode(bytes)`, `base64UrlDecode(text, out bytes)` | base64url without padding (from `andaime:http`); decoding is strict and returns false on bad input. |
| `sha256(data)` | SHA-256 (32 bytes). |
| `Sha256.start()`, `put(piece)`, `finish()` | SHA-256 of data that arrives in pieces (a file read in blocks), without holding it whole. Not copyable; spent by `finish`. |
| `hmacSha256(key, data)` | HMAC-SHA256 (32 bytes). |
| `hkdfSha256(salt, ikm, info, length)`, `hkdfExtract`, `hkdfExpand` | HKDF (RFC 5869). |
| `aes128GcmSeal(key, nonce, plaintext, aad)`, `aes128GcmOpen(key, nonce, sealed, out plaintext, aad)` | AES-128-GCM with a 16-byte key and a 12-byte nonce; the sealed form is the ciphertext followed by the 16-byte tag; `Open` returns false when the tag does not match. |
| `EcKeyP256.generate()`, `.fromPrivateKey(32 bytes)`, `.fromPublicKey(65 bytes)`, `.privateKey`, `.publicKey` | P-256 keys; public keys are uncompressed points (`0x04 ‖ X ‖ Y`), checked to be on the curve. |
| `es256Sign(key, data)`, `es256Verify(key, data, signature)` | ECDSA P-256 with SHA-256, with JWS's raw 64-byte `r‖s` signatures (not DER). |
| `ecdhP256(ourKey, peer)` | The ECDH shared secret (32 bytes). |
| `webPushEncrypt(payload, p256dh, auth)` | A Web Push message body (RFC 8291, `Content-Encoding: aes128gcm`), with a fresh key and salt; at most `webPushMaxPayload` (3993) bytes of payload. `webPushDecrypt` is the receiving side. |
| `bcryptHash(password, cost = 12)`, `bcryptVerify(password, hash)` | bcrypt `$2b$` hashes, compatible with Python's bcrypt and passlib (and `$2a$`/`$2y$` hashes from elsewhere). |
| `bcryptHashOffload`, `bcryptVerifyOffload` | The same, on the [offload pool](concurrency.md); use these inside handlers. |
| `cryptoAvailable()`, `bcryptAvailable()` | Whether the libraries load (for startup checks and tests). |

## Rules

- **bcrypt is slow on purpose.** Cost 12 takes about a quarter of a second of CPU. On the event loop that stalls every
  request of the worker; inside a handler call the `Offload` variants (they throw `PoolSaturated` when the pool's queue is
  full, which you can turn into a 503). Only the first 72 bytes of a password count, as in every bcrypt; a password with a
  NUL byte cannot be hashed (`bcryptVerify` returns false for it).
- **Authentication failures are `false`, not exceptions**: `aes128GcmOpen`, `es256Verify`, `bcryptVerify`,
  `webPushDecrypt`, `base64UrlDecode`. Exceptions (`CryptoError`) mean a missing library or misuse (a key of the wrong
  size, a bcrypt cost outside 4..31).
- **Never reuse an AES-GCM nonce with the same key.** Use `randomBytes(12)` per message, or a counter.
  `webPushEncrypt` picks a fresh key pair and salt per message; its overload that takes them is for known-answer tests.
- Compare secrets with `constantTimeEquals`, not `==`.
- The OpenSSL key inside `EcKeyP256` never leaves it; it is freed with the object.

## Tests

`tests/crypto/` checks the official vectors: RFC 4231 (HMAC), RFC 5869 (HKDF), the GCM specification's AES-128 cases,
RFC 8291 Appendix A end to end (the body matches byte for byte), ES256 against the `openssl` command in both directions,
and bcrypt against hashes made by Python's bcrypt. Without OpenSSL 3 or libxcrypt they report a skip.
