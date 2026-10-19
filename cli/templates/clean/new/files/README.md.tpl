# {{app}}

An [andaime](https://github.com/leotada/andaime) application in the clean template. The folders are the layers of
Clean Architecture, and dependencies point inward only:

```
source/
  domain/          entities and business rules              imports only andaime.values
  usecases/        what the application does, and its ports  imports domain/
  adapters/        HTTP, {{#pg}}Postgres, {{/pg}}memory, jobs              imports usecases/, domain/ and andaime
  app.d            the composition root (buildApp)           imports anything
  main.d, jobs.d, config.d   the process
tests/             dub test
{{#pg}}
migrations/        SQL, applied in order
{{/pg}}
```

A feature is the same file name in every layer: `domain/users.d`, `usecases/users.d`, `adapters/http/users.d`...

## Run

```sh
{{#pg}}
# without a database: the data lives in memory
STORE=memory dub run{{#jobs}} -- --role=all{{/jobs}}

# with PostgreSQL: create the tables, then serve
export DATABASE_URL="dbname={{appSnake}}"
for f in migrations/*.sql; do psql "$DATABASE_URL" -f "$f"; done
dub run
{{#jobs}}
dub run -- --role=worker                    # in another terminal: runs the background jobs
{{/jobs}}
{{/pg}}
{{^pg}}
dub run                                     # the data lives in memory, in one worker
{{/pg}}
```

The API is under `/api/v1`, and its documentation at `/docs` (OpenAPI at `/openapi.json`).

## Test

```sh
{{#pg}}
dub test                                    # HTTP end to end and the repository contract, in memory
TEST_DATABASE_URL="dbname={{appSnake}}_test" dub test   # also on Postgres, after its migrations (its tables are emptied)
{{/pg}}
{{^pg}}
dub test                                    # HTTP end to end and the repository contract
{{/pg}}
```

## Grow

```sh
andaime generate resource post title:string "body:string?" views:int
andaime generate usecase users ArchiveUser
andaime generate job users SendDigest user_id:long --every 1.hours
andaime routes                              # every route and its handler
andaime check                               # the dependency rule, from andaime.json
```
