// FLAGS: -version=AndaimeNamingSnakeCase -version=AndaimeNamingCamelCase
// EXPECT: andaime: more than one AndaimeNaming* version is set; keep one
import andaime;
struct User { long id; }
void main() { auto app = new App; }
