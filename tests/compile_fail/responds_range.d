// EXPECT: @responds(42, ...) is not an HTTP status; use a code from 100 to 599
import vela;
@safe:
@responds(42, "nope") string getUser() => "x";
void main() { auto app = new App; app.get!("/users", getUser); }
