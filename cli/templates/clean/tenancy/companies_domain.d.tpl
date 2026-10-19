/// Companies and their members: the tenants of the application. Plain D: no framework, no database.
module domain.companies 2025;

@safe:

import std.datetime.systime : SysTime;
import andaime.values.uuid : Uuid;
import domain.errors : RuleViolation;
import domain.tenancy : Role, Tenant;

/// A company: every piece of data a member creates belongs to one.
struct Company
{
    Uuid id;
    string name;
    SysTime createdAt;

    Tenant tenant() const pure nothrow => Tenant(id);
}

/// A company that is not stored yet.
struct NewCompany
{
    string name;
}

/// A user's place in a company.
struct Membership
{
    Uuid companyId;
    long userId;
    Role role;
    SysTime joinedAt;
}

/// The business rules of a new company; throws `RuleViolation`.
void checkRules(const NewCompany company)
{
    if (company.name.length > 120)
        throw new RuleViolation("a company name has at most 120 characters", "name_too_long");
}
