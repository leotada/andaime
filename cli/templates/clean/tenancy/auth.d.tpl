/// Who is calling, for the routes that need to know: the `Actor` of the domain, built from the request.
///
/// REPLACE `devAuth` BEFORE PRODUCTION. It trusts three headers that any client can send (`X-User-Id`, `X-Company-Id`,
/// `X-Role`), so it only stands in for real authentication (a session cookie, a verified JWT) while the rest is built.
/// The real middleware sets the same `AuthContext`, so nothing else changes.
module adapters.http.auth 2025;

@safe:

import std.conv : ConvException, to;
import andaime;
import domain.tenancy : Actor, Role, Tenant;

/// What the authentication found: the user, and the company they act in (with their role there), if they chose one.
struct AuthContext
{
    long userId;
    Optional!Tenant tenant;
    Role role;
}

/// The development stand-in described above: 401 without `X-User-Id`.
Middleware devAuth()
{
    return (Context ctx, Next next) {
        auto user = ctx.request.header("x-user-id");
        if (user.length == 0)
            throw new HttpError(401, "missing X-User-Id (adapters/http/auth.d stands in for real authentication)");
        AuthContext auth;
        try
            auth.userId = user.to!long;
        catch (ConvException)
            throw new HttpError(401, "X-User-Id is not a number");
        auto company = ctx.request.header("x-company-id");
        if (company.length)
        {
            Uuid id;
            if (!Uuid.fromString(company, id))
                throw new HttpError(401, "X-Company-Id is not a UUID");
            auth.tenant = Optional!Tenant(Tenant(id));
        }
        switch (ctx.request.header("x-role"))
        {
            case "admin": auth.role = Role.admin; break;
            case "owner": auth.role = Role.owner; break;
            default: auth.role = Role.member; break;
        }
        ctx.locals.set(auth);
        next();
    };
}

/// The actor of a request made in a company; 400 when the request did not say which.
Actor actorOf(const AuthContext auth)
{
    if (!auth.tenant.has)
        throw new HttpError(400, "pick a company: X-Company-Id");
    return Actor(auth.userId, auth.tenant.get, auth.role);
}
