// EXPECT: the handler has no concrete type. If it is a lambda, declare the parameter types
import andaime;
@safe:
void main() { auto app = new App; app.get!("/users/{id}", (id) => "x"); }
