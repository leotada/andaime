/// IP addresses without sockets: parsing, formatting and CIDR matching. IPv6-ready even though the server listens on
/// IPv4 only. No allocation (formatting writes into a caller's buffer).
module andaime.http.ip;

@safe:

/// An IPv4 or IPv6 address and, for a peer, its port. `family == 0` means "no address" (the default value).
struct IpAddress
{
    ubyte family;          /// 0 = none, 4 or 6
    ubyte[16] bytes;       /// IPv4 uses the first 4 bytes
    ushort port;           /// 0 when unknown

    bool valid() const pure nothrow @nogc => family != 0;

    /// An IPv4 address from the network-order `s_addr` value of a socket address.
    static IpAddress fromNetworkOrderV4(uint addr, ushort hostPort = 0) pure nothrow @nogc
    {
        IpAddress a;
        a.family = 4;
        // s_addr is in network byte order; its in-memory bytes are the address octets
        foreach (i; 0 .. 4)
            a.bytes[i] = cast(ubyte)(addr >> (8 * i)); // little-endian host: byte i of memory is bits 8*i..
        a.port = hostPort;
        return a;
    }

    /// Writes the address into `buf` (`1.2.3.4`, `2001:db8::1`; the port is not included). Returns the length.
    /// 39 bytes always suffice.
    size_t format(scope char[] buf) const pure nothrow @nogc
    {
        size_t n;
        void put(char c) { if (n < buf.length) buf[n++] = c; }
        void putDec(uint v)
        {
            char[3] d = void;
            size_t k = d.length;
            do { d[--k] = cast(char)('0' + v % 10); v /= 10; } while (v);
            foreach (c; d[k .. $]) put(c);
        }
        void putHex(uint v)
        {
            char[4] d = void;
            size_t k = d.length;
            do { d[--k] = "0123456789abcdef"[v & 15]; v >>= 4; } while (v);
            foreach (c; d[k .. $]) put(c);
        }
        if (family == 4)
        {
            foreach (i; 0 .. 4)
            {
                if (i) put('.');
                putDec(bytes[i]);
            }
        }
        else if (family == 6)
        {
            // RFC 5952: compress the longest run (>= 2) of zero groups
            uint[8] g;
            foreach (i; 0 .. 8)
                g[i] = (bytes[2 * i] << 8) | bytes[2 * i + 1];
            int bestStart = -1, bestLen = 0;
            for (int i = 0; i < 8;)
            {
                if (g[i] != 0) { i++; continue; }
                int j = i;
                while (j < 8 && g[j] == 0) j++;
                if (j - i > bestLen) { bestStart = i; bestLen = j - i; }
                i = j;
            }
            if (bestLen < 2) bestStart = -1;
            for (int i = 0; i < 8; i++)
            {
                if (i == bestStart)
                {
                    put(':');
                    i += bestLen - 1;
                    if (i == 7) put(':');
                    continue;
                }
                if (i) put(':');
                putHex(g[i]);
            }
        }
        return n;
    }

    /// The address as text (allocates; for logs and tests).
    string toString() const pure nothrow
    {
        char[39] b = void;
        return b[0 .. format(b[])].idup;
    }

    bool opEquals(const IpAddress o) const pure nothrow @nogc
    {
        if (family != o.family)
            return false;
        immutable n = family == 4 ? 4 : (family == 6 ? 16 : 0);
        return bytes[0 .. n] == o.bytes[0 .. n]; // the port is not part of the identity
    }
}

/// Parses `1.2.3.4`, `1.2.3.4:80`, `2001:db8::1`, `[2001:db8::1]` and `[2001:db8::1]:80`.
/// An IPv4-mapped IPv6 address (`::ffff:1.2.3.4`) becomes IPv4. Returns false for anything else.
bool parseIp(scope const(char)[] s, out IpAddress a) pure nothrow @nogc
{
    a = IpAddress.init;
    if (s.length == 0)
        return false;
    ushort port = 0;
    if (s[0] == '[')
    {
        size_t e = 1;
        while (e < s.length && s[e] != ']')
            e++;
        if (e == s.length)
            return false;
        auto host = s[1 .. e];
        auto rest = s[e + 1 .. $];
        if (rest.length)
        {
            if (rest[0] != ':' || !parsePort(rest[1 .. $], port))
                return false;
        }
        if (!parseV6(host, a))
            return false;
        a.port = port;
        return true;
    }
    size_t colons;
    foreach (c; s)
        if (c == ':')
            colons++;
    if (colons == 1)
    {
        // v4 with a port
        size_t c = 0;
        while (s[c] != ':')
            c++;
        if (!parsePort(s[c + 1 .. $], port) || !parseV4(s[0 .. c], a))
            return false;
        a.port = port;
        return true;
    }
    if (colons == 0)
        return parseV4(s, a);
    return parseV6(s, a);
}

private bool parsePort(scope const(char)[] s, out ushort port) pure nothrow @nogc
{
    port = 0;
    if (s.length == 0 || s.length > 5)
        return false;
    uint v;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            return false;
        v = v * 10 + (c - '0');
    }
    if (v > 65535)
        return false;
    port = cast(ushort) v;
    return true;
}

private bool parseV4(scope const(char)[] s, out IpAddress a) pure nothrow @nogc
{
    a = IpAddress.init;
    size_t part;
    uint cur;
    size_t digits;
    foreach (c; s)
    {
        if (c == '.')
        {
            if (digits == 0 || part == 3)
                return false;
            a.bytes[part++] = cast(ubyte) cur;
            cur = 0;
            digits = 0;
        }
        else if (c >= '0' && c <= '9')
        {
            if (digits == 1 && cur == 0)
                return false; // no leading zeros (ambiguous: octal in some parsers)
            cur = cur * 10 + (c - '0');
            if (++digits > 3 || cur > 255)
                return false;
        }
        else
            return false;
    }
    if (digits == 0 || part != 3)
        return false;
    a.bytes[3] = cast(ubyte) cur;
    a.family = 4;
    return true;
}

private bool parseV6(scope const(char)[] s, out IpAddress a) pure nothrow @nogc
{
    a = IpAddress.init;
    if (s.length < 2)
        return false;
    ushort[8] g;
    size_t n;                 // groups written before "::" (or in total)
    ushort[8] tail;
    size_t tn;                // groups after "::"
    bool gap;
    size_t i = 0;
    if (s[0] == ':')
    {
        if (s[1] != ':')
            return false;
        gap = true;
        i = 2;
    }
    while (i < s.length)
    {
        // a group of hex digits, or an embedded IPv4 as the last 32 bits
        size_t j = i;
        uint v;
        size_t digits;
        while (j < s.length && s[j] != ':')
        {
            immutable c = s[j];
            if (c == '.')
            {
                // embedded IPv4: the rest of the string
                IpAddress v4;
                size_t k = i;
                if (!parseV4(s[k .. $], v4) || (n + tn) > 6)
                    return false;
                auto dst = gap ? tail[] : g[];
                auto at = gap ? tn : n;
                dst[at] = cast(ushort)((v4.bytes[0] << 8) | v4.bytes[1]);
                dst[at + 1] = cast(ushort)((v4.bytes[2] << 8) | v4.bytes[3]);
                if (gap) tn += 2; else n += 2;
                i = s.length;
                goto done;
            }
            immutable int d = c >= '0' && c <= '9' ? c - '0' : (c >= 'a' && c <= 'f' ? c - 'a' + 10
                : (c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1));
            if (d < 0 || ++digits > 4)
                return false;
            v = v * 16 + d;
            j++;
        }
        if (digits == 0)
            return false;
        if (n + tn >= 8)
            return false;
        if (gap) tail[tn++] = cast(ushort) v; else g[n++] = cast(ushort) v;
        i = j;
        if (i < s.length)
        {
            // s[i] == ':'
            if (i + 1 < s.length && s[i + 1] == ':')
            {
                if (gap)
                    return false; // two "::"
                gap = true;
                i += 2;
                if (i == s.length)
                    break;
            }
            else
            {
                i++;
                if (i == s.length)
                    return false; // trailing single ':'
            }
        }
    }
done:
    if (gap ? (n + tn) > 7 : (n != 8))
        return false;
    ushort[8] all;
    foreach (k; 0 .. n)
        all[k] = g[k];
    foreach (k; 0 .. tn)
        all[8 - tn + k] = tail[k];
    // IPv4-mapped (::ffff:a.b.c.d) is just an IPv4 client
    bool mapped = all[0] == 0 && all[1] == 0 && all[2] == 0 && all[3] == 0 && all[4] == 0 && all[5] == 0xffff;
    if (mapped)
    {
        a.family = 4;
        a.bytes[0] = cast(ubyte)(all[6] >> 8);
        a.bytes[1] = cast(ubyte) all[6];
        a.bytes[2] = cast(ubyte)(all[7] >> 8);
        a.bytes[3] = cast(ubyte) all[7];
        return true;
    }
    a.family = 6;
    foreach (k; 0 .. 8)
    {
        a.bytes[2 * k] = cast(ubyte)(all[k] >> 8);
        a.bytes[2 * k + 1] = cast(ubyte) all[k];
    }
    return true;
}

/// A network in CIDR notation (`10.0.0.0/8`, `2001:db8::/32`, or a single address).
struct Cidr
{
    IpAddress net;
    ubyte prefix;

    bool contains(const IpAddress a) const pure nothrow @nogc
    {
        if (a.family != net.family || net.family == 0)
            return false;
        size_t bits = prefix;
        foreach (i; 0 .. (net.family == 4 ? 4 : 16))
        {
            if (bits == 0)
                return true;
            immutable take = bits >= 8 ? 8 : bits;
            immutable mask = cast(ubyte)(0xff << (8 - take));
            if ((a.bytes[i] & mask) != (net.bytes[i] & mask))
                return false;
            bits -= take;
        }
        return true;
    }
}

/// Parses `10.0.0.0/8`, `192.168.1.5` (a /32) or `::1` (a /128). The host bits may be set.
bool parseCidr(scope const(char)[] s, out Cidr c) pure nothrow @nogc
{
    c = Cidr.init;
    size_t slash = s.length;
    foreach (i, ch; s)
        if (ch == '/')
        {
            slash = i;
            break;
        }
    IpAddress a;
    if (!parseIp(s[0 .. slash], a) || a.port != 0)
        return false;
    immutable maxBits = a.family == 4 ? 32 : 128;
    uint bits = maxBits;
    if (slash < s.length)
    {
        auto p = s[slash + 1 .. $];
        if (p.length == 0 || p.length > 3)
            return false;
        bits = 0;
        foreach (ch; p)
        {
            if (ch < '0' || ch > '9')
                return false;
            bits = bits * 10 + (ch - '0');
        }
        if (bits > maxBits)
            return false;
    }
    c.net = a;
    c.prefix = cast(ubyte) bits;
    return true;
}

unittest
{
    IpAddress a;
    assert(parseIp("1.2.3.4", a) && a.family == 4 && a.toString == "1.2.3.4" && a.port == 0);
    assert(parseIp("1.2.3.4:8080", a) && a.toString == "1.2.3.4" && a.port == 8080);
    assert(parseIp("2001:db8::1", a) && a.family == 6 && a.toString == "2001:db8::1");
    assert(parseIp("[2001:db8::1]:443", a) && a.toString == "2001:db8::1" && a.port == 443);
    assert(parseIp("::1", a) && a.toString == "::1");
    assert(parseIp("::", a) && a.toString == "::");
    assert(parseIp("fe80::1:2:3:4", a) && a.toString == "fe80::1:2:3:4");
    assert(parseIp("2001:0db8:0000:0000:0000:0000:0000:0001", a) && a.toString == "2001:db8::1");
    assert(parseIp("1:2:3:4:5:6:7:8", a) && a.toString == "1:2:3:4:5:6:7:8");
    assert(parseIp("::ffff:1.2.3.4", a) && a.family == 4 && a.toString == "1.2.3.4", "IPv4-mapped is IPv4");
    assert(parseIp("64:ff9b::1.2.3.4", a) && a.family == 6);
    foreach (bad; ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "01.2.3.4", "1.2.3.4:", "1.2.3.4:99999", "a.b.c.d", "1:2:3:4:5:6:7",
        "1::2::3", ":1", "1:", "12345::", "[::1", "[::1]x", "::g", " 1.2.3.4", "1.2.3.4 ", "1..2.3"])
        assert(!parseIp(bad, a), bad);

    Cidr c;
    assert(parseCidr("10.0.0.0/8", c) && c.contains(IpAddress.init) == false);
    IpAddress in8, out8;
    parseIp("10.200.3.4", in8);
    parseIp("11.0.0.1", out8);
    assert(c.contains(in8) && !c.contains(out8));
    assert(parseCidr("192.168.1.5", c) && c.prefix == 32);
    IpAddress h;
    parseIp("192.168.1.5", h);
    assert(c.contains(h));
    parseIp("192.168.1.6", h);
    assert(!c.contains(h));
    assert(parseCidr("2001:db8::/32", c));
    parseIp("2001:db8:ffff::1", h);
    assert(c.contains(h));
    parseIp("2001:db9::1", h);
    assert(!c.contains(h));
    assert(parseCidr("0.0.0.0/0", c));
    parseIp("8.8.8.8", h);
    assert(c.contains(h));
    assert(!parseCidr("10.0.0.0/33", c) && !parseCidr("10.0.0.0/", c) && !parseCidr("::1/129", c) && !parseCidr("x/8", c));

    // the byte order of a socket address: 127.0.0.1 is s_addr 0x0100007f on a little-endian host
    version (LittleEndian)
        assert(IpAddress.fromNetworkOrderV4(0x0100007f, 5).toString == "127.0.0.1");
}
