// EXPECT: @status(700) is not an HTTP status; use a code from 100 to 599
import vela;
@safe:
@status(700) string getUser() => "x";
void main() { auto app = new App; app.get!("/users", getUser); }
