/// `vela:engine` — transport. Knows sockets and bytes, never routes or DTOs.
module vela.engine;

public import vela.engine.loop;
public import vela.engine.bufferpool;
public import vela.engine.fiberio;
public import vela.engine.offload;
version (linux)
    public import vela.engine.random;
version (linux)
{
    public import vela.engine.httpclient;
    public import vela.engine.wsclient;
    public import vela.engine.zlib;
}
public import vela.engine.devserver;
version (linux)
    public import vela.engine.epoll;
