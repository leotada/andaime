// EXPECT: query lists hold scalars (int, string, enum...)
import vela;
@safe:
struct Filter { int a; }
string f(Filter[] filters) => "x";
void main() { auto app = new App; app.get!("/f", f); }
