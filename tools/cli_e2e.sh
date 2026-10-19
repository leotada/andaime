#!/usr/bin/env bash
# The andaime command end to end. Builds it, makes projects from every template, grows them with every generator, and
# runs dub test, dub build, andaime routes and andaime check in them. examples/clean must be exactly what the commands
# of step 1 generate: to change it, change the templates (cli/templates/clean/) and copy a fresh output over it.
# With ANDAIME_PG (and psql), the generated Postgres repository passes its contract and the binary serves on Postgres.
# Needs dub; skips (77) without it. Usage: DC=dmd tools/cli_e2e.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DC="${DC:-dmd}"
if ! command -v dub > /dev/null; then echo "skip: dub not installed" >&2; exit 77; fi
dubc="--compiler=${DC/ldmd2/ldc2}"

work=.cli-e2e # two levels under the repository: the projects reach it at ../..
rm -rf "$work"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
log="$PWD/$work/log"
A="$PWD/$work/andaime"

# run <command...>: quiet when it passes, the end of its output when it fails
run() {
    if ! "$@" > "$log" 2>&1; then
        echo "FAILED: $*"
        tail -40 "$log"
        exit 1
    fi
}

run $DC -i -Icli/source -Jcli/templates cli/source/andaime/cli/main.d -of"$A"
run $DC -unittest -i -Icli/source -Jcli/templates cli/source/andaime/cli/main.d -of"$work/andaime-test"
run "$work/andaime-test" --help
echo "ok  the CLI builds, its unittests pass"

for t in cli/templates/*/; do
    if ! diff <(cd "$t" && find . -type f ! -name MANIFEST | sed 's|^\./||' | LC_ALL=C sort) \
        <(grep -v '^#' "$t/MANIFEST" | grep . | LC_ALL=C sort) > "$log"; then
        echo "FAILED: ${t}MANIFEST does not list the template's files"; cat "$log"; exit 1
    fi
done
echo "ok  every template's MANIFEST lists its files"

# without --andaime-path a project depends on the registry release series, not on a path
run "$A" new "$work/registry" --db pg --jobs
if ! grep -q 'dependency "andaime" version="~>' "$work/registry/dub.sdl" \
    || ! grep -q 'dependency "andaime:pgjobs" version="~>' "$work/registry/dub.sdl" \
    || grep -q 'path=' "$work/registry/dub.sdl"; then
    echo "FAILED: a new project without --andaime-path should depend on the registry:"; cat "$work/registry/dub.sdl"; exit 1
fi
echo "ok  a new project depends on the registry release by default"

# ---------------------------------------------------------------- 1. clean, Postgres, jobs and tenancy: the golden example
run "$A" new "$work/clean" --db pg --jobs --tenant --andaime-path ../..
(cd "$work/clean" && run "$A" generate resource user name:string email:string:unique \
    && run "$A" generate job users SendWelcome user_id:long)
# the snapshot of tests/openapi.json is the app's own output, not a template file: `andaime openapi` makes it
(cd "$work/clean" && "$A" openapi > tests/openapi.json 2> "$log") || { echo "FAILED: andaime openapi"; cat "$log"; exit 1; }
if ! diff -r -u -x .dub -x dub.selections.json -x clean -x 'clean-test-*' examples/clean "$work/clean" > "$log"; then
    echo "FAILED: examples/clean is not what the generators make:"; head -60 "$log"; exit 1
fi
echo "ok  examples/clean is exactly the generators' output"

(cd "$work/clean" && run dub test $dubc -q && run dub build $dubc -q)
echo "ok  clean: andaime openapi wrote the snapshot that its dub test compares with"
# the snapshot test fails when the contract changes, and UPDATE_OPENAPI=1 accepts the change
cp "$work/clean/tests/openapi.json" "$work/openapi.json.keep"
sed -i 's/"title": "clean"/"title": "changed"/' "$work/clean/tests/openapi.json"
if (cd "$work/clean" && dub test $dubc -q > "$log" 2>&1); then echo "FAILED: a changed snapshot should fail dub test"; exit 1; fi
grep -q "UPDATE_OPENAPI=1" "$log" || { echo "FAILED: the snapshot failure does not say how to update it"; tail -20 "$log"; exit 1; }
(cd "$work/clean" && UPDATE_OPENAPI=1 run dub test $dubc -q)
cmp "$work/clean/tests/openapi.json" "$work/openapi.json.keep" || { echo "FAILED: UPDATE_OPENAPI=1 did not restore the snapshot"; exit 1; }
echo "ok  clean: a changed snapshot fails dub test; UPDATE_OPENAPI=1 rewrites it"
echo "ok  clean: dub test (HTTP, the memory repository contract, the job) and dub build"

routes=$(cd "$work/clean" && "$A" routes)
expected="POST    /api/v1/companies                  adapters.http.companies.CompanyController.create
GET     /api/v1/companies/current          adapters.http.companies.CompanyController.current
GET     /api/v1/companies/current/members  adapters.http.companies.CompanyController.members
GET     /api/v1/users                      adapters.http.users.UserController.list
GET     /api/v1/users/{id}                 adapters.http.users.UserController.get
POST    /api/v1/users                      adapters.http.users.UserController.create
PUT     /api/v1/users/{id}                 adapters.http.users.UserController.update
DELETE  /api/v1/users/{id}                 adapters.http.users.UserController.remove
GET     /openapi.json                      (andaime: OpenAPI)
GET     /docs                              (andaime: Swagger UI)"
if [[ "$routes" != "$expected" ]]; then echo "FAILED: andaime routes printed:"; echo "$routes"; exit 1; fi
if [[ $(cd "$work/clean" && "$A" routes "{id}" | wc -l) != 3 ]]; then echo "FAILED: andaime routes {id}"; exit 1; fi
echo "ok  andaime routes lists every route and its handler, and filters"

(cd "$work/clean" && run "$A" check)
printf '\nimport andaime : App;\n' >> "$work/clean/source/domain/users.d"
if out=$(cd "$work/clean" && "$A" check 2>&1); then echo "FAILED: andaime check accepted domain importing andaime"; exit 1; fi
if [[ "$out" != "andaime check: domain.users imports andaime (domain may import: andaime.values.*)" ]]; then
    echo "FAILED: andaime check printed:"; echo "$out"; exit 1
fi
cp examples/clean/source/domain/users.d "$work/clean/source/domain/users.d"
echo "ok  andaime check passes the layers, and names a forbidden import in one line"

# ---------------------------------------------------------------- 2. no database: every generator, jobs installed late
run "$A" new "$work/nodb" --db none --tenant --andaime-path ../..
(
    cd "$work/nodb"
    run "$A" g r blog_post title:string "body:string?" views:int published:bool rating:double
    run "$A" g u blog_posts PublishPost
    run "$A" g j blog_posts NotifyFollowers post_id:long "note:string?" --every 15.minutes
    run "$A" g j blog_posts Digest --cron "0 6 * * *" --queue reports
    run dub test $dubc -q
    run dub build $dubc -q
    run "$A" check
    grep -q "^GET     /api/v1/blog-posts/{id}" <("$A" routes) || { echo "FAILED: nodb routes"; exit 1; }

    # an existing file stops generate before it writes anything; --dry-run writes nothing; --force overwrites
    cp source/app.d "../app.before"
    if "$A" g r blog_post title:string > "../out" 2>&1; then echo "FAILED: generate overwrote a resource"; exit 1; fi
    grep -q "nothing was written" "../out" || { echo "FAILED: the refusal says:"; cat "../out"; exit 1; }
    cmp -s source/app.d "../app.before" || { echo "FAILED: a refused generate changed app.d"; exit 1; }
    run "$A" g r tag name:string --dry-run
    [[ ! -e source/domain/tags.d ]] && cmp -s source/app.d "../app.before" || { echo "FAILED: --dry-run wrote"; exit 1; }
    run "$A" g r blog_post title:string "body:string?" views:int published:bool rating:double --force
    cmp -s source/app.d "../app.before" || { echo "FAILED: --force inserted into app.d twice"; exit 1; }
)
echo "ok  no database: resource, usecase and jobs (installed by the first one) generate, test, build and check"

# ---------------------------------------------------------------- 3. minimal, and an app the CLI did not make
run "$A" new "$work/mini" --template minimal --andaime-path ../..
(cd "$work/mini" && run dub test $dubc -q && run dub build $dubc -q)
grep -q "^POST    /items  *app.createItem$" <(cd "$work/mini" && "$A" routes) || { echo "FAILED: minimal routes"; exit 1; }
grep -q "^GET     /users/{id}  *app.getUser$" <(cd examples/hello && "$A" routes) || { echo "FAILED: hello routes"; exit 1; }
echo "ok  minimal: test, build, routes; andaime routes on examples/hello"

# ---------------------------------------------------------------- 4. Postgres
if [[ -z "${ANDAIME_PG:-}" ]] || ! command -v psql > /dev/null || ! command -v curl > /dev/null; then
    echo "(the Postgres part needs ANDAIME_PG, psql and curl: skipped)"
    exit 0
fi
db="$ANDAIME_PG dbname=andaime_cli_e2e"
run psql "$ANDAIME_PG" -v ON_ERROR_STOP=1 -qc "drop database if exists andaime_cli_e2e" -c "create database andaime_cli_e2e"
for m in "$work"/clean/migrations/*.sql; do run psql "$db" -v ON_ERROR_STOP=1 -q -f "$m"; done
(cd "$work/clean" && TEST_DATABASE_URL="$db" run dub test $dubc -q)
echo "ok  Postgres: the repository contract"
# (dub test writes its test runner to ./clean, the app's own path: build the app again before starting it)
(cd "$work/clean" && run dub build $dubc -q)

port=$(( 18000 + RANDOM % 1000 ))
(cd "$work/clean" && DATABASE_URL="$db" PORT=$port exec ./clean --role=all) > "$work/server.log" 2>&1 &
server=$!
base="http://127.0.0.1:$port/api/v1"
status() { curl -s -o /dev/null -w "%{http_code}" "$@" || true; } # (a refused connection answers 000, not a dead script)
if ! curl -s --retry-connrefused --retry 30 --retry-delay 1 -o /dev/null "$base/users"; then
    echo "FAILED: the binary did not answer on port $port; it is ${server:+pid $server, }$(kill -0 $server 2> /dev/null && echo running || echo gone):"
    cat "$work/server.log"; kill -TERM $server 2> /dev/null || true; exit 1
fi
c1=$(status -X POST "$base/users" -d '{"name":"Ana","email":"ana@example.com"}')
c2=$(status -X POST "$base/users" -d '{"name":"Bia","email":"ana@example.com"}')
c3=$(status "$base/users/999")
c4=$(status -X POST "$base/users" -d '{"name":"Ana"}')
# --tenant: a company and its owner's membership, written in one unit of work; the members are for admins
company=$(curl -s -X POST "$base/companies" -H 'X-User-Id: 7' -d '{"name":"Acme"}' | sed -n 's/^{"id":"\([^"]*\)".*/\1/p')
c5=$(status "$base/companies/current/members" -H 'X-User-Id: 7' -H "X-Company-Id: $company" -H 'X-Role: owner')
c6=$(status "$base/companies/current/members" -H 'X-User-Id: 8' -H "X-Company-Id: $company")
kill -TERM $server; wait $server || true
if [[ "$c1 $c2 $c3 $c4 $c5 $c6" != "201 409 404 422 200 403" ]]; then
    echo "FAILED: on Postgres, the users and companies routes answered $c1 $c2 $c3 $c4 $c5 $c6 (expected 201 409 404 422 200 403)"
    tail -20 "$work/server.log"; exit 1
fi
run psql "$db" -v ON_ERROR_STOP=1 -qc "select 1 from memberships where user_id = 7 and role = 'owner'" # both tables written
run psql "$db" -qc "select count(*) from andaime_jobs" # the worker created its queue
run psql "$ANDAIME_PG" -qc "drop database andaime_cli_e2e"
echo "ok  Postgres: the binary serves (201, 409 from the unique column, 404, 422; a company with its owner, 403) and runs its job worker"
