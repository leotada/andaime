// EXPECT: @status does not apply to a WebSocket route (it answers 101); remove it
import vela;
@safe:
@status(201) WebSocket chat() => WebSocket((scope WsConn ws) { ws.send("hi"); });
void main() { auto app = new App; app.ws!("/chat", chat); }
