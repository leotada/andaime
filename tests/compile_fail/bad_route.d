// EXPECT: chave '{' sem '}' na rota "/users/{id"
import vela;
string getUser(long id) => "x";
void main() { auto app = new App; app.get!("/users/{id", getUser); }
