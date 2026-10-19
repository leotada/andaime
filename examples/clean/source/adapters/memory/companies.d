/// Companies and memberships in memory, in one thread: for tests, and for `STORE=memory`. A
/// `MemoryUnitOfWork` that tracks them rolls them back together.
module adapters.memory.companies 2025;

@safe:

import andaime.values.optional : Optional;
import domain.companies;
import domain.errors : Conflict;
import domain.tenancy : Tenant;
import usecases.companies : CompanyRepository, MembershipRepository;

final class MemoryCompanyRepository : CompanyRepository
{
    private Company[] rows;

    void delegate() @safe snapshot()
    {
        auto saved = rows.dup;
        return () { rows = saved.dup; };
    }

    void add(Company company)
    {
        rows ~= company;
    }

    Optional!Company find(Tenant tenant)
    {
        foreach (row; rows)
            if (row.id == tenant.id)
                return Optional!Company(row);
        return Optional!Company.none;
    }
}

final class MemoryMembershipRepository : MembershipRepository
{
    private Membership[] rows;

    void delegate() @safe snapshot()
    {
        auto saved = rows.dup;
        return () { rows = saved.dup; };
    }

    void add(Tenant tenant, Membership membership)
    {
        foreach (row; rows)
            if (row.companyId == tenant.id && row.userId == membership.userId)
                throw new Conflict("the user is already a member of the company");
        membership.companyId = tenant.id;
        rows ~= membership;
    }

    Membership[] list(Tenant tenant)
    {
        Membership[] result;
        foreach (row; rows)
            if (row.companyId == tenant.id)
                result ~= row;
        return result;
    }
}
