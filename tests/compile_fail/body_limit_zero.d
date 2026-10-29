// EXPECT: @bodyLimit(0): a body limit must be at least 1 byte
import andaime;
@safe:
@bodyLimit(0) string f(Context c) => "x";
void main() { auto app = new App; app.post!("/f", f); }
