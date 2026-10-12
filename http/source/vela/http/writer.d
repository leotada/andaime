/// Serializes the HTTP/1.1 response head straight into a ByteBuffer.
module vela.http.writer;

import vela.http.types;
import vela.http.buffer;

void writeResponseHead(ref ByteBuffer o, int status, scope const(char)[] contentType,
    size_t contentLength, scope const HeaderField[] extra, bool keepAlive) nothrow @nogc @safe
{
    o.put("HTTP/1.1 ");
    o.putUint(status);
    o.put(' ');
    o.put(statusText(status));
    o.put("\r\n");
    if (contentType.length)
    {
        o.put("Content-Type: ");
        o.put(contentType);
        o.put("\r\n");
    }
    // 204 and 304 carry no body or Content-Length (RFC 9110 §8.6)
    if (status != 204 && status != 304)
    {
        o.put("Content-Length: ");
        o.putUint(contentLength);
        o.put("\r\n");
    }
    foreach (ref h; extra)
    {
        o.put(h.name);
        o.put(": ");
        o.put(h.value);
        o.put("\r\n");
    }
    if (!keepAlive)
        o.put("Connection: close\r\n");
    o.put("\r\n");
}

unittest
{
    ByteBuffer b;
    HeaderField[1] x = [HeaderField("X-Id", "7")];
    writeResponseHead(b, 201, "application/json", 2, x[], false);
    assert(b.data == "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n"
        ~ "Content-Length: 2\r\nX-Id: 7\r\nConnection: close\r\n\r\n", b.data);
}
