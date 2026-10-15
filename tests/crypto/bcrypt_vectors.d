/// bcrypt against hashes made by Python's bcrypt 4.3 (passlib's backend), including a `$2a$` one, plus new hashes,
/// wrong passwords, malformed hashes, the 72-byte limit and the offload helpers. Exits 77 (skip) when libxcrypt is
/// missing.
module bcrypt_vectors;

import vela.crypto;
import core.stdc.stdio : fprintf, printf, stderr;

int main()
{
    if (!bcryptAvailable())
    {
        fprintf(stderr, "skip: libxcrypt (libcrypt.so.1 with crypt_rn) not available\n");
        return 77;
    }

    // python3 -c "import bcrypt; print(bcrypt.hashpw(pw, bcrypt.gensalt(rounds=cost, prefix=b'2b')))"
    static immutable string[2][] vectors = [
        ["correct horse battery staple", "$2b$12$J.AOd9Ij4hyQq0sx6TzDsO.oS.vJMjGs8vIj.1rgFJRRADn.rJiRG"],
        ["S3nh@-ção", "$2b$12$MD/D1Dupcm.YWeY6viiAjeL1fvbgRRnrLqRDrUw8H521mskhwiLzy"],
        ["", "$2b$04$FtTF1sWsMsDSiHN4NALoo./klUT5Zk/F/sfgDxGHEeQki04St43Tu"],
        ["xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            "$2b$04$69rWNeZQGFSjfZMth2wWj.s/BoLp8rav692BfyiHzsSnhF8DMV3U6"],
        ["short", "$2b$10$pLyzvFiudTAqval.uVbLHOI5FXSs4MMbj4cLfeTcKYB.WCTgJMUGq"],
        ["password", "$2a$05$q8XgwEPF/8PftWSNF76xp.TE.ZCjI/98dUzPfNYWSsdh9CbuVyb8W"],
    ];
    foreach (v; vectors)
    {
        assert(bcryptVerify(v[0], v[1]), v[1]);
        assert(!bcryptVerify("!" ~ v[0], v[1]), "wrong password accepted for " ~ v[1]);
    }

    // only the first 72 bytes count (the 72-x vector also verifies with more x's)
    auto x72 = vectors[3][0];
    assert(bcryptVerify(x72 ~ "yyy", vectors[3][1]));

    // new hashes: the format, a fresh salt each time, and they verify
    auto h1 = bcryptHash("hunter2", 4), h2 = bcryptHash("hunter2", 4);
    assert(h1.length == 60 && h1[0 .. 7] == "$2b$04$" && h1 != h2, h1);
    assert(bcryptVerify("hunter2", h1) && bcryptVerify("hunter2", h2) && !bcryptVerify("hunter3", h1));
    assert(bcryptHash("x")[0 .. 7] == "$2b$12$", "default cost 12");

    // malformed hashes and passwords are false, never an exception
    foreach (bad; ["", "$2b$12$short", "$1$abcdefgh$abcdefghijklmnopqrstuv", vectors[0][1][0 .. 59],
        vectors[0][1][0 .. 59] ~ "!", "$2x$12$J.AOd9Ij4hyQq0sx6TzDsO.oS.vJMjGs8vIj.1rgFJRRADn.rJiRG",
        "$2b$99$J.AOd9Ij4hyQq0sx6TzDsO.oS.vJMjGs8vIj.1rgFJRRADn.rJiRG"])
        assert(!bcryptVerify("correct horse battery staple", bad), bad);
    assert(!bcryptVerify("a\0b", h1));

    bool threw;
    try
        bcryptHash("x", 3);
    catch (CryptoError e)
        threw = e.msg == "vela.crypto: the bcrypt cost goes from 4 to 31";
    assert(threw);
    threw = false;
    try
        bcryptHash("a\0b", 4);
    catch (CryptoError)
        threw = true;
    assert(threw);

    // outside a request the offload helpers run inline
    auto h3 = bcryptHashOffload("pw", 4);
    assert(bcryptVerifyOffload("pw", h3) && !bcryptVerifyOffload("px", h3));

    printf("bcrypt: %zu python bcrypt vectors, new hashes, malformed input and offload helpers pass\n", vectors.length);
    return 0;
}
