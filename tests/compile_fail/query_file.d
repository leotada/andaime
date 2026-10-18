// EXPECT: fields must be scalars (int, string, enum, bool...), text types, Optional of those, or lists of scalars
import andaime;
@safe:
struct Filters { UploadedFile file; }
string f(Query!Filters q) => "x";
void main() { auto app = new App; app.get!("/f", f); }
