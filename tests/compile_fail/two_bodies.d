// EXPECT: há mais de um JsonBody; junte os campos num único DTO
import vela;
struct A { int x; } struct B { int y; }
string f(JsonBody!A a, JsonBody!B b) => "x";
void main() { auto app = new App; app.post!("/x", f); }
