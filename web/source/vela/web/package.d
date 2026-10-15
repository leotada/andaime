/// `vela:web` — high-level API. Knows nothing about sockets: operates on
/// `Request` (slices) and writes into a response buffer.
module vela.web;

@safe:

public import vela.web.application;
public import vela.web.context;
public import vela.web.params;
public import vela.web.dto : jsonKey, optional, jsonIgnore, minLength, maxLength, inRange, schemaName,
    ValidationErrors, FieldError, ErrorSource, LocPart;
public import vela.web.handler_traits : writeDefaultValidationErrors;
public import vela.web.jsonvalue : JsonValue, JsonMember, JsonType, JsonError, JsonLimits, parseJson, fromJson, toJson;
public import vela.web.json : writeJson;
public import vela.web.testing;
public import vela.web.cors;
public import vela.web.openapi : OpenApiInfo, summary;
public import vela.web.middleware;
public import vela.web.stream : Stream, StreamWriter, EventStream, EventWriter, produces, sendResponse;
public import vela.web.websocket : WebSocket;
public import vela.http.websocket : WsConn, WsMessage, WsKind, WsCloseCode, WsClosed;
public import vela.web.router : RouteError;
public import vela.web.models : Query, Form, UploadedFile;
public import vela.web.cookies : cookie, setCookie, deleteCookie, CookieOptions, SameSite;
