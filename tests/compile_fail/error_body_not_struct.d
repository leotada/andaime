// EXPECT: andaime: errorBody: the function must return a struct (it is the JSON body of every error), not 'const(string)'
import andaime;
void main() { auto app = new App; app.errorBody((ref const ErrorInfo e) => e.message); }
