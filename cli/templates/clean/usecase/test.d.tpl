
unittest // {{Name}}
{
    auto {{instance}} = new {{Name}}(new Memory{{Entity}}Repository);
    {{instance}}.execute({{#fields}}{{sample1}}{{^last}}, {{/last}}{{/fields}});
    // then check what it did
}
