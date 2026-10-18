/// The app as a whole.
module tests.app;

@safe:

import andaime;
import andaime.web.testing;
import app : buildAppWith, memoryAdapters;

unittest // the app builds over in-memory adapters and documents itself
{
    auto c = TestClient(buildAppWith(memoryAdapters()));
    auto r = c.get("/openapi.json");
    assert(r.status == 200, r.body);
}
