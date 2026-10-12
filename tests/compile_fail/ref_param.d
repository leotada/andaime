// EXPECT: o parâmetro 'id' não pode ser 'ref'; receba por valor
import vela;
string getUser(ref long id) => "x";
void main() { auto app = new App; app.get!("/users/{id}", getUser); }
