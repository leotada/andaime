// EXPECT: o parâmetro 'filtro' tem tipo 'int[string]', que o vela não sabe extrair
import vela;
string busca(int[string] filtro) => "x";
void main() { auto app = new App; app.get!("/busca", busca); }
