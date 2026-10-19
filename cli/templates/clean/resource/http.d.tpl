/// {{PluralWords}} over HTTP: the routes, the JSON a client sends and receives, and the calls to the use cases.
module adapters.http.{{plural}} 2025;

@safe:

import andaime;
import adapters.http.paging : Page;
import domain.{{plural}} : New{{Name}}, {{Name}};
import usecases.{{plural}};

/// What a client sends to create or replace {{a}} {{words}}. Validation attributes (`@minLength`, `@inRange`...) on these
/// fields check the request's format and answer 422.
struct {{Name}}In
{
{{#fields}}
    {{type}} {{name}};
{{/fields}}
}

/// What a client receives.
struct {{Name}}Out
{
    long id;
{{#fields}}
    {{type}} {{name}};
{{/fields}}
}

// The fields of the same name and type, checked at compile time: a field the domain gains and the DTO lacks stays
// behind; a DTO field the domain lacks does not compile (write that conversion by hand).
{{Name}}Out toOut({{Name}} {{camel}}) => copyAs!{{Name}}Out({{camel}});

New{{Name}} toNew({{Name}}In input) => copyAs!New{{Name}}(input);

/// The `{{path}}` routes; `app.d` mounts them under `/api/v1`.
final class {{Name}}Controller
{
    private List{{Plural}} list{{Plural}};
    private Get{{Name}} get{{Name}};
    private Create{{Name}} create{{Name}};
    private Update{{Name}} update{{Name}};
    private Delete{{Name}} delete{{Name}};

    this(List{{Plural}} list{{Plural}}, Get{{Name}} get{{Name}}, Create{{Name}} create{{Name}}, Update{{Name}} update{{Name}}, Delete{{Name}} delete{{Name}})
    {
        this.list{{Plural}} = list{{Plural}};
        this.get{{Name}} = get{{Name}};
        this.create{{Name}} = create{{Name}};
        this.update{{Name}} = update{{Name}};
        this.delete{{Name}} = delete{{Name}};
    }

    @Get("{{path}}") @summary("List {{pluralWords}}")
    {{Name}}Out[] list(Query!Page page)
    {
        {{Name}}Out[] result;
        foreach ({{camel}}; list{{Plural}}.execute(page.limit, page.offset))
            result ~= toOut({{camel}});
        return result;
    }

    @Get("{{path}}/{id}") @summary("Get {{a}} {{words}}") @responds(404, "{{words}} not found")
    {{Name}}Out get(long id) => toOut(get{{Name}}.execute(id));

    @Post("{{path}}") @status(201) @summary("Create {{a}} {{words}}"){{#hasUnique}} @responds(409, "a unique value is taken"){{/hasUnique}}
    {{Name}}Out create(JsonBody!{{Name}}In body_) => toOut(create{{Name}}.execute(toNew(body_)));

    @Put("{{path}}/{id}") @summary("Replace {{a}} {{words}}") @responds(404, "{{words}} not found")
{{#hasUnique}}
    @responds(409, "a unique value is taken")
{{/hasUnique}}
    {{Name}}Out update(long id, JsonBody!{{Name}}In body_) => toOut(update{{Name}}.execute(id, toNew(body_)));

    @Delete("{{path}}/{id}") @status(204) @summary("Delete {{a}} {{words}}") @responds(404, "{{words}} not found")
    void remove(long id)
    {
        delete{{Name}}.execute(id);
    }
}
