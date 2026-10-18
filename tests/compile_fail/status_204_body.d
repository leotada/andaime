// EXPECT: @status(204) means a response with no body, but the handler returns 'string'; return void
import andaime;
@safe:
@status(204) string getUser() => "x";
void main() { auto app = new App; app.get!("/users", getUser); }
