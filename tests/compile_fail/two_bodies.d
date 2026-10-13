// EXPECT: more than one body parameter (JsonBody or Form); merge the fields into a single DTO
import vela;
@safe:
struct A { int x; } struct B { int y; }
string f(JsonBody!A a, JsonBody!B b) => "x";
void main() { auto app = new App; app.post!("/x", f); }
