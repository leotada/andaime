/// What the application does with {{pluralWords}}. One class per use case, with one `execute`; its constructor takes the
/// ports it needs. Imports the domain only: no framework, no database.
module usecases.{{plural}};

@safe:

import andaime.http.optional : Optional;
import domain.errors : NotFound;
import domain.{{plural}};

{{#pg}}
/// Where {{pluralWords}} are kept: the port. `adapters/postgres/{{plural}}.d` and
/// `adapters/memory/{{plural}}.d` implement it, and `tests/{{plural}}.d` checks that both behave the same.
{{/pg}}
{{^pg}}
/// Where {{pluralWords}} are kept: the port. `adapters/memory/{{plural}}.d` implements it, and `tests/{{plural}}.d` holds
/// the contract any other implementation must pass.
{{/pg}}
interface {{Name}}Repository
{
    /// {{PluralWords}} ordered by id: at most `limit`, skipping the first `offset`.
    {{Name}}[] list(int limit, int offset);

    /// The {{words}} with this id, if there is one.
    Optional!{{Name}} find(long id);

    /// Stores a new {{words}} and returns it with its id.
{{#hasUnique}}
    /// Throws `Conflict` when a unique value is taken.
{{/hasUnique}}
    {{Name}} add(New{{Name}} {{camel}});

    /// Replaces the stored {{words}} that has `{{camel}}.id`; false when there is none.
{{#hasUnique}}
    /// Throws `Conflict` when a unique value is taken.
{{/hasUnique}}
    bool update({{Name}} {{camel}});

    /// Deletes the {{words}}; false when there was none.
    bool remove(long id);
}

/// Lists {{pluralWords}}, a page at a time.
final class List{{Plural}}
{
    private {{Name}}Repository {{pluralCamel}};

    this({{Name}}Repository {{pluralCamel}})
    {
        this.{{pluralCamel}} = {{pluralCamel}};
    }

    {{Name}}[] execute(int limit, int offset)
    {
        return {{pluralCamel}}.list(limit, offset);
    }
}

/// One {{words}} by id.
final class Get{{Name}}
{
    private {{Name}}Repository {{pluralCamel}};

    this({{Name}}Repository {{pluralCamel}})
    {
        this.{{pluralCamel}} = {{pluralCamel}};
    }

    {{Name}} execute(long id)
    {
        auto found = {{pluralCamel}}.find(id);
        if (!found.has)
            throw new NotFound("{{words}} not found");
        return found.get;
    }
}

/// Creates {{a}} {{words}}.
final class Create{{Name}}
{
    private {{Name}}Repository {{pluralCamel}};

    this({{Name}}Repository {{pluralCamel}})
    {
        this.{{pluralCamel}} = {{pluralCamel}};
    }

    {{Name}} execute(New{{Name}} input)
    {
        checkRules(input);
        return {{pluralCamel}}.add(input);
    }
}

/// Replaces {{a}} {{words}}'s values.
final class Update{{Name}}
{
    private {{Name}}Repository {{pluralCamel}};

    this({{Name}}Repository {{pluralCamel}})
    {
        this.{{pluralCamel}} = {{pluralCamel}};
    }

    {{Name}} execute(long id, New{{Name}} input)
    {
        checkRules(input);
        auto {{camel}} = {{Name}}(id{{#fields}}, input.{{name}}{{/fields}});
        if (!{{pluralCamel}}.update({{camel}}))
            throw new NotFound("{{words}} not found");
        return {{camel}};
    }
}

/// Deletes {{a}} {{words}}.
final class Delete{{Name}}
{
    private {{Name}}Repository {{pluralCamel}};

    this({{Name}}Repository {{pluralCamel}})
    {
        this.{{pluralCamel}} = {{pluralCamel}};
    }

    void execute(long id)
    {
        if (!{{pluralCamel}}.remove(id))
            throw new NotFound("{{words}} not found");
    }
}
