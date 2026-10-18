// EXPECT: unclosed '{' in route "/users/{id"
import andaime;
@safe:
string getUser(long id) => "x";
void main() { auto app = new App; app.get!("/users/{id", getUser); }
