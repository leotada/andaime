/// `vela:engine` — transport. Knows sockets and bytes, never routes or DTOs.
module vela.engine;

public import vela.engine.loop;
public import vela.engine.bufferpool;
public import vela.engine.fiberio;
public import vela.engine.offload;
public import vela.engine.random;
public import vela.engine.httpclient;
public import vela.engine.httpfake;
public import vela.engine.wsclient;
public import vela.engine.zlib;
public import vela.engine.tls : tlsAvailable, tlsLoadError;
public import vela.engine.devserver;
public import vela.engine.epoll;
