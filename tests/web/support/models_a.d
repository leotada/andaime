/// Support module for tests/web/openapi_names.d: a `User` that collides with models_b.User.
module support.models_a;

struct User { long id; }
struct Page(T) { T[] items; }
