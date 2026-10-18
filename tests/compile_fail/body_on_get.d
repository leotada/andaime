// EXPECT: parameter 'body' is JsonBody, but GET has no body; use POST, PUT or PATCH
import andaime;
@safe:
struct Dto { string name; }
string create(JsonBody!Dto body) => body.name;
void main() { auto app = new App; app.get!("/users", create); }
