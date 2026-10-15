/// `import vela;` brings in everything an application needs.
module vela;

public import vela.http.types : Method, HeaderField, Request, Protocol;
public import vela.web;
public import vela.server : serve, tryServe;
public import vela.staticfiles : serveStatic, StaticConfig;
public import vela.engine.loop : ServerConfig, TlsConfig, ErrorBody, jsonErrorBodies;
// Cooperative I/O for handlers: wait without blocking the worker
public import vela.engine.fiberio : sleep, awaitFd, IoEvent, RequestCancelled, spawn, stopping, workerIndex;
// Blocking work (DNS, CPU, C libs) and outgoing HTTP calls, both cooperative
public import vela.engine.offload : offload, configureOffload, PoolSaturated;
version (linux)
{
    public import vela.engine.httpclient : httpClient, HttpClient, HttpClientConfig, HttpClientError,
        HttpClientTimeout, ClientResponse, HeaderPair, HttpTransport, setHttpTransport;
    public import vela.engine.httpfake : FakeHttpClient, Expectation, RecordedRequest;
    public import vela.engine.wsclient : wsConnect, WsClientOptions;
}
