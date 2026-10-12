/// `vela:web` — API de alto nível. Não conhece sockets: opera sobre
/// `Request` (fatias) e escreve num buffer de resposta.
module vela.web;

public import vela.web.application;
public import vela.web.context;
public import vela.web.params;
public import vela.web.dto : jsonKey, optional, jsonIgnore, minLength, maxLength, inRange;
public import vela.web.testing;
public import vela.web.cors;
public import vela.web.openapi : OpenApiInfo, summary;
public import vela.web.middleware;
