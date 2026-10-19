/// `andaime check`: the dependency rule. The layers of `andaime.json` say which modules belong to each layer and what each
/// may import; the imports themselves come from the compiler (`-deps`, with `-o-`: nothing is generated), so the check
/// sees exactly what the build sees, including imports inside functions.
module andaime.cli.check;

import std.algorithm : canFind, sort, startsWith;
import std.array : join;
import std.json : JSONValue, JSONType;

@safe:

/// A layer: the modules in it (globs, `*` matches anything) and what they may import (layer names or module globs).
struct Layer
{
    string name;
    string[] modules;
    string[] mayImport;
}

/// The `"layers"` object of `andaime.json`. Their order does not matter: a module belongs to the layer with its most
/// specific (longest) matching glob.
Layer[] parseLayers(JSONValue json) @trusted
{
    Layer[] layers;
    auto p = "layers" in json.object;
    if (p is null)
        return layers;
    foreach (name, value; p.object)
    {
        Layer l;
        l.name = name;
        foreach (m; value["modules"].array)
            l.modules ~= m.str;
        if (auto mi = "may_import" in value.object)
            foreach (m; mi.array)
                l.mayImport ~= m.str;
        layers ~= l;
    }
    return layers;
}

/// A module glob: `*` matches any run of characters (dots included), and `x.*` also matches `x` itself (`andaime.*`
/// covers `import andaime;`).
bool moduleMatch(string pattern, string mod) pure nothrow
{
    if (pattern.length > 2 && pattern[$ - 2 .. $] == ".*" && mod == pattern[0 .. $ - 2])
        return true;
    return globMatch(pattern, mod);
}

/// `*` matches any run of characters (dots included); everything else matches itself.
bool globMatch(string pattern, string s) pure nothrow
{
    if (pattern.length == 0)
        return s.length == 0;
    if (pattern[0] == '*')
    {
        foreach (i; 0 .. s.length + 1)
            if (globMatch(pattern[1 .. $], s[i .. $]))
                return true;
        return false;
    }
    return s.length && s[0] == pattern[0] && globMatch(pattern[1 .. $], s[1 .. $]);
}

/// The layer `mod` belongs to: the one with the most specific matching glob (the longest), or "".
string layerOf(const Layer[] layers, string mod) pure nothrow
{
    string best;
    size_t bestLength;
    foreach (l; layers)
        foreach (g; l.modules)
            if (moduleMatch(g, mod) && (best.length == 0 || g.length > bestLength))
            {
                best = l.name;
                bestLength = g.length;
            }
    return best;
}

/// druntime and Phobos, always allowed.
bool isRuntime(string mod) pure nothrow
{
    foreach (root; ["object", "core", "std", "etc", "ldc", "gcc"])
        if (mod == root || (mod.length > root.length && mod[0 .. root.length] == root && mod[root.length] == '.'))
            return true;
    return false;
}

/// One import: `from` imports `to`.
struct Import
{
    string from;
    string to;
}

/// The imports in the output of `-deps`: lines `A (file) : private : B (file)[:names]`, which `-deps=<file>` writes, or
/// the same with a `depsImport ` prefix on stdout (where `depsVersion`, `depsFile`... lines come too).
Import[] parseDeps(string text) pure
{
    import std.string : indexOf, lineSplitter, strip;

    Import[] found;
    foreach (line; text.lineSplitter)
    {
        auto rest = line;
        if (rest.startsWith("depsImport "))
            rest = rest["depsImport ".length .. $];
        else if (rest.length > 4 && rest[0 .. 4] == "deps" && rest[4] >= 'A' && rest[4] <= 'Z')
            continue;
        auto sp = rest.indexOf(' ');
        if (sp < 0)
            continue;
        auto from = rest[0 .. sp];
        auto c1 = rest.indexOf(" : ");
        if (c1 < 0)
            continue;
        auto afterProt = rest[c1 + 3 .. $];
        auto c2 = afterProt.indexOf(" : ");
        if (c2 < 0)
            continue;
        auto target = afterProt[c2 + 3 .. $];
        auto sp2 = target.indexOf(' ');
        auto to = (sp2 < 0 ? target : target[0 .. sp2]).strip;
        found ~= Import(from.idup, to.idup);
    }
    return found;
}

/// One line per broken rule, sorted, each starting with `andaime check:`. `ours` are the project's modules: only their
/// imports are checked.
string[] violations(const Layer[] layers, const Import[] imports, const bool[string] ours)
{
    bool[string] seen;
    string[] lines;
    foreach (mod; ours.byKey)
        if (layerOf(layers, mod).length == 0)
            lines ~= "andaime check: " ~ mod ~ " is in no layer of andaime.json";
    foreach (imp; imports)
    {
        if ((imp.from in ours) is null || imp.from == imp.to || isRuntime(imp.to))
            continue;
        auto fromLayer = layerOf(layers, imp.from);
        if (fromLayer.length == 0)
            continue; // already reported
        auto toLayer = layerOf(layers, imp.to);
        if (toLayer == fromLayer)
            continue;
        const(string)[] allowed;
        foreach (l; layers)
            if (l.name == fromLayer)
                allowed = l.mayImport;
        bool ok;
        foreach (a; allowed)
        {
            bool isLayer;
            foreach (l; layers)
                isLayer |= l.name == a;
            ok |= isLayer ? toLayer == a : moduleMatch(a, imp.to);
        }
        if (ok)
            continue;
        auto key = imp.from ~ " " ~ imp.to;
        if (key in seen)
            continue;
        seen[key] = true;
        lines ~= "andaime check: " ~ imp.from ~ " imports " ~ imp.to ~ " (" ~ fromLayer ~ " may import: "
            ~ (allowed.length ? allowed.join(", ") : "only its own layer") ~ ")";
    }
    lines.sort();
    return lines;
}

unittest // globs and layers
{
    assert(moduleMatch("domain.*", "domain.users") && moduleMatch("domain.*", "domain.a.b"));
    assert(moduleMatch("andaime.*", "andaime") && !moduleMatch("andaime.*", "andaimex"));
    assert(moduleMatch("*", "anything") && moduleMatch("andaime.http.optional", "andaime.http.optional"));
    assert(!moduleMatch("jobs", "andaime.jobs") && moduleMatch("*.users", "domain.users"));
    auto layers = [Layer("domain", ["domain.*"], ["andaime.http.optional"]), Layer("main", ["app", "jobs"], ["*"]),
        Layer("adapters", ["adapters.*"], ["domain", "andaime.*"])];
    assert(layerOf(layers, "domain.users") == "domain" && layerOf(layers, "jobs") == "main");
    assert(layerOf(layers, "andaime.jobs") == "");
    assert(isRuntime("std.stdio") && isRuntime("object") && isRuntime("core.time") && !isRuntime("stdx.allocator"));

    // an application whose modules share a package prefix (docs/architecture.md, "Growing")
    auto prefixed = [Layer("domain", ["visto.domain.*"], ["andaime.values.*"]),
        Layer("usecases", ["visto.usecases.*"], ["domain", "andaime.values.*"]), Layer("main", ["visto.*"], ["*"])];
    assert(layerOf(prefixed, "visto.domain.users") == "domain" && layerOf(prefixed, "visto.usecases.users") == "usecases");
    assert(layerOf(prefixed, "visto.app") == "main", "the longest matching glob wins");
    assert(moduleMatch("andaime.values.*", "andaime.values.uuid") && !moduleMatch("andaime.values.*", "andaime.web"));
}

unittest // -deps lines and the violations they make
{
    auto deps = "depsImport domain.users (source/domain/users.d) : private : object (/usr/include/object.d)\n"
        ~ "depsImport domain.users (source/domain/users.d) : private : andaime.web.application (web/x.d):App\n"
        ~ "depsImport domain.users (source/domain/users.d) : private : andaime.http.optional (http/o.d)\n"
        ~ "depsImport domain.users (source/domain/users.d) : private : andaime.web.application (web/x.d):HttpError\n"
        ~ "depsImport adapters.http.users (source/a.d) : private : domain.users (source/domain/users.d)\n"
        ~ "depsImport adapters.http.users (source/a.d) : private : andaime (source/andaime/package.d)\n"
        ~ "depsImport adapters.http.users (source/a.d) : private : app (source/app.d)\n"
        ~ "depsImport andaime (source/andaime/package.d) : public : vibe.d (x.d)\n"
        ~ "stray (source/stray.d) : private static : std.stdio (x.d)\n" // the -deps=<file> form
        ~ "depsVersion andaime.web.handler_traits (x.d) : AndaimeStrictSafe\n";
    auto imports = parseDeps(deps);
    assert(imports.length == 9 && imports[1] == Import("domain.users", "andaime.web.application"));
    assert(imports[8] == Import("stray", "std.stdio"));
    auto layers = [Layer("domain", ["domain.*"], ["andaime.http.optional"]),
        Layer("adapters", ["adapters.*"], ["domain", "andaime.*"]), Layer("main", ["app"], ["*"])];
    bool[string] ours = ["domain.users": true, "adapters.http.users": true, "app": true, "stray": true];
    assert(violations(layers, imports, ours) == [
        "andaime check: adapters.http.users imports app (adapters may import: domain, andaime.*)",
        "andaime check: domain.users imports andaime.web.application (domain may import: andaime.http.optional)",
        "andaime check: stray is in no layer of andaime.json",
    ]);
}
