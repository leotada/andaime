// FLAGS: -version=AndaimeStrictSafe
// EXPECT: is not @safe (AndaimeStrictSafe is on). Mark it @safe (or put `@safe:` at the top of the module)
import andaime;
string getUser(long id) @system => "x";
void main() { auto app = new App; app.get!("/users/{id}", getUser); }
