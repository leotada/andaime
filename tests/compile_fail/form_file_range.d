// EXPECT: @inRange does not apply to UploadedFile
import andaime;
@safe:
struct Profile { @inRange(0, 1) UploadedFile avatar; }
string f(Form!Profile p) => "x";
void main() { auto app = new App; app.post!("/f", f); }
