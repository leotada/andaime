// EXPECT: fields must be scalars (int, string, enum, bool...), text types, Optional of those, or lists of scalars
import vela;
@safe:
struct Inner { int a; }
struct Filters { Inner inner; }
string f(Query!Filters q) => "x";
void main() { auto app = new App; app.get!("/f", f); }
