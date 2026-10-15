// EXPECT: vela: log fields come in pairs ("key", value), but 3 were given
import vela;
@safe:
void main() { logInfo("created", "id", 7, "plan"); }
