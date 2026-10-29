// EXPECT: more than one body parameter (JsonBody, Form or BodyStream); merge the fields into a single DTO
import andaime;
@safe:
struct Dto { string name; }
string f(JsonBody!Dto d, BodyStream b) => "x";
void main() { auto app = new App; app.post!("/f", f); }
