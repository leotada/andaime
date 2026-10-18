/// Where templates come from: the built-in ones, compiled into the program from `cli/templates/<name>/` (each lists its
/// files in a `MANIFEST`), a folder given to `andaime new --template`, and a project's own overrides in
/// `.andaime/templates/<template>/`.
///
/// A template is a folder of generators: `new/` makes a project, and `resource/`, `usecase/`, `job/`, `install-jobs/`...
/// grow it. Each generator has a `generator.json` (see `andaime.cli.generator`) and the files it renders.
module andaime.cli.templates;

@safe:

import andaime.cli.generator : Files;

/// The templates compiled into the program.
immutable string[] builtinTemplates = ["clean", "minimal"];

/// The files of a built-in template, or null when there is no such template.
Files builtinTemplate(string name)
{
    static foreach (t; builtinTemplates)
        if (name == t)
            return embedded!t();
    return null;
}

private Files embedded(string name)()
{
    Files files;
    static foreach (path; manifestLines(import(name ~ "/MANIFEST")))
        files[path] = import(name ~ "/" ~ path);
    return files;
}

/// The paths a `MANIFEST` lists: one per line; blank lines and `#` comments are skipped. Runs at compile time.
string[] manifestLines(string text) pure
{
    string[] paths;
    size_t from;
    foreach (i; 0 .. text.length + 1)
    {
        if (i < text.length && text[i] != '\n')
            continue;
        auto line = text[from .. i];
        from = i + 1;
        while (line.length && (line[$ - 1] == ' ' || line[$ - 1] == '\r'))
            line = line[0 .. $ - 1];
        if (line.length && line[0] != '#')
            paths ~= line;
    }
    return paths;
}

/// Every file under `dir`, by path relative to it (with `/` separators).
Files readFolder(string dir) @trusted
{
    import std.file : dirEntries, exists, isDir, readText, SpanMode;
    import std.path : relativePath;
    import std.array : replace;

    Files files;
    if (!exists(dir) || !isDir(dir))
        return files;
    foreach (e; dirEntries(dir, SpanMode.depth))
        if (e.isFile)
            files[relativePath(e.name, dir).replace("\\", "/")] = readText(e.name);
    return files;
}

/// The template a project uses: the built-in one named `name`, or the folder `name` (relative to the project) when it is
/// not one; then the project's `.andaime/templates/<base name>/` files replace those with the same path.
Files projectTemplate(string projectRoot, string name)
{
    import std.path : baseName, buildPath, isAbsolute;

    auto files = builtinTemplate(name);
    if (files is null)
    {
        auto dir = isAbsolute(name) ? name : buildPath(projectRoot, name);
        files = readFolder(dir);
        if (files.length == 0)
            throw new Exception("andaime: there is no template '" ~ name ~ "' (built in: clean, minimal; or a folder)");
    }
    foreach (path, text; readFolder(buildPath(projectRoot, ".andaime", "templates", baseName(name))))
        files[path] = text;
    return files;
}

unittest
{
    assert(manifestLines("a\n# comment\n\nb/c.tpl \r\nd") == ["a", "b/c.tpl", "d"]);
    enum ct = manifestLines("x\ny\n");
    static assert(ct == ["x", "y"]);
    foreach (t; builtinTemplates)
    {
        auto files = builtinTemplate(t);
        assert(files.length > 0 && "new/generator.json" in files, t);
    }
    assert(builtinTemplate("nope") is null);
}
