/// `import andaime;` brings in everything an application needs.
module andaime 2025;

public import andaime.http.types : Method, HeaderField, Request, Protocol;
public import andaime.web;
public import andaime.server : serve, tryServe;
public import andaime.staticfiles : serveStatic, StaticConfig;
public import andaime.engine.loop : ServerConfig, TlsConfig, ErrorBody, jsonErrorBodies;
// Cooperative I/O for handlers: wait without blocking the worker
public import andaime.engine.fiberio : sleep, awaitFd, IoEvent, RequestCancelled, spawn, stopping, workerIndex;
// Per-fiber values for code below a handler or a job (one per class type)
public import andaime.engine.fiberio : fiberLocal, setFiberLocal, clearFiberLocal;
// Blocking work (DNS, CPU, C libs) and outgoing HTTP calls, both cooperative
public import andaime.engine.offload : offload, configureOffload, PoolSaturated;
public import andaime.engine.httpclient : httpClient, HttpClient, HttpClientConfig, HttpClientError,
    HttpClientTimeout, ClientResponse, HeaderPair, HttpTransport, setHttpTransport;
public import andaime.engine.httpfake : FakeHttpClient, Expectation, RecordedRequest;
public import andaime.engine.wsclient : wsConnect, WsClientOptions;
// Is a native library installed? (startup and image checks)
public import andaime.engine.tls : tlsAvailable, tlsLoadError;
public import andaime.engine.zlib : zlibAvailable, zlibLoadError;
