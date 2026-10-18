// EXPECT: andaime: log fields come in pairs ("key", value), but 3 were given
import andaime;
@safe:
void main() { logInfo("created", "id", 7, "plan"); }
