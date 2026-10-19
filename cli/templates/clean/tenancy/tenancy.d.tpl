/// Who acts, and for which company: the values the use cases decide permissions with. The HTTP adapter builds an `Actor`
/// from the request's authentication (`adapters/http/auth.d`); the domain's policies below decide what it may do.
module domain.tenancy 2025;

@safe:

import andaime.values.uuid : Uuid;
import domain.errors : Forbidden;

/// The company that owns some data. A repository method over data owned by a company takes its `Tenant`, so the
/// compiler makes every query say whose data it reads: forgetting the filter does not compile.
struct Tenant
{
    Uuid id;
}

/// What a member may do in a company, from least to most.
enum Role
{
    member,
    admin,
    owner,
}

/// The user acting on a request: who, in which company, with which role there.
struct Actor
{
    long userId;
    Tenant tenant;
    Role role;
}

/// The policies: what each role may do. Rules of the business, decided here, not in status codes.
bool canSeeMembers(const Actor actor) pure nothrow => actor.role >= Role.admin;

/// Throws `Forbidden` with `why` unless `allowed`.
void require(bool allowed, string why) pure
{
    if (!allowed)
        throw new Forbidden(why);
}
