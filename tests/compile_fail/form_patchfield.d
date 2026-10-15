// EXPECT: field 'nick' of Upd is PatchField!string; PatchField is for JSON bodies (a form has no null): use Optional!T
import vela;
@safe:
struct Upd { PatchField!string nick; }
string upd(Form!Upd f) => "x";
void main() { auto app = new App; app.post!("/u", upd); }
