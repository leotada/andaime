// EXPECT: handler 'byId' em GET /items/{id}: o parâmetro 'id' vem da rota ({id}) e precisa ser escalar
import vela;
struct Key { long v; }
final class Items { @Get("/items/{id}") string byId(Key id) => "x"; }
void main() { auto app = new App; app.mount(new Items); }
