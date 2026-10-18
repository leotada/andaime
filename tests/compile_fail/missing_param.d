// EXPECT: the route declares {id}, but the function has no parameter named 'id'
import andaime;
@safe:
string getUser(long userId) => "x";
void main() { auto app = new App; app.get!("/users/{id}", getUser); }
