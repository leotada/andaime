// EXPECT: matches several fields of Adapters; keep one field of that type or pass the value as an extra argument
import andaime;
@safe:
interface Clock { }
struct Adapters { Clock a; Clock b; }
final class Needs { this(Clock c) {} }
void main() { Adapters a; construct!Needs(a); }
