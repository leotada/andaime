// EXPECT: o retorno 'int*' não é suportado
import vela;
int* getUser(long id) => null;
void main() { auto app = new App; app.get!("/users/{id}", getUser); }
