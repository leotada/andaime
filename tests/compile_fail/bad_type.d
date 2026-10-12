// EXPECT: parameter 'filter' has type 'int[string]', which vela cannot extract
import vela;
string search(int[string] filter) => "x";
void main() { auto app = new App; app.get!("/search", search); }
