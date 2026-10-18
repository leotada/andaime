/// {{PluralWords}}: the entity and its rules. Plain D: no framework, no database.
module domain.{{plural}} 2025;

@safe:

{{#hasOptional}}
import andaime.http.optional : Optional;
{{/hasOptional}}
import domain.errors : RuleViolation;

/// {{A}} {{words}}, as the application knows it.
struct {{Name}}
{
    long id;
{{#fields}}
    {{type}} {{name}};
{{/fields}}
}

/// {{A}} {{words}} that is not stored yet, or the new values of one.
struct New{{Name}}
{
{{#fields}}
    {{type}} {{name}};
{{/fields}}
}

/// The business rules {{a}} {{words}} must follow before it is stored; throws `RuleViolation`. The format of a request
/// (types, lengths, required fields) is checked earlier, at the edge (`adapters/http/{{plural}}.d`): this is for what
/// the business decides.
void checkRules(const New{{Name}} {{camel}})
{
}
