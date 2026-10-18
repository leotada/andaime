
@Job("{{queue}}")
{{#schedule}}
{{schedule}}
{{/schedule}}
struct {{Name}}Job
{
{{#fields}}
    {{type}} {{name}};
{{/fields}}
{{#hasFields}}

{{/hasFields}}
    void perform(ref JobContext ctx) @safe
    {
        provided!{{Name}}.get().execute({{args}});
    }
}
