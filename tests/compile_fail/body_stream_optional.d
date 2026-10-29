// EXPECT: is Optional!BodyStream; take BodyStream (an empty body reads as 0 bytes)
import andaime;
@safe:
string f(Optional!BodyStream b) => "x";
void main() { auto app = new App; app.post!("/f", f); }
