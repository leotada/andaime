// EXPECT: vela: onValidationError takes a function (Context ctx, ValidationErrors errors) returning void
import vela;
@safe:
void main() { auto app = new App; app.onValidationError((Context ctx) { ctx.text("x", 400); }); }
