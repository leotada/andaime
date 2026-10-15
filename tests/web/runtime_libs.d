/// `tlsAvailable`, `zlibAvailable` and `pgAvailable` (with their `*LoadError`) agree with each other, whether or not the
/// native library is installed here, and the reason names the library.
module runtime_libs;

import vela;
import vela.db : pgAvailable, pgLoadError;

@safe:

unittest
{
    assert(tlsAvailable == !tlsLoadError.has);
    if (!tlsAvailable)
    {
        auto why = tlsLoadError.get;
        assert(why.length > 20 && why[0 .. 11] == "vela.http: ", why);
        assert(why == tlsLoadError.get, "the reason is stable between calls");
    }
}

unittest
{
    assert(zlibAvailable == !zlibLoadError.has);
    if (!zlibAvailable)
    {
        auto why = zlibLoadError.get;
        assert(why.length > 20 && why[0 .. 6] == "vela: ", why);
    }
}

unittest
{
    assert(pgAvailable == !pgLoadError.has);
    if (!pgAvailable)
    {
        auto why = pgLoadError.get;
        assert(why.length > 20 && why[0 .. 9] == "vela.db: ", why);
    }
}
