// EXPECT: has several constructors; construct needs exactly one
import andaime;
@safe:
struct Adapters { int x; }
final class Two { this(int a) {} this(string s) {} }
void main() { Adapters a; construct!Two(a); }
