/// Users in memory, in one thread: for tests, and for `STORE=memory`.
/// It behaves like the Postgres repository: `tests/users.d` runs the same contract on both.
module adapters.memory.users 2025;

@safe:

import andaime.values.optional : Optional;
import domain.errors : Conflict;
import domain.users;
import usecases.users : UserRepository;

final class MemoryUserRepository : UserRepository
{
    private User[] rows; // ordered by id
    private long lastId;

    /// What the store holds now, as a function that puts it back (`MemoryUnitOfWork` rolls back with it). Ids are not
    /// reused, like a sequence's.
    void delegate() @safe snapshot()
    {
        auto saved = rows.dup;
        return () { rows = saved.dup; };
    }

    User[] list(int limit, int offset)
    {
        immutable from = offset < rows.length ? cast(size_t) offset : rows.length;
        immutable to = from + limit < rows.length ? from + limit : rows.length;
        return rows[from .. to].dup;
    }

    Optional!User find(long id)
    {
        foreach (row; rows)
            if (row.id == id)
                return Optional!User(row);
        return Optional!User.none;
    }

    User add(NewUser user)
    {
        checkUnique(User(0, user.name, user.email));
        auto row = User(++lastId, user.name, user.email);
        rows ~= row;
        return row;
    }

    bool update(User user)
    {
        foreach (ref row; rows)
            if (row.id == user.id)
            {
                checkUnique(user);
                row = user;
                return true;
            }
        return false;
    }

    bool remove(long id)
    {
        foreach (i, row; rows)
            if (row.id == id)
            {
                rows = rows[0 .. i] ~ rows[i + 1 .. $];
                return true;
            }
        return false;
    }

    /// The unique columns (email): a value another user already has is a `Conflict`, as in Postgres.
    private void checkUnique(User user)
    {
        foreach (row; rows)
            if (row.id != user.id && row.email == user.email)
                throw new Conflict("a user with the same email already exists");
    }
}
