// EXPECT: andaime: a log field key must be a string, but key 1 is 'int'
import andaime;
@safe:
void main() { logWarn("x", 1, 2); }
