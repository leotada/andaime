// EXPECT: vela: a log field key must be a string, but key 1 is 'int'
import vela;
@safe:
void main() { logWarn("x", 1, 2); }
