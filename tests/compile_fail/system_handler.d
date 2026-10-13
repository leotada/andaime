// FLAGS: -version=VelaStrictSafe
// EXPECT: is not @safe (VelaStrictSafe is on). Mark it @safe (or put `@safe:` at the top of the module)
import vela;
string getUser(long id) @system => "x";
void main() { auto app = new App; app.get!("/users/{id}", getUser); }
