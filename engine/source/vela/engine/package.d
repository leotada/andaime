/// `vela:engine` — transporte. Conhece sockets e bytes, nunca rotas ou DTOs.
module vela.engine;

public import vela.engine.loop;
public import vela.engine.bufferpool;
public import vela.engine.fiberio;
public import vela.engine.offload;
version (linux)
    public import vela.engine.httpclient;
public import vela.engine.devserver;
version (linux)
    public import vela.engine.epoll;
