/// Users over HTTP: the routes, the JSON a client sends and receives, and the calls to the use cases.
module adapters.http.users 2025;

@safe:

import andaime;
import adapters.http.paging : Page;
import domain.users : NewUser, User;
import usecases.users;

/// What a client sends to create or replace a user. Validation attributes (`@minLength`, `@inRange`...) on these
/// fields check the request's format and answer 422.
struct UserIn
{
    string name;
    string email;
}

/// What a client receives.
struct UserOut
{
    long id;
    string name;
    string email;
}

// The fields of the same name and type, checked at compile time: a field the domain gains and the DTO lacks stays
// behind; a DTO field the domain lacks does not compile (write that conversion by hand).
UserOut toOut(User user) => copyAs!UserOut(user);

NewUser toNew(UserIn input) => copyAs!NewUser(input);

/// The `/users` routes; `app.d` mounts them under `/api/v1`.
final class UserController
{
    private ListUsers listUsers;
    private GetUser getUser;
    private CreateUser createUser;
    private UpdateUser updateUser;
    private DeleteUser deleteUser;

    this(ListUsers listUsers, GetUser getUser, CreateUser createUser, UpdateUser updateUser, DeleteUser deleteUser)
    {
        this.listUsers = listUsers;
        this.getUser = getUser;
        this.createUser = createUser;
        this.updateUser = updateUser;
        this.deleteUser = deleteUser;
    }

    @Get("/users") @summary("List users")
    UserOut[] list(Query!Page page)
    {
        UserOut[] result;
        foreach (user; listUsers.execute(page.limit, page.offset))
            result ~= toOut(user);
        return result;
    }

    @Get("/users/{id}") @summary("Get a user") @responds(404, "user not found")
    UserOut get(long id) => toOut(getUser.execute(id));

    @Post("/users") @status(201) @summary("Create a user") @responds(409, "a unique value is taken")
    UserOut create(JsonBody!UserIn body_) => toOut(createUser.execute(toNew(body_)));

    @Put("/users/{id}") @summary("Replace a user") @responds(404, "user not found")
    @responds(409, "a unique value is taken")
    UserOut update(long id, JsonBody!UserIn body_) => toOut(updateUser.execute(id, toNew(body_)));

    @Delete("/users/{id}") @status(204) @summary("Delete a user") @responds(404, "user not found")
    void remove(long id)
    {
        deleteUser.execute(id);
    }
}
