/// Companies and memberships in PostgreSQL (andaime:pg). The tables come from `migrations/0001_companies.sql`. Both
/// repositories use the worker's pool: inside a `PgUnitOfWork` their statements share its transaction.
module adapters.postgres.companies 2025;

@safe:

import std.datetime.systime : SysTime;
import andaime.db;
import andaime.values.optional : Optional;
import andaime.values.uuid : Uuid;
import domain.companies;
import domain.errors : Conflict;
import domain.tenancy : Role, Tenant;
import usecases.companies : CompanyRepository, MembershipRepository;

/// A row as the query returns it: the time as ISO 8601 text, turned into a `SysTime` by `toCompany`.
private struct CompanyRow
{
    Uuid id;
    string name;
    string createdAt;
}

private struct MembershipRow
{
    Uuid companyId;
    long userId;
    Role role;
    string joinedAt;
}

final class PgCompanyRepository : CompanyRepository
{
    private PgPool db;

    this(PgPool db)
    {
        this.db = db;
    }

    void add(Company company)
    {
        db.exec(`insert into companies (id, name, created_at) values ($1, $2, $3)`, company.id, company.name,
            company.createdAt.toISOExtString);
    }

    Optional!Company find(Tenant tenant)
    {
        auto rows = db.query(`select id, name, to_json(created_at) #>> '{}' as created_at from companies where id = $1`,
            tenant.id).rowsAs!CompanyRow;
        if (rows.length == 0)
            return Optional!Company.none;
        auto r = rows[0];
        return Optional!Company(Company(r.id, r.name, SysTime.fromISOExtString(r.createdAt)));
    }
}

final class PgMembershipRepository : MembershipRepository
{
    private PgPool db;

    this(PgPool db)
    {
        this.db = db;
    }

    void add(Tenant tenant, Membership m)
    {
        try
            db.exec(`insert into memberships (company_id, user_id, role, joined_at) values ($1, $2, $3, $4)`,
                tenant.id, m.userId, m.role, m.joinedAt.toISOExtString);
        catch (PgError e)
        {
            if (e.isUniqueViolation)
                throw new Conflict("the user is already a member of the company");
            throw e;
        }
    }

    Membership[] list(Tenant tenant)
    {
        Membership[] result;
        foreach (r; db.query(`select company_id, user_id, role, to_json(joined_at) #>> '{}' as joined_at
                from memberships where company_id = $1 order by joined_at, user_id`, tenant.id).rowsAs!MembershipRow)
            result ~= Membership(r.companyId, r.userId, r.role, SysTime.fromISOExtString(r.joinedAt));
        return result;
    }
}
