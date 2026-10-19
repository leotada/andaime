// EXPECT: andaime: validationMessages takes a function (ref const FieldError e) returning string, not
import andaime;
void main() { auto app = new App; app.validationMessages((int x) => "no"); }
