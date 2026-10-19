// EXPECT: andaime: copyAs!(UserOut, User): field 'nickname' of UserOut has no field of the same name in User
import andaime;
struct User { long id; string name; }
struct UserOut { long id; string nickname; }
void main() { auto o = copyAs!UserOut(User(1, "a")); }
