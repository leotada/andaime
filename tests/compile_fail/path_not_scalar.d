// EXPECT: parameter 'id' comes from the route ({id}) and must be a scalar (int, long, string, bool, enum...), but it is 'Dto'
import vela;
@safe:
struct Dto { long v; }
string getUser(Dto id) => "x";
void main() { auto app = new App; app.get!("/users/{id}", getUser); }
