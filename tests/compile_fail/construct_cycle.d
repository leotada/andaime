// EXPECT: the constructor parameters form a cycle
import andaime;
@safe:
struct Adapters { int x; }
final class A { this(B b) {} }
final class B { this(A a) {} }
void main() { Adapters a; construct!A(a); }
