/// `tlsAvailable`, `zlibAvailable` and `pgAvailable` (with their `*LoadError`) agree with each other, whether or not the
/// native library is installed here, and the reason names the library.
module runtime_libs;

import andaime;
import andaime.db : pgAvailable, pgLoadError;

@safe:

unittest
{
    assert(tlsAvailable == !tlsLoadError.has);
    if (!tlsAvailable)
    {
        auto why = tlsLoadError.get;
        assert(why.length > 20 && why[0 .. 14] == "andaime.http: ", why);
        assert(why == tlsLoadError.get, "the reason is stable between calls");
    }
}

unittest
{
    assert(zlibAvailable == !zlibLoadError.has);
    if (!zlibAvailable)
    {
        auto why = zlibLoadError.get;
        assert(why.length > 20 && why[0 .. 9] == "andaime: ", why);
    }
}

unittest
{
    assert(pgAvailable == !pgLoadError.has);
    if (!pgAvailable)
    {
        auto why = pgLoadError.get;
        assert(why.length > 20 && why[0 .. 12] == "andaime.db: ", why);
    }
}
