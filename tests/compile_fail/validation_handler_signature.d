// EXPECT: andaime: onValidationError takes a function (Context ctx, ValidationErrors errors) returning void
import andaime;
@safe:
void main() { auto app = new App; app.onValidationError((Context ctx) { ctx.text("x", 400); }); }
