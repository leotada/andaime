/// `copyAs!Dst(src)`: a new `Dst` whose fields come from the fields of `src` with the same name and type, checked at
/// compile time. For the edge of a layer where a domain type and a DTO (or a row) have almost the same shape: write the
/// two structs, not the field-by-field copy.
///
///     struct User { long id; string name; string email; string passwordHash; }
///     struct UserOut { long id; string name; string email; }
///     auto dto = copyAs!UserOut(user);    // id, name, email; passwordHash stays behind
///
/// A field of `Dst` with no match in `Src` is a one-line compile error naming it; fields of `Src` that `Dst` lacks are
/// left out.
module andaime.values.copy 2025;

@safe:

/// See the module.
Dst copyAs(Dst, Src)(auto ref Src src) if (is(Dst == struct) && is(Src == struct))
{
    enum string err = copyAsError!(Dst, Src);
    static assert(err.length == 0, err);
    Dst d;
    static foreach (i; 0 .. Dst.tupleof.length)
        d.tupleof[i] = __traits(getMember, src, __traits(identifier, Dst.tupleof[i]));
    return d;
}

/// The one-line reason `copyAs!Dst(Src)` does not compile, or "".
template copyAsError(Dst, Src)
{
    enum string copyAsError = () {
        static foreach (i; 0 .. Dst.tupleof.length)
        {{
            enum name = __traits(identifier, Dst.tupleof[i]);
            static if (!__traits(hasMember, Src, name))
                return "andaime: copyAs!(" ~ Dst.stringof ~ ", " ~ Src.stringof ~ "): field '" ~ name ~ "' of "
                    ~ Dst.stringof ~ " has no field of the same name in " ~ Src.stringof;
            else static if (!is(typeof(__traits(getMember, Src.init, name)) == typeof(Dst.tupleof[i])))
                return "andaime: copyAs!(" ~ Dst.stringof ~ ", " ~ Src.stringof ~ "): field '" ~ name ~ "' is "
                    ~ typeof(Dst.tupleof[i]).stringof ~ " in " ~ Dst.stringof ~ " but "
                    ~ typeof(__traits(getMember, Src.init, name)).stringof ~ " in " ~ Src.stringof
                    ~ "; convert it by hand";
        }}
        return "";
    }();
}

@safe unittest
{
    struct User { long id; string name; string email; string passwordHash; }
    struct UserOut { string email; long id; string name; }
    auto u = User(7, "Ana", "a@x.com", "secret");
    auto o = copyAs!UserOut(u);
    assert(o == UserOut("a@x.com", 7, "Ana"), "by name, whatever the order");

    struct Wider { long id; string nickname; }
    static assert(copyAsError!(Wider, User)
        == "andaime: copyAs!(Wider, User): field 'nickname' of Wider has no field of the same name in User");
    struct Narrower { int id; }
    static assert(copyAsError!(Narrower, User)
        == "andaime: copyAs!(Narrower, User): field 'id' is int in Narrower but long in User; convert it by hand");
    static assert(!__traits(compiles, copyAs!Wider(u)));
}
