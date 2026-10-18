/// {{PluralWords}} in memory, in one thread: for tests{{#pg}}, and for `STORE=memory`{{/pg}}.
{{#pg}}
/// It behaves like the Postgres repository: `tests/{{plural}}.d` runs the same contract on both.
{{/pg}}
module adapters.memory.{{plural}};

@safe:

import andaime.http.optional : Optional;
{{#hasUnique}}
import domain.errors : Conflict;
{{/hasUnique}}
import domain.{{plural}};
import usecases.{{plural}} : {{Name}}Repository;

final class Memory{{Name}}Repository : {{Name}}Repository
{
    private {{Name}}[] rows; // ordered by id
    private long lastId;

    {{Name}}[] list(int limit, int offset)
    {
        immutable from = offset < rows.length ? cast(size_t) offset : rows.length;
        immutable to = from + limit < rows.length ? from + limit : rows.length;
        return rows[from .. to].dup;
    }

    Optional!{{Name}} find(long id)
    {
        foreach (row; rows)
            if (row.id == id)
                return Optional!{{Name}}(row);
        return Optional!{{Name}}.none;
    }

    {{Name}} add(New{{Name}} {{camel}})
    {
{{#hasUnique}}
        checkUnique({{Name}}(0{{#fields}}, {{camel}}.{{name}}{{/fields}}));
{{/hasUnique}}
        auto row = {{Name}}(++lastId{{#fields}}, {{camel}}.{{name}}{{/fields}});
        rows ~= row;
        return row;
    }

    bool update({{Name}} {{camel}})
    {
        foreach (ref row; rows)
            if (row.id == {{camel}}.id)
            {
{{#hasUnique}}
                checkUnique({{camel}});
{{/hasUnique}}
                row = {{camel}};
                return true;
            }
        return false;
    }

    bool remove(long id)
    {
        foreach (i, row; rows)
            if (row.id == id)
            {
                rows = rows[0 .. i] ~ rows[i + 1 .. $];
                return true;
            }
        return false;
    }
{{#hasUnique}}

    /// The unique columns ({{uniqueText}}): a value another {{words}} already has is a `Conflict`, as in Postgres.
    private void checkUnique({{Name}} {{camel}})
    {
        foreach (row; rows)
            if (row.id != {{camel}}.id && {{#manyUnique}}({{/manyUnique}}{{#uniqueFields}}row.{{name}} == {{camel}}.{{name}}{{^last}} || {{/last}}{{/uniqueFields}}{{#manyUnique}}){{/manyUnique}})
                throw new Conflict("{{a}} {{words}} with the same {{uniqueText}} already exists");
    }
{{/hasUnique}}
}
