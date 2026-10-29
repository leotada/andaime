// EXPECT: is BodyStream, but GET has no body; use POST, PUT or PATCH
import andaime;
@safe:
string f(BodyStream b) => "x";
void main() { auto app = new App; app.get!("/f", f); }
