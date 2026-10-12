// EXPECT: o parâmetro 'id' vem da rota ({id}) e precisa ser escalar (int, long, string, bool, enum...), mas é 'Dto'
import vela;
struct Dto { long v; }
string getUser(Dto id) => "x";
void main() { auto app = new App; app.get!("/users/{id}", getUser); }
