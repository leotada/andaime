// EXPECT: whose fromString does not take its text as `scope`
import andaime;
@safe:
struct BadId
{
    const(char)[] raw;
    static bool fromString(const(char)[] s, out BadId v) { v.raw = s; return true; }
    void toString(scope void delegate(scope const(char)[]) @safe sink) const { sink(raw); }
}
string f(Optional!BadId id) => "x";
void main() { auto app = new App; app.get!("/f", f); }
