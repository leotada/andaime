// EXPECT: parameter 'page' is PatchField!int; PatchField is for fields of a JSON body DTO
import andaime;
@safe:
string list(PatchField!int page) => "x";
void main() { auto app = new App; app.get!("/l", list); }
