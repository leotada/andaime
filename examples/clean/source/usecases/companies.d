/// What the application does with companies. `CreateCompany` writes two tables in one unit of work; the others take the
/// acting user (`Actor`) and decide with the domain's policies.
module usecases.companies 2025;

@safe:

import andaime.values.optional : Optional;
import domain.companies;
import domain.errors : NotFound;
import domain.tenancy;
import usecases.system : Clock, IdGenerator;
import usecases.uow : UnitOfWork;

/// Where companies are kept.
interface CompanyRepository
{
    void add(Company company);

    /// The company of `tenant`, if it exists.
    Optional!Company find(Tenant tenant);
}

/// Where memberships are kept. Everything here is owned by a company, so every method takes its `Tenant`.
interface MembershipRepository
{
    void add(Tenant tenant, Membership membership);

    /// The members of the company, oldest first.
    Membership[] list(Tenant tenant);
}

/// Creates a company and makes the user who asked its owner: two tables, written together or not at all.
final class CreateCompany
{
    private UnitOfWork uow;
    private CompanyRepository companies;
    private MembershipRepository memberships;
    private Clock clock;
    private IdGenerator ids;

    this(UnitOfWork uow, CompanyRepository companies, MembershipRepository memberships, Clock clock, IdGenerator ids)
    {
        this.uow = uow;
        this.companies = companies;
        this.memberships = memberships;
        this.clock = clock;
        this.ids = ids;
    }

    Company execute(long userId, NewCompany input)
    {
        checkRules(input);
        auto company = Company(ids.newId(), input.name, clock.now());
        uow.run(() {
            companies.add(company);
            memberships.add(company.tenant, Membership(company.id, userId, Role.owner, company.createdAt));
        });
        return company;
    }
}

/// The company the actor is acting in.
final class GetCompany
{
    private CompanyRepository companies;

    this(CompanyRepository companies)
    {
        this.companies = companies;
    }

    Company execute(Actor actor)
    {
        auto found = companies.find(actor.tenant);
        if (!found.has)
            throw new NotFound("company not found");
        return found.get;
    }
}

/// The members of the actor's company: for its admins and owners.
final class ListMembers
{
    private MembershipRepository memberships;

    this(MembershipRepository memberships)
    {
        this.memberships = memberships;
    }

    Membership[] execute(Actor actor)
    {
        require(canSeeMembers(actor), "only an admin or the owner sees the members");
        return memberships.list(actor.tenant);
    }
}
