// EXPECT: is a Form, but GET has no body; use POST, PUT or PATCH
import vela;
@safe:
struct Login { string user; }
string f(Form!Login l) => "x";
void main() { auto app = new App; app.get!("/f", f); }
