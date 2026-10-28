// EXPECT: andaime: construct!Needs: parameter 'secret' (string) has no value: add a field of that type to Adapters or pass it as an extra argument
import andaime;
@safe:
struct Adapters { int x; }
final class Needs { this(string secret) {} }
void main() { Adapters a; construct!Needs(a); }
