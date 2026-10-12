// EXPECT: o handler não tem tipo concreto. Se for um lambda, declare os tipos dos parâmetros
import vela;
void main() { auto app = new App; app.get!("/users/{id}", (id) => "x"); }
