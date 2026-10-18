/// The template language of the CLI: a small subset of Mustache.
///
/// - `{{name}}` is a value.
/// - `{{#name}}...{{/name}}` repeats for each item of a list, or shows its content when a flag is true or a value is not
///   empty. Inside a list, `first` and `last` are flags of the current item.
/// - `{{^name}}...{{/name}}` is the opposite: an empty list, a false flag, an empty value.
///
/// A tag is `{{`, an optional `#`, `^` or `/`, a name (letters, digits, `_`, `.`) and `}}`. Anything else is text, so the
/// `{{ }}` blocks of D code pass through. A section tag alone on its line takes the whole line with it. A name that is
/// not defined is an error: a template cannot silently print nothing.
module andaime.cli.mustache;

@safe:

/// The names a template can use.
final class Scope
{
    string[string] text;
    bool[string] flags;
    Scope[][string] lists;

    Scope set(string name, string value)
    {
        text[name] = value;
        return this;
    }

    Scope flag(string name, bool value)
    {
        flags[name] = value;
        return this;
    }

    Scope list(string name, Scope[] items)
    {
        lists[name] = items;
        return this;
    }
}

/// Thrown for a malformed template or a name it uses that no scope defines.
class TemplateError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, file, line);
    }
}

/// `tpl` with its tags replaced from `scope_`. `where` names the template in error messages.
string render(string tpl, Scope scope_, string where = "template")
{
    size_t pos;
    auto nodes = parse(tpl, pos, null, where);
    string o;
    Scope[] stack = [scope_];
    emit(nodes, stack, o, where);
    return o;
}

private struct Node
{
    enum Kind { text, value, section, inverted }

    Kind kind;
    string text; // the text, or the name
    Node[] children;
}

private struct Tag
{
    size_t start, end; // `{{` .. after `}}`
    char sigil;        // 0, '#', '^' or '/'
    string name;
}

private bool isNameChar(char c) pure nothrow
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.';
}

/// The tag starting at `i`, if there is one.
private bool tagAt(string s, size_t i, out Tag t) pure nothrow
{
    if (i + 4 > s.length || s[i] != '{' || s[i + 1] != '{')
        return false;
    size_t j = i + 2;
    char sigil = 0;
    if (s[j] == '#' || s[j] == '^' || s[j] == '/')
        sigil = s[j++];
    immutable from = j;
    if (j >= s.length || !(isNameChar(s[j]) && (s[j] < '0' || s[j] > '9') && s[j] != '.'))
        return false; // a name starts with a letter or `_`
    while (j < s.length && isNameChar(s[j]))
        j++;
    if (j + 2 > s.length || s[j] != '}' || s[j + 1] != '}')
        return false;
    t = Tag(i, j + 2, sigil, s[from .. j]);
    return true;
}

/// Where the line holding `t` starts, and where the next one starts, when `t` is alone on it (spaces aside); otherwise
/// false. `textFrom` is where the text before the tag began: a tag between it and the line start shares the line.
private bool standalone(string s, Tag t, size_t textFrom, out size_t lineStart, out size_t nextLine) pure nothrow
{
    size_t a = t.start;
    while (a > textFrom && (s[a - 1] == ' ' || s[a - 1] == '\t'))
        a--;
    if (!(a == 0 || s[a - 1] == '\n') || a < textFrom)
        return false;
    size_t b = t.end;
    while (b < s.length && (s[b] == ' ' || s[b] == '\t'))
        b++;
    if (b < s.length && s[b] != '\n')
        return false;
    lineStart = a;
    nextLine = b < s.length ? b + 1 : b;
    return true;
}

/// Nodes from `pos` up to the closing tag of `open` (or the end when `open` is null).
private Node[] parse(string s, ref size_t pos, string open, string where)
{
    Node[] nodes;
    size_t textFrom = pos;
    size_t i = pos;
    while (i < s.length)
    {
        Tag t;
        if (!tagAt(s, i, t))
        {
            i++;
            continue;
        }
        size_t textTo = t.start, after = t.end;
        if (t.sigil != 0)
        {
            size_t lineStart, nextLine;
            if (standalone(s, t, textFrom, lineStart, nextLine))
            {
                textTo = lineStart;
                after = nextLine;
            }
        }
        if (textTo > textFrom)
            nodes ~= Node(Node.Kind.text, s[textFrom .. textTo]);
        pos = after;
        final switch (t.sigil)
        {
            case 0:
                nodes ~= Node(Node.Kind.value, t.name);
                break;
            case '#':
            case '^':
                auto children = parse(s, pos, t.name, where);
                nodes ~= Node(t.sigil == '#' ? Node.Kind.section : Node.Kind.inverted, t.name, children);
                break;
            case '/':
                if (t.name != open)
                    throw new TemplateError(where ~ ": {{/" ~ t.name ~ "}} closes nothing"
                        ~ (open.length ? " (the open section is " ~ open ~ ")" : ""));
                return nodes;
        }
        i = textFrom = pos;
    }
    if (open.length)
        throw new TemplateError(where ~ ": {{#" ~ open ~ "}} is never closed");
    if (s.length > textFrom)
        nodes ~= Node(Node.Kind.text, s[textFrom .. $]);
    pos = s.length;
    return nodes;
}

private enum Found { missing, text, flag, list }

private Found lookup(Scope[] stack, string name, out string text, out bool flag, out Scope[] list)
{
    foreach_reverse (sc; stack)
    {
        if (auto p = name in sc.text)
        {
            text = *p;
            return Found.text;
        }
        if (auto p = name in sc.flags)
        {
            flag = *p;
            return Found.flag;
        }
        if (auto p = name in sc.lists)
        {
            list = *p;
            return Found.list;
        }
    }
    return Found.missing;
}

private void emit(Node[] nodes, ref Scope[] stack, ref string o, string where)
{
    foreach (ref n; nodes)
    {
        string text;
        bool flag;
        Scope[] list;
        final switch (n.kind)
        {
            case Node.Kind.text:
                o ~= n.text;
                break;
            case Node.Kind.value:
                final switch (lookup(stack, n.text, text, flag, list))
                {
                    case Found.text:
                        o ~= text;
                        break;
                    case Found.flag:
                    case Found.list:
                        throw new TemplateError(where ~ ": {{" ~ n.text ~ "}} is a flag or a list, not a value");
                    case Found.missing:
                        throw new TemplateError(where ~ ": {{" ~ n.text ~ "}} is not defined");
                }
                break;
            case Node.Kind.section:
            case Node.Kind.inverted:
                immutable want = n.kind == Node.Kind.section;
                final switch (lookup(stack, n.text, text, flag, list))
                {
                    case Found.text:
                        if ((text.length > 0) == want)
                            emit(n.children, stack, o, where);
                        break;
                    case Found.flag:
                        if (flag == want)
                            emit(n.children, stack, o, where);
                        break;
                    case Found.list:
                        if (!want)
                        {
                            if (list.length == 0)
                                emit(n.children, stack, o, where);
                            break;
                        }
                        foreach (k, item; list)
                        {
                            auto position = new Scope;
                            position.flag("first", k == 0).flag("last", k + 1 == list.length);
                            stack ~= position;
                            stack ~= item;
                            emit(n.children, stack, o, where);
                            stack = stack[0 .. $ - 2];
                        }
                        break;
                    case Found.missing:
                        throw new TemplateError(where ~ ": {{#" ~ n.text ~ "}} is not defined");
                }
                break;
        }
    }
}

unittest // values, flags, lists with first/last, and D's own braces
{
    auto s = new Scope;
    s.set("Name", "User").flag("pg", true).flag("memory", false);
    s.list("fields", [new Scope().set("name", "name"), new Scope().set("name", "email")]);
    assert(render("struct {{Name}} { }", s) == "struct User { }");
    assert(render("{{#pg}}pg{{/pg}}{{^memory}}!{{/memory}}", s) == "pg!");
    assert(render("{{#fields}}{{name}}{{^last}}, {{/last}}{{/fields}}", s) == "name, email");
    assert(render("{{#fields}}{{#first}}[{{/first}}{{name}}{{/fields}}", s) == "[nameemail");
    assert(render("static if (x) {{ int y; }}", s) == "static if (x) {{ int y; }}");
    assert(render("a {{ b }} {{9}}", s) == "a {{ b }} {{9}}"); // not tags: a space, or no name
    assert(render("{{Name}}{{#fields}}{{Name}}{{/fields}}", s) == "UserUserUser"); // outer names are visible inside
}

unittest // a section tag alone on its line takes the line with it
{
    auto s = new Scope;
    s.flag("yes", true).flag("no", false);
    s.list("items", [new Scope().set("v", "a"), new Scope().set("v", "b")]);
    assert(render("x\n    {{#yes}}\n    y\n    {{/yes}}\nz\n", s) == "x\n    y\nz\n");
    assert(render("x\n{{#no}}\ny\n{{/no}}\nz\n", s) == "x\nz\n");
    assert(render("{{#items}}\n- {{v}}\n{{/items}}\n", s) == "- a\n- b\n");
    assert(render("a {{#yes}}b{{/yes}}\n", s) == "a b\n"); // not alone: the line stays
    assert(render("a\n{{#yes}}\nb\n{{/yes}}", s) == "a\nb\n"); // a tag on the last line, with no newline after it
}

unittest // errors name the template and the tag
{
    auto s = new Scope;
    s.flag("f", true);
    bool threw(string tpl, string expected)
    {
        try
            render(tpl, s, "t.d");
        catch (TemplateError e)
            return e.msg == expected;
        return false;
    }
    assert(threw("{{x}}", "t.d: {{x}} is not defined"));
    assert(threw("{{f}}", "t.d: {{f}} is a flag or a list, not a value"));
    assert(threw("{{#f}}a", "t.d: {{#f}} is never closed"));
    assert(threw("{{/f}}", "t.d: {{/f}} closes nothing"));
    assert(threw("{{#f}}{{/g}}", "t.d: {{/g}} closes nothing (the open section is f)"));
}
