// EXPECT: parameter 'id' cannot be 'ref'; take it by value
import vela;
string getUser(ref long id) => "x";
void main() { auto app = new App; app.get!("/users/{id}", getUser); }
