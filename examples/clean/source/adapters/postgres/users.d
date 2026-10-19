/// Users in PostgreSQL (andaime:pg). The table comes from `migrations/0001_users.sql`.
module adapters.postgres.users 2025;

@safe:

import andaime.db;
import andaime.values.optional : Optional;
import domain.errors : Conflict;
import domain.users;
import usecases.users : UserRepository;

final class PgUserRepository : UserRepository
{
    private PgPool db;

    this(PgPool db)
    {
        this.db = db;
    }

    User[] list(int limit, int offset)
    {
        return db.query(`select id, name, email from users order by id limit $1 offset $2`, limit, offset)
            .rowsAs!User;
    }

    Optional!User find(long id)
    {
        auto rows = db.query(`select id, name, email from users where id = $1`, id).rowsAs!User;
        return rows.length ? Optional!User(rows[0]) : Optional!User.none;
    }

    User add(NewUser user)
    {
        try
            return db.query(`insert into users (name, email) values ($1, $2) returning id, name, email`,
                user.name, user.email).one!User;
        catch (PgError e)
            throw conflictOr(e);
    }

    bool update(User user)
    {
        try
            return db.query(`update users set name = $2, email = $3 where id = $1 returning id`,
                user.id, user.name, user.email).rows == 1;
        catch (PgError e)
            throw conflictOr(e);
    }

    bool remove(long id)
    {
        return db.query(`delete from users where id = $1 returning id`, id).rows == 1;
    }
}

/// A unique violation is the domain's `Conflict`; any other database error goes on as it is.
private Exception conflictOr(PgError e)
{
    if (e.isUniqueViolation)
        return new Conflict("a user with the same email already exists");
    return e;
}
