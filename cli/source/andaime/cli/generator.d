/// Runs a generator of a template. A generator is a folder with a `generator.json` and the files it renders:
///
/// ```json
/// {
///   "create":  [ { "tree": "files" },
///                { "path": "source/domain/{{plural}}.d", "from": "domain.d.tpl", "if": "pg" } ],
///   "append":  [ { "path": "source/usecases/{{feature}}.d", "from": "usecase.d.tpl",
///                  "header": "usecases_header.d.tpl", "unless": "class {{Name}}" } ],
///   "insert":  [ { "path": "source/app.d", "marker": "// andaime:mount", "from": "mount.d.tpl" } ],
///   "replace": [ { "path": "source/main.d", "text": "serve(&buildApp, cfg);", "with": "serveWithJobs(args, cfg);" } ]
/// }
/// ```
///
/// - `create` writes a new file (`tree` creates every file under that folder of the generator, without its `.tpl`). A
///   file that exists stops the whole run, unless `--force`.
/// - `append` adds to the end of a file (created from `header` when missing), unless it already contains `unless`.
/// - `insert` puts the text before the line holding `marker`, with that line's indentation; text already in the file is
///   not inserted twice.
/// - `replace` changes the first `text` into `with`.
/// - `if` (any action) names a flag; `!flag` is its opposite. `text` may replace `from` with inline text, and a `from`
///   starting with `../` names a file of another generator of the same template.
///
/// Paths, file contents, `unless`, `text` and `with` are templates (`andaime.cli.mustache`). Nothing is written unless
/// every `create` can be done. When a marker or a replaced text is missing, the change is printed for the user to make.
module andaime.cli.generator;

import andaime.cli.mustache;

import std.algorithm : canFind, startsWith;
import std.array : join, split;
import std.file : exists, mkdirRecurse, readText, write;
import std.format : format;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : buildPath, dirName, isAbsolute;
import std.string : indexOf;

/// A template's files: path relative to the template's folder (`resource/domain.d.tpl`) -> contents.
alias Files = string[string];

struct GenOptions
{
    bool dryRun; /// report only
    bool force;  /// overwrite the files `create` would write
}

/// What a run did.
struct GenResult
{
    string[] report; /// `      create  source/domain/users.d`
    string[] manual; /// changes the user has to make by hand
}

/// Runs the generator `name` of the template `tpl` in the project at `root`.
GenResult runGenerator(Files tpl, string name, string root, Scope vars, GenOptions opt) @trusted
{
    auto specText = name ~ "/generator.json" in tpl;
    if (specText is null)
        throw new Exception("andaime: this template has no '" ~ name ~ "' generator");
    auto spec = parseJSON(*specText);

    GenResult result;
    string[string] pending; // path -> new contents
    string[] order;         // paths in the order they were first touched
    string[] existing;

    void note(string verb, string path)
    {
        result.report ~= format("%12s  %s", verb, path);
    }

    void put(string path, string text)
    {
        if (path !in pending)
            order ~= path;
        pending[path] = text;
    }

    bool hasFile(string path) => (path in pending) !is null || exists(buildPath(root, path));

    string current(string path) => path in pending ? pending[path] : readText(buildPath(root, path));

    string file(string from)
    {
        auto key = from.startsWith("../") ? from[3 .. $] : name ~ "/" ~ from; // `../usecase/x.tpl`: another generator's

        auto p = key in tpl;
        if (p is null)
            throw new Exception("andaime: generator '" ~ name ~ "' refers to a missing file: " ~ from);
        return render(*p, vars, key);
    }

    string body(JSONValue entry)
    {
        if (auto t = "text" in entry.object)
            return render(t.str, vars, name ~ "/generator.json");
        return file(entry["from"].str);
    }

    bool wanted(JSONValue entry)
    {
        auto c = "if" in entry.object;
        if (c is null)
            return true;
        auto flag = c.str;
        immutable negate = flag.startsWith("!");
        if (negate)
            flag = flag[1 .. $];
        auto v = flag in vars.flags;
        if (v is null)
            throw new Exception("andaime: generator '" ~ name ~ "': the condition '" ~ c.str ~ "' is not a flag");
        return *v != negate;
    }

    string target(JSONValue entry)
    {
        auto path = render(entry["path"].str, vars, name ~ "/generator.json");
        checkPath(path);
        return path;
    }

    foreach (entry; actions(spec, "create"))
    {
        if (!wanted(entry))
            continue;
        string[2][] files; // [path, contents]
        if (auto tree = "tree" in entry.object)
        {
            auto prefix = name ~ "/" ~ tree.str ~ "/";
            foreach (path; sortedKeys(tpl))
                if (path.startsWith(prefix))
                {
                    auto rel = path[prefix.length .. $];
                    if (rel.length > 4 && rel[$ - 4 .. $] == ".tpl")
                        rel = rel[0 .. $ - 4];
                    auto out_ = render(rel, vars, path);
                    checkPath(out_);
                    files ~= [out_, render(tpl[path], vars, path)];
                }
        }
        else
            files ~= [target(entry), body(entry)];
        foreach (f; files)
        {
            if (hasFile(f[0]) && !opt.force)
                existing ~= f[0];
            put(f[0], f[1]);
            note("create", f[0]);
        }
    }
    if (existing.length)
        throw new Exception("andaime: these files exist; nothing was written (--force overwrites them):\n  "
            ~ existing.join("\n  "));

    foreach (entry; actions(spec, "append"))
    {
        if (!wanted(entry))
            continue;
        auto path = target(entry);
        string text;
        bool fresh;
        if (hasFile(path))
            text = current(path);
        else if (auto h = "header" in entry.object)
        {
            text = file(h.str);
            fresh = true;
        }
        else
        {
            result.manual ~= path ~ " does not exist; nothing was appended to it";
            continue;
        }
        if (auto u = "unless" in entry.object)
            if (text.canFind(render(u.str, vars, name ~ "/generator.json")))
            {
                note("identical", path);
                put(path, text);
                continue;
            }
        if (text.length && text[$ - 1] != '\n')
            text ~= '\n';
        put(path, text ~ body(entry));
        note(fresh ? "create" : "append", path);
    }

    foreach (entry; actions(spec, "insert"))
    {
        if (!wanted(entry))
            continue;
        auto path = target(entry);
        auto text = body(entry);
        auto marker = entry["marker"].str;
        if (!hasFile(path))
        {
            result.manual ~= "add to " ~ path ~ " (it does not exist):\n" ~ text;
            continue;
        }
        auto old = current(path);
        auto at = lineStartOf(old, marker);
        if (at < 0)
        {
            result.manual ~= "add to " ~ path ~ " (it has no '" ~ marker ~ "' line):\n" ~ text;
            continue;
        }
        auto indent = old[at .. $][0 .. old[at .. $].indexOf(marker)];
        auto indented = indentLines(text, indent);
        if (old.canFind(indented))
        {
            note("identical", path);
            continue;
        }
        put(path, old[0 .. at] ~ indented ~ old[at .. $]);
        note("insert", path);
    }

    foreach (entry; actions(spec, "replace"))
    {
        if (!wanted(entry))
            continue;
        auto path = target(entry);
        auto from = render(entry["text"].str, vars, name ~ "/generator.json");
        auto to = render(entry["with"].str, vars, name ~ "/generator.json");
        auto old = hasFile(path) ? current(path) : null;
        auto at = old.indexOf(from);
        if (at >= 0)
        {
            put(path, old[0 .. at] ~ to ~ old[at + from.length .. $]);
            note("replace", path);
        }
        else if (old.canFind(to))
            note("identical", path);
        else
            result.manual ~= "in " ~ path ~ ", replace\n  " ~ from ~ "\nwith\n  " ~ to;
    }

    if (!opt.dryRun)
        foreach (path; order)
        {
            auto full = buildPath(root, path);
            mkdirRecurse(dirName(full));
            write(full, pending[path]);
        }
    return result;
}

private JSONValue[] actions(JSONValue spec, string kind) @trusted
{
    auto p = kind in spec.object;
    if (p is null)
        return null;
    if (p.type != JSONType.array)
        throw new Exception("andaime: generator.json: '" ~ kind ~ "' must be a list");
    return p.array;
}

private string[] sortedKeys(Files files)
{
    import std.algorithm : sort;

    auto keys = files.keys;
    keys.sort();
    return keys;
}

/// A generated path stays inside the project.
private void checkPath(string path)
{
    if (path.length == 0 || isAbsolute(path) || path.split('/').canFind(".."))
        throw new Exception("andaime: a template wants to write outside the project: '" ~ path ~ "'");
}

/// Where the line that holds `marker` starts, or -1.
private ptrdiff_t lineStartOf(string text, string marker)
{
    auto at = text.indexOf(marker);
    if (at < 0)
        return -1;
    while (at > 0 && text[at - 1] != '\n')
        at--;
    return at;
}

/// `text` with `indent` before each non-empty line.
private string indentLines(string text, string indent)
{
    string o;
    foreach (line; text.split('\n')[0 .. $ - (text.length && text[$ - 1] == '\n' ? 1 : 0)])
        o ~= (line.length ? indent ~ line : line) ~ "\n";
    return o;
}

unittest // create, append, insert at a marker with its indentation, replace, conditions, and no overwrite
{
    import std.file : rmdirRecurse, tempDir;

    auto root = buildPath(tempDir, "andaime_cli_generator_test");
    if (exists(root))
        rmdirRecurse(root);
    scope (exit)
        rmdirRecurse(root);

    Files tpl;
    tpl["new/generator.json"] = `{"create": [{"tree": "files"}]}`;
    tpl["new/files/source/app.d.tpl"] = "module app;\nvoid build()\n{\n    // andaime:mount\n}\n";
    tpl["new/files/README.md"] = "# {{app}}\n";
    tpl["res/generator.json"] = `{
        "create": [{"path": "source/{{plural}}.d", "from": "res.d.tpl"},
                   {"path": "migrations/{{plural}}.sql", "text": "create table {{plural}};", "if": "pg"}],
        "append": [{"path": "NOTES", "header": "notes.tpl", "text": "{{plural}}\n", "unless": "{{plural}}"}],
        "insert": [{"path": "source/app.d", "marker": "// andaime:mount", "text": "mount({{plural}});\n"}],
        "replace": [{"path": "README.md", "text": "# {{app}}", "with": "# {{app}} ({{plural}})"},
                    {"path": "README.md", "text": "absent", "with": "nowhere"}]
    }`;
    tpl["res/res.d.tpl"] = "module {{plural}};\n";
    tpl["res/notes.tpl"] = "notes:\n";

    auto vars = new Scope;
    vars.set("app", "demo").set("plural", "users").flag("pg", false);
    auto r = runGenerator(tpl, "new", root, vars, GenOptions.init);
    assert(readText(buildPath(root, "README.md")) == "# demo\n");

    r = runGenerator(tpl, "res", root, vars, GenOptions.init);
    assert(readText(buildPath(root, "source/users.d")) == "module users;\n");
    assert(!exists(buildPath(root, "migrations")));
    assert(readText(buildPath(root, "NOTES")) == "notes:\nusers\n");
    assert(readText(buildPath(root, "source/app.d")) == "module app;\nvoid build()\n{\n    mount(users);\n    // andaime:mount\n}\n");
    assert(readText(buildPath(root, "README.md")) == "# demo (users)\n");
    assert(r.manual.length == 1 && r.manual[0].canFind("replace\n  absent"));

    // a second run: the created file exists, so nothing at all is written
    bool refused;
    try
        runGenerator(tpl, "res", root, vars, GenOptions.init);
    catch (Exception e)
        refused = e.msg.canFind("source/users.d");
    assert(refused);
    assert(readText(buildPath(root, "NOTES")) == "notes:\nusers\n");

    // --force: written again, and the insert and the append are not repeated
    vars.set("plural", "users").flag("pg", true);
    r = runGenerator(tpl, "res", root, vars, GenOptions(false, true));
    assert(readText(buildPath(root, "source/app.d")).canFind("    mount(users);\n    // andaime:mount"));
    assert(readText(buildPath(root, "source/app.d")).split("mount(users)").length == 2);
    assert(readText(buildPath(root, "NOTES")) == "notes:\nusers\n");
    assert(exists(buildPath(root, "migrations/users.sql")));
}
