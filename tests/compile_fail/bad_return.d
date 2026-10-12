// EXPECT: the return type 'int*' is not supported
import vela;
int* getUser(long id) => null;
void main() { auto app = new App; app.get!("/users/{id}", getUser); }
