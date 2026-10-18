/// `andaime`: the optional command of the andaime web framework. It creates projects from templates, grows them with
/// generators, lists the routes of any andaime app and checks the dependency rule of a project. The framework never
/// depends on it.
module andaime.cli.main;

import andaime.cli.check;
import andaime.cli.generator;
import andaime.cli.mustache;
import andaime.cli.naming;
import andaime.cli.templates;

import std.algorithm : canFind, filter, map, sort, startsWith;
import std.array : array, join, replace, split;
import std.conv : to;
import std.file : dirEntries, exists, isDir, readText, remove, SpanMode, tempDir;
import std.format : format;
import std.getopt : getopt, GetOptException;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildPath, dirName;
import std.process : Config, environment, execute;
import std.regex : matchFirst, regex;
import std.stdio : stderr, stdout, writeln;
import std.string : lineSplitter, strip;

enum usage = `andaime: the optional command of the andaime web framework

  andaime new <dir> [--template clean|minimal|<folder>] [--db pg|none] [--jobs] [--andaime-path <path>]
  andaime generate resource <name> <field>... [--plural <word>]
  andaime generate usecase <feature> <Name> [<field>...]
  andaime generate job <feature> <Name> [<field>...] [--queue <name>] [--cron "<m h dom mon dow>" | --every <15.minutes>]
  andaime routes [<text>]
  andaime check

A field is name:type, name:type? (may be absent) or name:type:unique, with the types string, int, long, bool and
double; quote a field with ? for the shell. generate takes --dry-run (show the changes, write nothing) and --force
(overwrite the files it creates); g, r, u and j are short for generate, resource, usecase and job. A feature is the
plural of a resource: users, blog_posts.

  new       a project from a template: clean (layers, the default) or minimal (one module)
  generate  grow a project with its template's generators
  routes    every route and its handler (runs the app with ANDAIME_ROUTES=1); <text> filters the lines
  check     the dependency rule: each import against the layers of andaime.json
`;

/// What a new project depends on when it is not given `--andaime-path`: this release series, from the registry.
private enum andaimeVersion = "~>0.1.0";

int main(string[] args)
{
    try
        return run(args);
    catch (NameError e)
        stderr.writeln(e.msg);
    catch (GetOptException e)
        stderr.writeln("andaime: ", e.msg, " (andaime --help)");
    catch (TemplateError e)
        stderr.writeln("andaime: in the template: ", e.msg);
    catch (Exception e)
        stderr.writeln(e.msg);
    return 1;
}

private int run(string[] args)
{
    if (args.length < 2 || ["help", "-h", "--help"].canFind(args[1]))
    {
        stdout.write(usage);
        return args.length < 2 ? 1 : 0;
    }
    auto rest = args[0] ~ args[2 .. $];
    switch (args[1])
    {
        case "new":
            return cmdNew(rest);
        case "generate", "g":
            return cmdGenerate(rest);
        case "routes":
            return cmdRoutes(rest);
        case "check":
            return cmdCheck(rest);
        default:
            throw new Exception("andaime: unknown command '" ~ args[1] ~ "' (andaime --help)");
    }
}

// ---------------------------------------------------------------- the project

/// A project made by `andaime new`: its folder and its `andaime.json`.
struct Project
{
    string root;
    JSONValue json;

    string name() => text("name");
    string templateName() => text("template");
    string db() => text("db");
    string andaimePath() => text("andaime_path");
    bool jobs() => ("jobs" in json.object) !is null && json["jobs"].type == JSONType.true_;

    private string text(string key)
    {
        auto p = key in json.object;
        return p is null || p.type != JSONType.string ? null : p.str;
    }
}

/// The project around the current folder (this folder or a parent holding `andaime.json`).
private Project findProject()
{
    auto dir = absolutePath(".");
    for (;;)
    {
        auto file = buildPath(dir, "andaime.json");
        if (exists(file))
            return Project(dir, parseJSON(readText(file)));
        auto up = dirName(dir);
        if (up == dir)
            throw new Exception("andaime: no andaime.json here or in a parent folder; this command works in a project "
                ~ "made by `andaime new`");
        dir = up;
    }
}

/// The names every generator sees: the project's.
private Scope projectScope(string name, string templateName, string db, string andaimePath, bool jobs)
{
    auto s = new Scope;
    s.set("app", name).set("appSnake", snake(name)).set("template", templateName).set("db", db);
    s.set("andaimePath", andaimePath).flag("pg", db == "pg").flag("jobs", jobs);
    // the attributes of every `dependency "andaime..."` line: a checkout, or the registry
    s.set("andaimeSource", andaimePath.length ? `path="` ~ andaimePath ~ `"` : `version="` ~ andaimeVersion ~ `"`);
    return s;
}

private Scope projectScope(Project p) => projectScope(p.name, p.templateName, p.db, p.andaimePath, p.jobs);

private void print(GenResult r)
{
    foreach (line; r.report)
        writeln(line);
    foreach (m; r.manual)
        stderr.writeln("andaime: do this by hand: ", m);
}

// ---------------------------------------------------------------- new

private int cmdNew(string[] args)
{
    string templateName = "clean", db = "pg", andaimePath;
    bool jobs;
    getopt(args, "template", &templateName, "db", &db, "jobs", &jobs, "andaime-path", &andaimePath);
    if (args.length != 2)
        throw new Exception("andaime: new takes one folder: andaime new <dir> (andaime --help)");
    auto dir = args[1];
    if (exists(dir) && (!isDir(dir) || !dirEntries(dir, SpanMode.shallow).empty))
        throw new Exception("andaime: '" ~ dir ~ "' exists and is not an empty folder");
    if (db != "pg" && db != "none")
        throw new Exception("andaime: --db is pg or none, not '" ~ db ~ "'");
    auto name = baseName(absolutePath(dir));
    if (!matchFirst(name, regex(`^[a-z][a-z0-9_-]*$`)))
        throw new Exception("andaime: the folder's name is the package name, so it is lowercase letters, digits, - and _ "
            ~ "starting with a letter, not '" ~ name ~ "'");

    auto files = builtinTemplate(templateName);
    if (files is null)
    {
        auto folder = absolutePath(templateName);
        files = readFolder(folder);
        if (files.length == 0)
            throw new Exception("andaime: there is no template '" ~ templateName ~ "' (built in: clean, minimal; or a "
                ~ "folder)");
        templateName = folder;
    }

    // `jobs` tells the new files what is coming (the README); the install step itself sets it in andaime.json
    auto vars = projectScope(name, templateName, db, andaimePath, jobs);
    print(runGenerator(files, "new", dir, vars, GenOptions.init));
    if (jobs)
        installJobs(Project(absolutePath(dir), parseJSON(readText(buildPath(dir, "andaime.json")))), GenOptions.init);
    writeln("\nnext: cd ", dir, " && dub test");
    return 0;
}

// ---------------------------------------------------------------- generate

private int cmdGenerate(string[] args)
{
    bool dryRun, force;
    string plural, queue = "default", cron, every;
    getopt(args, "dry-run", &dryRun, "force", &force, "plural", &plural, "queue", &queue, "cron", &cron,
        "every", &every);
    if (args.length < 2)
        throw new Exception("andaime: generate what? resource, usecase or job (andaime --help)");
    auto opt = GenOptions(dryRun, force);
    auto project = findProject();
    auto kind = args[1];
    auto positional = args[2 .. $];
    switch (kind)
    {
        case "resource", "r":
            if (positional.length < 1)
                throw new Exception("andaime: generate resource <name> <field>... (andaime --help)");
            return generateResource(project, positional[0], positional[1 .. $], plural, opt);
        case "usecase", "u":
            if (positional.length < 2)
                throw new Exception("andaime: generate usecase <feature> <Name> [<field>...] (andaime --help)");
            return generateUseCase(project, positional[0], positional[1], positional[2 .. $], opt);
        case "job", "j":
            if (positional.length < 2)
                throw new Exception("andaime: generate job <feature> <Name> [<field>...] (andaime --help)");
            if (cron.length && every.length)
                throw new Exception("andaime: a job takes --cron or --every, not both");
            return generateJob(project, positional[0], positional[1], positional[2 .. $], queue, cron, every, opt);
        default:
            // a template may bring its own generators: they get the project's names and the arguments as arg1, arg2...
            auto vars = projectScope(project);
            foreach (i, a; positional)
                vars.set("arg" ~ (i + 1).to!string, a);
            print(runGenerator(projectTemplate(project.root, project.templateName), kind, project.root, vars, opt));
            return 0;
    }
}

/// The fields as template items, with their values for tests.
private Scope[] fieldItems(Field[] fields)
{
    Scope[] items;
    foreach (f; fields)
    {
        auto s = new Scope;
        s.set("name", f.name).set("column", f.column).set("type", f.dType).set("baseType", f.type);
        s.set("sqlType", f.sqlType).flag("optional", f.optional).flag("unique", f.unique);
        foreach (n; 1 .. 5)
            s.set("sample" ~ n.to!string, f.sample(n)).set("json" ~ n.to!string, f.sampleJson(n));
        items ~= s;
    }
    return items;
}

/// `{"name":"name 1","email":"email 1"}`: field `f` takes sample `pick(f)`; `id` comes first when given.
private string jsonObject(Field[] fields, int delegate(Field) pick, string id = null)
{
    string[] parts;
    if (id.length)
        parts ~= `"id":` ~ id;
    foreach (f; fields)
        parts ~= `"` ~ f.name ~ `":` ~ f.sampleJson(pick(f));
    return "{" ~ parts.join(",") ~ "}";
}

/// `"name 1", "email 1"`: the D values of each field, for a constructor call.
private string dArgs(Field[] fields, int delegate(Field) pick)
{
    return fields.map!(f => f.sample(pick(f))).join(", ");
}

private int generateResource(Project project, string word, string[] specs, string plural, GenOptions opt)
{
    auto n = names(word, plural);
    Field[] fields;
    foreach (spec; specs)
        fields ~= parseField(spec);
    if (fields.length == 0)
        throw new Exception("andaime: a resource needs at least one field: generate resource " ~ word
            ~ " name:string ...");
    auto unique = fields.filter!(f => f.unique).array;

    auto vars = projectScope(project);
    vars.set("name", n.snake).set("Name", n.pascal).set("camel", n.camel).set("plural", n.plural);
    vars.set("Plural", n.pluralPascal).set("pluralCamel", n.pluralCamel).set("path", n.path).set("table", n.plural);
    vars.set("migration", format("%04d", nextMigration(project.root)));
    vars.list("fields", fieldItems(fields)).list("uniqueFields", fieldItems(unique));
    vars.flag("hasUnique", unique.length > 0).flag("hasOptional", fields.canFind!(f => f.optional));
    vars.flag("hasRequired", fields.canFind!(f => !f.optional)).flag("manyUnique", unique.length > 1);
    vars.set("words", n.snake.replace("_", " ")).set("pluralWords", n.plural.replace("_", " "));
    vars.set("PluralWords", pascal(n.plural)[0 .. 1] ~ n.plural.replace("_", " ")[1 .. $]);
    immutable article = "aeio".canFind(n.snake[0]) ? "an" : "a";
    vars.set("a", article).set("A", article == "an" ? "An" : "A");
    vars.set("uniqueText", unique.map!(f => f.column).join(" or "));

    // SQL
    string[] select = ["id"];
    foreach (f; fields)
        select ~= f.column == f.name ? f.column : f.column ~ ` as "` ~ f.name ~ `"`;
    vars.set("selectList", select.join(", "));
    vars.set("insertColumns", fields.map!(f => f.column).join(", "));
    string[] params, sets;
    foreach (i, f; fields)
    {
        params ~= "$" ~ (i + 1).to!string;
        sets ~= f.column ~ " = $" ~ (i + 2).to!string;
    }
    vars.set("insertParams", params.join(", ")).set("updateSets", sets.join(", "));

    // values for the generated tests
    vars.set("body1", jsonObject(fields, f => 1)).set("body2", jsonObject(fields, f => 2));
    vars.set("out1", jsonObject(fields, f => 1, "1")).set("out2", jsonObject(fields, f => 2, "1"));
    vars.set("conflictBody", jsonObject(fields, f => f.unique ? 1 : 2));
    foreach (k; 1 .. 5)
        vars.set("args" ~ k.to!string, dArgs(fields, f => k));
    vars.set("conflictArgs", dArgs(fields, f => f.unique ? 2 : 4));

    auto tpl = projectTemplate(project.root, project.templateName);
    print(runGenerator(tpl, "resource", project.root, vars, opt));
    return 0;
}

/// The number after the highest `migrations/NNNN_*.sql`.
private int nextMigration(string root)
{
    auto dir = buildPath(root, "migrations");
    int top;
    if (exists(dir))
        foreach (e; dirEntries(dir, "*.sql", SpanMode.shallow))
        {
            auto m = matchFirst(baseName(e.name), regex(`^(\d+)_`));
            if (m)
            {
                immutable v = m[1].to!int;
                top = v > top ? v : top;
            }
        }
    return top + 1;
}

/// The names of a use case of `feature`, shared by `generate usecase` and `generate job`.
private Scope useCaseScope(Project project, string feature, string word, Field[] fields, string doc)
{
    auto file = buildPath(project.root, "source", "usecases", feature ~ ".d");
    if (!exists(file))
        throw new Exception("andaime: there is no feature '" ~ feature ~ "' (no source/usecases/" ~ feature ~ ".d); "
            ~ "generate a resource first, or name an existing feature (the plural: users)");
    auto m = matchFirst(readText(file), regex(`interface\s+(\w+)Repository\b`));
    if (!m)
        throw new Exception("andaime: source/usecases/" ~ feature ~ ".d declares no `interface ...Repository`; the "
            ~ "generated use case takes the feature's repository");
    auto name = pascal(word);
    auto vars = projectScope(project);
    vars.set("feature", feature).set("featureCamel", camel(feature)).set("Entity", m[1]).set("Name", name);
    vars.set("instance", camel(word));
    vars.set("params", fields.map!(f => f.dType ~ " " ~ f.name).join(", "));
    vars.set("args", fields.map!(f => f.name).join(", "));
    vars.list("fields", fieldItems(fields)).flag("hasFields", fields.length > 0);
    vars.set("doc", render(doc, vars));
    return vars;
}

private int generateUseCase(Project project, string feature, string word, string[] specs, GenOptions opt)
{
    Field[] fields;
    foreach (spec; specs)
        fields ~= parseField(spec);
    auto vars = useCaseScope(project, feature, word, fields, "The use case {{Name}}.");
    print(runGenerator(projectTemplate(project.root, project.templateName), "usecase", project.root, vars, opt));
    return 0;
}

private int generateJob(Project project, string feature, string word, string[] specs, string queue, string cron,
    string every, GenOptions opt)
{
    Field[] fields;
    foreach (spec; specs)
        fields ~= parseField(spec);
    if (cron.length && cron.strip.split(' ').filter!(s => s.length).array.length != 5)
        throw new Exception("andaime: --cron takes five fields: minute hour day-of-month month day-of-week, like "
            ~ `"15 6 * * *"`);
    if (every.length && !matchFirst(every, regex(`^\d+\.(seconds|minutes|hours|days)$`)))
        throw new Exception("andaime: --every takes a number and a unit, like 15.minutes or 1.hours, not '" ~ every
            ~ "'");
    if (!matchFirst(queue, regex(`^[a-z][a-z0-9_-]*$`)))
        throw new Exception("andaime: --queue is lowercase letters, digits, - and _, not '" ~ queue ~ "'");
    if (!project.jobs)
    {
        installJobs(project, opt);
        if (!opt.dryRun)
            project = findProject();
    }
    auto vars = useCaseScope(project, feature, word, fields,
        "Run by the job `{{Name}}Job` (`adapters/jobs/{{feature}}.d`).");
    vars.set("queue", queue);
    vars.set("schedule", cron.length ? `@Cron("` ~ cron.strip ~ `")` : every.length ? "@Every(" ~ every ~ ")" : "");
    vars.set("payload", fields.length ? `"` ~ fields[0].name ~ `":` ~ fields[0].sampleJson(1) : "");
    print(runGenerator(projectTemplate(project.root, project.templateName), "job", project.root, vars, opt));
    return 0;
}

/// The jobs runtime of a project: `andaime:jobs`, `jobs.d`, the use case provider, and `main` serving through it.
private void installJobs(Project project, GenOptions opt)
{
    auto tpl = projectTemplate(project.root, project.templateName);
    if ("install-jobs/generator.json" !in tpl)
        throw new Exception("andaime: the template '" ~ project.templateName ~ "' has no jobs (no install-jobs "
            ~ "generator)");
    auto vars = projectScope(project);
    vars.flag("jobs", true);
    print(runGenerator(tpl, "install-jobs", project.root, vars, opt));
}

// ---------------------------------------------------------------- routes

/// `--compiler=` for dub when `DC` is set (ldmd2 is spelled ldc2 there).
private string[] dubCompiler()
{
    auto dc = environment.get("DC");
    return dc.length ? ["--compiler=" ~ dc.replace("ldmd2", "ldc2")] : null;
}

private int cmdRoutes(string[] args)
{
    if (args.length > 2)
        throw new Exception("andaime: routes takes at most one filter text (andaime --help)");
    auto filter = args.length == 2 ? args[1] : null;
    auto env = ["ANDAIME_ROUTES": "1"];
    auto r = execute(["dub", "run", "-q"] ~ dubCompiler(), env, Config.stderrPassThrough);
    if (r.status != 0)
        throw new Exception("andaime: `dub run` failed (exit " ~ r.status.to!string ~ "); see above");
    size_t shown;
    foreach (line; r.output.lineSplitter)
        if (filter.length == 0 || line.canFind(filter))
        {
            writeln(line);
            shown++;
        }
    if (shown == 0 && filter.length == 0)
        stderr.writeln("andaime: the app printed no routes; does main call serve (or tryServe)?");
    return 0;
}

// ---------------------------------------------------------------- check

/// The compiler for `-deps`: `DC`, or dmd, or ldmd2.
private string compiler()
{
    auto dc = environment.get("DC");
    if (dc.length)
        return dc == "ldc2" ? "ldmd2" : dc;
    foreach (c; ["dmd", "ldmd2"])
        if (execute(["which", c]).status == 0)
            return c;
    throw new Exception("andaime: no D compiler found (set DC)");
}

/// One `dub describe --data=<what> --data-list` answer: a list of values.
private string[] describe(string what)
{
    auto r = execute(["dub", "describe", "--data=" ~ what, "--data-list"] ~ dubCompiler(), null,
        Config.stderrPassThrough);
    if (r.status != 0)
        throw new Exception("andaime: `dub describe` failed (exit " ~ r.status.to!string ~ "); see above");
    return r.output.lineSplitter.map!(l => l.strip.idup).filter!(l => l.length > 0).array;
}

private int cmdCheck(string[] args)
{
    if (args.length > 1)
        throw new Exception("andaime: check takes no arguments (andaime --help)");
    auto project = findProject();
    import std.file : chdir, getcwd;

    auto back = getcwd();
    chdir(project.root);
    scope (exit)
        chdir(back);

    auto layers = parseLayers(project.json);
    if (layers.length == 0)
    {
        writeln("andaime check: andaime.json has no layers; nothing to check");
        return 0;
    }
    string[] sources;
    foreach (e; dirEntries("source", "*.d", SpanMode.depth))
        sources ~= e.name.replace("\\", "/");
    sources.sort();
    string[] flags = ["-o-"];
    foreach (p; describe("import-paths"))
        flags ~= "-I" ~ p;
    foreach (p; describe("string-import-paths"))
        flags ~= "-J" ~ p;
    foreach (v; describe("versions"))
        flags ~= "-version=" ~ v;
    auto depsFile = buildPath(tempDir, "andaime-check-" ~ environment.get("USER", "user") ~ ".deps");
    scope (exit)
        if (exists(depsFile))
            remove(depsFile);
    auto r = execute([compiler()] ~ flags ~ ["-deps=" ~ depsFile] ~ sources);
    if (r.status != 0)
    {
        stderr.write(r.output);
        throw new Exception("andaime check: the project does not compile; fix that first");
    }
    auto imports = parseDeps(readText(depsFile));
    bool[string] ours;
    foreach (line; readText(depsFile).lineSplitter)
    {
        auto m = matchFirst(line, regex(`^(?:depsImport )?(\S+) \((source/[^)]*)\)`));
        if (m)
            ours[m[1].idup] = true;
    }
    auto broken = violations(layers, imports, ours);
    foreach (line; broken)
        writeln(line);
    if (broken.length)
        return 1;
    writeln("andaime check: ", ours.length, " modules follow the layers of andaime.json");
    return 0;
}
