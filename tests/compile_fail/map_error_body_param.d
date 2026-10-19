// EXPECT: andaime: mapError!NotFound takes a function (NotFound e) returning a struct, not
import andaime;
class NotFound : Exception { this() { super("x"); } }
struct ApiError { string message; }
void main() { auto app = new App; app.mapError!NotFound(404, (int code) => ApiError("x")); }
