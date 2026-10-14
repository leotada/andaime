// EXPECT: returns WebSocket; register it with app.ws!("/chat", chat)
import vela;
@safe:
WebSocket chat() => WebSocket((scope WsConn ws) { ws.send("hi"); });
void main() { auto app = new App; app.get!("/chat", chat); }
