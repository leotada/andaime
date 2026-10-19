// FLAGS: -version=VelaStrictSafe
// EXPECT: andaime: version VelaStrictSafe was renamed to AndaimeStrictSafe
import andaime;
string getUser(long id) @safe => "x";
void main() { auto app = new App; app.get!("/users/{id}", getUser); }
