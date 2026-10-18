/// The query of a list endpoint: `?limit=20&offset=40`.
module adapters.http.paging;

@safe:

import andaime;

/// A page of a list. Out-of-range values are a 422, and both appear in the OpenAPI document.
struct Page
{
    @inRange(1, 100) int limit = 20;
    @optional @inRange(0, int.max) int offset;
}
