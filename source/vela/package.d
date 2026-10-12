/// `import vela;` traz tudo o que uma aplicação precisa.
module vela;

public import vela.http.types : Method, HeaderField, Request;
public import vela.web;
public import vela.server : serve;
public import vela.staticfiles : serveStatic, StaticConfig;
public import vela.engine.loop : ServerConfig;
// E/S cooperativa para handlers: esperar sem bloquear o worker
public import vela.engine.fiberio : sleep, awaitFd, IoEvent, RequestCancelled;
// Trabalho que bloqueia (DNS, CPU, libs C) e chamadas HTTP de saída, ambos cooperativos
public import vela.engine.offload : offload, configureOffload, PoolSaturated;
version (linux)
    public import vela.engine.httpclient : httpClient, HttpClient, HttpClientConfig, HttpClientError,
        HttpClientTimeout, ClientResponse, HeaderPair;
