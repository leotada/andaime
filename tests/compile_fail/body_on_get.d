// EXPECT: o parâmetro 'body' é JsonBody, mas GET não tem corpo; use POST, PUT ou PATCH
import vela;
struct Dto { string name; }
string create(JsonBody!Dto body) => body.name;
void main() { auto app = new App; app.get!("/users", create); }
