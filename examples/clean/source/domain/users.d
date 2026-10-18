/// Users: the entity and its rules. Plain D: no framework, no database.
module domain.users 2025;

@safe:

import domain.errors : RuleViolation;

/// A user, as the application knows it.
struct User
{
    long id;
    string name;
    string email;
}

/// A user that is not stored yet, or the new values of one.
struct NewUser
{
    string name;
    string email;
}

/// The business rules a user must follow before it is stored; throws `RuleViolation`. The format of a request
/// (types, lengths, required fields) is checked earlier, at the edge (`adapters/http/users.d`): this is for what
/// the business decides.
void checkRules(const NewUser user)
{
}
