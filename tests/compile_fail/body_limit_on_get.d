// EXPECT: @bodyLimit on GET, which has no body
import andaime;
@safe:
@bodyLimit(1024) string f() => "x";
void main() { auto app = new App; app.get!("/f", f); }
