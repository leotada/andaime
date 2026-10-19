/// Companies over HTTP. These routes know who calls (`Local!AuthContext`, set by `adapters/http/auth.d`) and hand the
/// use cases an `Actor`.
module adapters.http.companies 2025;

@safe:

import andaime;
import adapters.http.auth : AuthContext, actorOf;
import domain.companies : Company, Membership, NewCompany;
import domain.tenancy : Role;
import usecases.companies;

/// What a client sends to create a company.
struct CompanyIn
{
    @minLength(1) string name;
}

/// What a client receives.
struct CompanyOut
{
    Uuid id;
    string name;
    Timestamp createdAt;
}

/// One member, as a client sees it.
struct MemberOut
{
    long userId;
    Role role;
    Timestamp joinedAt;
}

CompanyOut toOut(Company c) => CompanyOut(c.id, c.name, c.createdAt);

MemberOut toOut(Membership m) => MemberOut(m.userId, m.role, m.joinedAt);

/// The `/companies` routes; `app.d` mounts them under `/api/v1`, behind the authentication middleware.
final class CompanyController
{
    private CreateCompany createCompany;
    private GetCompany getCompany;
    private ListMembers listMembers;

    this(CreateCompany createCompany, GetCompany getCompany, ListMembers listMembers)
    {
        this.createCompany = createCompany;
        this.getCompany = getCompany;
        this.listMembers = listMembers;
    }

    @Post("/companies") @status(201) @summary("Create a company; the caller becomes its owner")
    CompanyOut create(Local!AuthContext auth, JsonBody!CompanyIn body_)
        => toOut(createCompany.execute(auth.userId, NewCompany(body_.name)));

    @Get("/companies/current") @summary("The company the caller acts in") @responds(404, "company not found")
    CompanyOut current(Local!AuthContext auth) => toOut(getCompany.execute(actorOf(auth)));

    @Get("/companies/current/members") @summary("The members of the caller's company (admins and owners)")
    @responds(403, "only an admin or the owner sees the members")
    MemberOut[] members(Local!AuthContext auth)
    {
        MemberOut[] result;
        foreach (m; listMembers.execute(actorOf(auth)))
            result ~= toOut(m);
        return result;
    }
}
