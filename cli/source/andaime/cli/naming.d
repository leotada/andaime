/// Names for generated code: one word in (`user`, `User`, `blog_post`, `blogPost`), every spelling out, and the fields of
/// a resource (`email:string:unique`, `bio:string?`).
module andaime.cli.naming;

@safe:

import std.ascii : isAlpha, isAlphaNum, isDigit, isLower, isUpper, toLower, toUpper;

/// Thrown for a name or a field the generators cannot use; the message is shown as it is.
class NameError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, file, line);
    }
}

/// `blogPost`, `BlogPost` or `blog-post` -> `blog_post`.
string snake(string word) pure
{
    string o;
    foreach (i, c; word)
    {
        if (c == '-' || c == '_')
        {
            if (o.length && o[$ - 1] != '_')
                o ~= '_';
        }
        else if (isUpper(c))
        {
            if (i > 0 && o.length && o[$ - 1] != '_' && !isUpper(word[i - 1]))
                o ~= '_';
            o ~= toLower(c);
        }
        else
            o ~= c;
    }
    return o;
}

/// `blog_post` -> `BlogPost`.
string pascal(string word) pure
{
    string o;
    bool up = true;
    foreach (c; snake(word))
    {
        if (c == '_')
        {
            up = true;
            continue;
        }
        o ~= up ? toUpper(c) : c;
        up = false;
    }
    return o;
}

/// `blog_post` -> `blogPost`.
string camel(string word) pure
{
    auto p = pascal(word);
    return p.length ? toLower(p[0]) ~ p[1 .. $] : p;
}

/// `blog_post` -> `blog-post` (URL paths).
string kebab(string word) pure
{
    string o;
    foreach (c; snake(word))
        o ~= c == '_' ? '-' : c;
    return o;
}

/// The English plural of a snake_case word, by the common rules (`--plural` covers the rest).
string pluralize(string word) pure
{
    auto w = snake(word);
    if (w.length == 0)
        return w;
    if (endsWith(w, "s") || endsWith(w, "x") || endsWith(w, "z") || endsWith(w, "ch") || endsWith(w, "sh"))
        return w ~ "es";
    if (w.length > 1 && w[$ - 1] == 'y' && !isVowel(w[$ - 2]))
        return w[0 .. $ - 1] ~ "ies";
    return w ~ "s";
}

private bool isVowel(char c) pure nothrow => c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u';

private bool endsWith(string s, string tail) pure nothrow => s.length >= tail.length && s[$ - tail.length .. $] == tail;

/// The spellings of a resource's name.
struct Names
{
    string snake;        /// `blog_post`
    string pascal;       /// `BlogPost`
    string camel;        /// `blogPost`
    string plural;       /// `blog_posts`: module files, the table, the feature
    string pluralPascal; /// `BlogPosts`
    string pluralCamel;  /// `blogPosts`
    string path;         /// `/blog-posts`
}

/// The names of `word` (singular); `plural` overrides the computed plural.
Names names(string word, string plural = null)
{
    checkIdentifier(word, "the name");
    Names n;
    n.snake = snake(word);
    n.pascal = pascal(word);
    n.camel = camel(word);
    n.plural = plural.length ? snake(plural) : pluralize(word);
    checkIdentifier(n.plural, "the plural");
    if (n.plural == n.snake)
        throw new NameError("andaime: the plural of '" ~ word ~ "' is the same word; give another one with --plural");
    n.pluralPascal = pascal(n.plural);
    n.pluralCamel = camel(n.plural);
    n.path = "/" ~ kebab(n.plural);
    return n;
}

/// The scalar types a field may have.
immutable string[] fieldTypes = ["string", "int", "long", "bool", "double"];

/// A field of a resource, a job or a use case.
struct Field
{
    string name;      /// `userId`: the D name and the JSON key
    string column;    /// `user_id`: the SQL column
    string type;      /// `long`
    bool optional;    /// `?`: may be absent (`Optional!T`, a nullable column)
    bool unique;      /// `:unique`: no two rows share it

    /// The D type: `long` or `Optional!long`.
    string dType() const pure => optional ? "Optional!" ~ type : type;

    /// The column definition.
    string sqlType() const pure
    {
        string t;
        switch (type)
        {
            case "string": t = "text"; break;
            case "int": t = "integer"; break;
            case "long": t = "bigint"; break;
            case "bool": t = "boolean"; break;
            case "double": t = "double precision"; break;
            default: assert(0, type);
        }
        if (!optional)
            t ~= " not null";
        if (unique)
            t ~= " unique";
        return t;
    }

    /// A value for tests, different for each `n`, as JSON.
    string sampleJson(int n) const pure
    {
        import std.conv : to;

        switch (type)
        {
            case "string": return `"` ~ column ~ " " ~ n.to!string ~ `"`;
            case "int", "long": return n.to!string;
            case "bool": return n % 2 ? "true" : "false";
            case "double": return n.to!string ~ ".5";
            default: assert(0, type);
        }
    }

    /// The same value as D code.
    string sample(int n) const pure
    {
        auto v = sampleJson(n);
        return optional ? "Optional!" ~ type ~ "(" ~ v ~ ")" : v;
    }
}

/// `email:string:unique`, `bio:string?` or `views:int`.
Field parseField(string spec)
{
    import std.array : split;

    auto parts = spec.split(':');
    if (parts.length < 2 || parts.length > 3 || parts[0].length == 0)
        throw new NameError("andaime: field '" ~ spec ~ "': write name:type, name:type? or name:type:unique");
    Field f;
    checkIdentifier(parts[0], "field '" ~ spec ~ "'");
    f.name = camel(parts[0]);
    f.column = snake(parts[0]);
    auto type = parts[1];
    if (type.length && type[$ - 1] == '?')
    {
        f.optional = true;
        type = type[0 .. $ - 1];
    }
    bool known;
    foreach (t; fieldTypes)
        known |= t == type;
    if (!known)
        throw new NameError("andaime: field '" ~ spec ~ "': the type is string, int, long, bool or double (with ? when it "
            ~ "may be absent), not '" ~ type ~ "'");
    f.type = type;
    if (parts.length == 3)
    {
        if (parts[2] != "unique")
            throw new NameError("andaime: field '" ~ spec ~ "': the only modifier is :unique, not ':" ~ parts[2] ~ "'");
        f.unique = true;
    }
    if (f.name == "id")
        throw new NameError("andaime: field '" ~ spec ~ "': every resource already has an id");
    if (isKeyword(f.name))
        throw new NameError("andaime: field '" ~ spec ~ "': '" ~ f.name ~ "' is a D keyword; choose another name");
    return f;
}

/// A word of letters, digits and `_` or `-`, starting with a letter.
private void checkIdentifier(string word, string what)
{
    bool ok = word.length > 0 && isAlpha(word[0]);
    foreach (c; word)
        ok &= isAlphaNum(c) || c == '_' || c == '-';
    if (!ok)
        throw new NameError("andaime: " ~ what ~ " must be letters, digits and _ starting with a letter, not '" ~ word
            ~ "'");
}

private bool isKeyword(string s) pure nothrow
{
    static immutable keywords = ["abstract", "alias", "align", "asm", "assert", "auto", "bool", "break", "byte",
        "case", "cast", "catch", "char", "class", "const", "continue", "dchar", "debug", "default", "delegate", "delete",
        "deprecated", "do", "double", "else", "enum", "export", "extern", "false", "final", "finally", "float", "for",
        "foreach", "function", "goto", "if", "immutable", "import", "in", "inout", "int", "interface", "invariant", "is",
        "lazy", "long", "macro", "mixin", "module", "new", "nothrow", "null", "out", "override", "package", "pragma",
        "private", "protected", "public", "pure", "real", "ref", "return", "scope", "shared", "short", "static", "struct",
        "super", "switch", "synchronized", "template", "this", "throw", "true", "try", "typeid", "typeof", "ubyte",
        "uint", "ulong", "union", "unittest", "ushort", "version", "void", "wchar", "while", "with"];
    foreach (k; keywords)
        if (k == s)
            return true;
    return false;
}

unittest // spellings
{
    assert(snake("BlogPost") == "blog_post" && snake("blogPost") == "blog_post" && snake("blog-post") == "blog_post");
    assert(snake("user_id") == "user_id" && snake("URL") == "url");
    assert(pascal("blog_post") == "BlogPost" && camel("blog_post") == "blogPost" && kebab("blog_post") == "blog-post");
    assert(pluralize("user") == "users" && pluralize("category") == "categories" && pluralize("day") == "days");
    assert(pluralize("box") == "boxes" && pluralize("match") == "matches" && pluralize("bus") == "buses");
    auto n = names("BlogPost");
    assert(n.snake == "blog_post" && n.pascal == "BlogPost" && n.plural == "blog_posts" && n.pluralPascal == "BlogPosts");
    assert(n.pluralCamel == "blogPosts" && n.path == "/blog-posts");
    assert(names("person", "people").plural == "people");
}

unittest // fields
{
    auto f = parseField("user_id:long");
    assert(f.name == "userId" && f.column == "user_id" && f.dType == "long" && f.sqlType == "bigint not null");
    assert(f.sample(2) == "2" && f.sampleJson(2) == "2");
    f = parseField("bio:string?");
    assert(f.optional && f.dType == "Optional!string" && f.sqlType == "text");
    assert(f.sample(1) == `Optional!string("bio 1")` && f.sampleJson(1) == `"bio 1"`);
    f = parseField("email:string:unique");
    assert(f.unique && f.sqlType == "text not null unique");
    assert(parseField("ok:bool").sample(1) == "true" && parseField("price:double").sample(3) == "3.5");

    bool fails(string spec, string text)
    {
        try
            parseField(spec);
        catch (NameError e)
        {
            import std.algorithm : canFind;

            return e.msg.canFind(text);
        }
        return false;
    }
    assert(fails("name", "write name:type"));
    assert(fails("age:integer", "not 'integer'"));
    assert(fails("id:long", "already has an id"));
    assert(fails("version:string", "D keyword"));
    assert(parseField("body:string?").name == "body"); // `body` is no longer reserved
    assert(fails("x:int:indexed", "only modifier"));
    assert(fails("9lives:int", "starting with a letter"));
}
