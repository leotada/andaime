// EXPECT: Optional accepts a scalar, Header!"Name", Cookie!"name" or JsonBody!T
import vela;
@safe:
string who(Optional!ClientIp ip) => "x";
void main() { auto app = new App; app.get!("/who", who); }
