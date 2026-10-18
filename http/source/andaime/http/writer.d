/// Serializes the HTTP/1.1 response head straight into a ByteBuffer (the structured form lives in `andaime.http.response`).
module andaime.http.writer 2025;

@safe:

import andaime.http.types;
import andaime.http.buffer;
import andaime.http.response;

/// Convenience form used for the responses the engine itself produces (errors, redirects): a known length, no streaming.
void writeResponseHead(ref ByteBuffer o, int status, scope const(char)[] contentType,
    size_t contentLength, scope const HeaderField[] extra, bool keepAlive) nothrow @nogc @safe
{
    const ResponseHead head = ResponseHead(status, contentType, extra, cast(long) contentLength);
    andaime.http.response.writeResponseHead(o, head, keepAlive, false); // (the structured overload)
}

unittest
{
    ByteBuffer b;
    HeaderField[1] x = [HeaderField("X-Id", "7")];
    writeResponseHead(b, 201, "application/json", 2, x[], false);
    assert(b.data == "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n"
        ~ "Content-Length: 2\r\nX-Id: 7\r\nConnection: close\r\n\r\n", b.data.idup);
}
