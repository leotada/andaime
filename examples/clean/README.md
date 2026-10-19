# clean

An [andaime](https://github.com/leotada/andaime) application in the clean template. The folders are the layers of
Clean Architecture, and dependencies point inward only:

```
source/
  domain/          entities and business rules              imports only andaime.values
  usecases/        what the application does, and its ports  imports domain/
  adapters/        HTTP, Postgres, memory, jobs              imports usecases/, domain/ and andaime
  app.d            the composition root (buildApp)           imports anything
  main.d, jobs.d, config.d   the process
tests/             dub test
migrations/        SQL, applied in order
```

A feature is the same file name in every layer: `domain/users.d`, `usecases/users.d`, `adapters/http/users.d`...

## Run

```sh
# without a database: the data lives in memory
STORE=memory dub run -- --role=all

# with PostgreSQL: create the tables, then serve
export DATABASE_URL="dbname=clean"
for f in migrations/*.sql; do psql "$DATABASE_URL" -f "$f"; done
dub run
dub run -- --role=worker                    # in another terminal: runs the background jobs
```

The API is under `/api/v1`, and its documentation at `/docs` (OpenAPI at `/openapi.json`).

## Test

```sh
dub test                                    # HTTP end to end and the repository contract, in memory
TEST_DATABASE_URL="dbname=clean_test" dub test   # also on Postgres, after its migrations (its tables are emptied)
```

## Grow

```sh
andaime generate resource post title:string "body:string?" views:int
andaime generate usecase users ArchiveUser
andaime generate job users SendDigest user_id:long --every 1.hours
andaime routes                              # every route and its handler
andaime check                               # the dependency rule, from andaime.json
```
