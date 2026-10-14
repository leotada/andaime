// EXPECT: a WebSocket route must return WebSocket, but it returns 'string'
import vela;
@safe:
string chat(string room) => room;
void main() { auto app = new App; app.ws!("/chat/{room}", chat); }
