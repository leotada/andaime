// EXPECT: andaime: onValidationError!(string): the error body type must be a struct
import andaime;
@safe:
void main() { auto app = new App; app.onValidationError!string(400, (Context ctx, ValidationErrors e) {}); }
