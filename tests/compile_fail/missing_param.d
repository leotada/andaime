// EXPECT: a rota declara {id}, mas a função não tem parâmetro chamado 'id'
import vela;
string getUser(long userId) => "x";
void main() { auto app = new App; app.get!("/users/{id}", getUser); }
