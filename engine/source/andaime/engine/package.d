/// `andaime:engine` — transport. Knows sockets and bytes, never routes or DTOs.
module andaime.engine 2025;

public import andaime.engine.loop;
public import andaime.engine.bufferpool;
public import andaime.engine.fiberio;
public import andaime.engine.offload;
public import andaime.engine.random;
public import andaime.engine.httpclient;
public import andaime.engine.httpfake;
public import andaime.engine.wsclient;
public import andaime.engine.zlib;
public import andaime.engine.tls : tlsAvailable, tlsLoadError;
public import andaime.engine.devserver;
public import andaime.engine.epoll;
