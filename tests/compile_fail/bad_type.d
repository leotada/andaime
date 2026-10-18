// EXPECT: parameter 'filter' has type 'int[string]', which andaime cannot extract
import andaime;
@safe:
string search(int[string] filter) => "x";
void main() { auto app = new App; app.get!("/search", search); }
