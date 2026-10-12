/// `vela:http` — HTTP/1.1 types and wire format. No I/O, no GC on the hot path.
module vela.http;

public import vela.http.types;
public import vela.http.buffer;
public import vela.http.parser;
public import vela.http.writer;
public import vela.http.date;
