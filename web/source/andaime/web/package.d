/// `andaime:web` — high-level API. Knows nothing about sockets: operates on
/// `Request` (slices) and writes into a response buffer.
module andaime.web 2025;

@safe:

public import andaime.web.application;
public import andaime.web.context;
public import andaime.web.params;
public import andaime.web.dto : jsonKey, optional, jsonIgnore, omitIfAbsent, minLength, maxLength, inRange, schemaName,
    ValidationErrors, FieldError, ErrorSource, LocPart;
public import andaime.http.naming : Naming, naming, wireName, defaultNaming;
public import andaime.web.handler_traits : writeDefaultValidationErrors;
public import andaime.web.jsonvalue : JsonValue, JsonMember, JsonType, JsonError, JsonLimits, parseJson, fromJson, toJson,
    Json;
public import andaime.web.json : writeJson;
public import andaime.values.uuid : Uuid;
public import andaime.values.timestamp : Timestamp;
public import andaime.values.calendardate : CalendarDate;
public import andaime.values.copy : copyAs;
public import andaime.web.errors : ErrorInfo, ProblemDetails, ProblemField, problemDetails, problemJson;
public import andaime.log;
public import andaime.web.testing;
public import andaime.web.cors;
public import andaime.web.openapi : OpenApiInfo, summary;
public import andaime.web.middleware;
public import andaime.web.stream : Stream, StreamWriter, EventStream, EventWriter, produces, sendResponse;
public import andaime.web.websocket : WebSocket;
public import andaime.http.websocket : WsConn, WsMessage, WsKind, WsCloseCode, WsClosed;
public import andaime.web.router : RouteError;
public import andaime.web.models : Query, Form, UploadedFile;
public import andaime.web.cookies : cookie, setCookie, deleteCookie, CookieOptions, SameSite;
