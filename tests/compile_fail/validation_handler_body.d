// EXPECT: vela: onValidationError!(string): the error body type must be a struct
import vela;
@safe:
void main() { auto app = new App; app.onValidationError!string(400, (Context ctx, ValidationErrors e) {}); }
