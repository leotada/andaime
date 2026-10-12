// EXPECT: the route declares {id}, but the function has no parameter named 'id'
import vela;
string getUser(long userId) => "x";
void main() { auto app = new App; app.get!("/users/{id}", getUser); }
