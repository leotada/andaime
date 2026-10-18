/// {{PluralWords}} in PostgreSQL (andaime:pg). The table comes from `migrations/{{migration}}_{{plural}}.sql`.
module adapters.postgres.{{plural}};

@safe:

import andaime.db;
import andaime.http.optional : Optional;
{{#hasUnique}}
import domain.errors : Conflict;
{{/hasUnique}}
import domain.{{plural}};
import usecases.{{plural}} : {{Name}}Repository;

final class Pg{{Name}}Repository : {{Name}}Repository
{
    private PgPool db;

    this(PgPool db)
    {
        this.db = db;
    }

    {{Name}}[] list(int limit, int offset)
    {
        return db.query(`select {{selectList}} from {{table}} order by id limit $1 offset $2`, limit, offset)
            .rowsAs!{{Name}};
    }

    Optional!{{Name}} find(long id)
    {
        auto rows = db.query(`select {{selectList}} from {{table}} where id = $1`, id).rowsAs!{{Name}};
        return rows.length ? Optional!{{Name}}(rows[0]) : Optional!{{Name}}.none;
    }

    {{Name}} add(New{{Name}} {{camel}})
    {
{{#hasUnique}}
        try
            return db.query(`insert into {{table}} ({{insertColumns}}) values ({{insertParams}}) returning {{selectList}}`,
                {{#fields}}{{camel}}.{{name}}{{^last}}, {{/last}}{{/fields}}).one!{{Name}};
        catch (PgError e)
            throw conflictOr(e);
{{/hasUnique}}
{{^hasUnique}}
        return db.query(`insert into {{table}} ({{insertColumns}}) values ({{insertParams}}) returning {{selectList}}`,
            {{#fields}}{{camel}}.{{name}}{{^last}}, {{/last}}{{/fields}}).one!{{Name}};
{{/hasUnique}}
    }

    bool update({{Name}} {{camel}})
    {
{{#hasUnique}}
        try
            return db.query(`update {{table}} set {{updateSets}} where id = $1 returning id`,
                {{camel}}.id{{#fields}}, {{camel}}.{{name}}{{/fields}}).rows == 1;
        catch (PgError e)
            throw conflictOr(e);
{{/hasUnique}}
{{^hasUnique}}
        return db.query(`update {{table}} set {{updateSets}} where id = $1 returning id`,
            {{camel}}.id{{#fields}}, {{camel}}.{{name}}{{/fields}}).rows == 1;
{{/hasUnique}}
    }

    bool remove(long id)
    {
        return db.query(`delete from {{table}} where id = $1 returning id`, id).rows == 1;
    }
}
{{#hasUnique}}

/// A unique violation is the domain's `Conflict`; any other database error goes on as it is.
private Exception conflictOr(PgError e)
{
    if (e.isUniqueViolation)
        return new Conflict("{{a}} {{words}} with the same {{uniqueText}} already exists");
    return e;
}
{{/hasUnique}}
