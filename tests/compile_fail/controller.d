// EXPECT: handler 'byId' in GET /items/{id}: parameter 'id' comes from the route ({id}) and must be a scalar
import vela;
struct Key { long v; }
final class Items { @Get("/items/{id}") string byId(Key id) => "x"; }
void main() { auto app = new App; app.mount(new Items); }
