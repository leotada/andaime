/// What the application does with users. One class per use case, with one `execute`; its constructor takes the
/// ports it needs. Imports the domain only: no framework, no database.
module usecases.users 2025;

@safe:

import andaime.values.optional : Optional;
import domain.errors : NotFound;
import domain.users;

/// Where users are kept: the port. `adapters/postgres/users.d` and
/// `adapters/memory/users.d` implement it, and `tests/users.d` checks that both behave the same.
interface UserRepository
{
    /// Users ordered by id: at most `limit`, skipping the first `offset`.
    User[] list(int limit, int offset);

    /// The user with this id, if there is one.
    Optional!User find(long id);

    /// Stores a new user and returns it with its id.
    /// Throws `Conflict` when a unique value is taken.
    User add(NewUser user);

    /// Replaces the stored user that has `user.id`; false when there is none.
    /// Throws `Conflict` when a unique value is taken.
    bool update(User user);

    /// Deletes the user; false when there was none.
    bool remove(long id);
}

/// Lists users, a page at a time.
final class ListUsers
{
    private UserRepository users;

    this(UserRepository users)
    {
        this.users = users;
    }

    User[] execute(int limit, int offset)
    {
        return users.list(limit, offset);
    }
}

/// One user by id.
final class GetUser
{
    private UserRepository users;

    this(UserRepository users)
    {
        this.users = users;
    }

    User execute(long id)
    {
        auto found = users.find(id);
        if (!found.has)
            throw new NotFound("user not found");
        return found.get;
    }
}

/// Creates a user.
final class CreateUser
{
    private UserRepository users;

    this(UserRepository users)
    {
        this.users = users;
    }

    User execute(NewUser input)
    {
        checkRules(input);
        return users.add(input);
    }
}

/// Replaces a user's values.
final class UpdateUser
{
    private UserRepository users;

    this(UserRepository users)
    {
        this.users = users;
    }

    User execute(long id, NewUser input)
    {
        checkRules(input);
        auto user = User(id, input.name, input.email);
        if (!users.update(user))
            throw new NotFound("user not found");
        return user;
    }
}

/// Deletes a user.
final class DeleteUser
{
    private UserRepository users;

    this(UserRepository users)
    {
        this.users = users;
    }

    void execute(long id)
    {
        if (!users.remove(id))
            throw new NotFound("user not found");
    }
}

/// Run by the job `SendWelcomeJob` (`adapters/jobs/users.d`).
final class SendWelcome
{
    private UserRepository users;

    this(UserRepository users)
    {
        this.users = users;
    }

    void execute(long userId)
    {
        // what SendWelcome does goes here
    }
}

/// Runs SendWelcome later, in the background: the port. Called inside a unit of work, the job is stored with the
/// transaction, or not at all (`adapters/jobs/users.d`).
interface SendWelcomeScheduler
{
    void schedule(long userId);
}
