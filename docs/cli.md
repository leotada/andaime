# The andaime command

`andaime` is an optional command line tool, in the spirit of `rails new` and `rails generate`. It creates projects from
templates, grows them with generators, lists the routes of any andaime app, and checks the dependency rule of a project.
The framework does not depend on it, and a generated project is plain code that you own: delete the tool and the
project still builds.

## Install

andaime is not on code.dlang.org yet, so build the command from your checkout:

```sh
cd andaime
dub build :cli                 # cli/bin/andaime; put it on your PATH
```

## `andaime new`

```sh
andaime new my-api                         # the clean template, with PostgreSQL
andaime new my-api --db none               # in memory only: no database to set up
andaime new my-api --jobs                  # with background jobs (andaime:jobs) from the start
andaime new my-api --template minimal      # one module of routes and handlers
andaime new my-api --template ../my-template
```

- `--template`: `clean` (the default, [architecture.md](architecture.md)), `minimal`, or the folder of your own template.
- `--db`: `pg` (the default) or `none`.
- `--andaime-path`: where the project finds andaime, written into its `dub.sdl`. By default it is the checkout the command
  was built from.

The folder's name is the package name. The project gets an `andaime.json` that records the template, the options and
the layer rules of `andaime check`.

## `andaime generate`

```sh
andaime generate resource user name:string email:string:unique "bio:string?"
andaime generate usecase users ArchiveUser
andaime generate job users SendWelcome user_id:long
andaime generate job users SendDigest --every 1.hours --queue mail
andaime generate job users PurgeOld --cron "0 3 * * *"
```

`g`, `r`, `u` and `j` are short for `generate`, `resource`, `usecase` and `job`. A **field** is `name:type`,
`name:type?` (may be absent: `Optional!T` and a nullable column) or `name:type:unique`. The types are `string`, `int`,
`long`, `bool` and `double`. Quote a field with `?` for the shell. A **feature** is the plural of a resource (`users`,
`blog_posts`): the file name in each layer.

| Generator | Writes (clean template) |
|-----------|-------------------------|
| `resource <name> <field>...` | `domain/`, `usecases/`, `adapters/http/`, `adapters/postgres/` and `adapters/memory/` files, a numbered migration, `tests/<plural>.d` (HTTP end to end and the repository contract), and the wiring in `app.d` |
| `usecase <feature> <Name> [<field>...]` | a use case class appended to `usecases/<feature>.d`, a test skeleton in `tests/<feature>.d` |
| `job <feature> <Name> [<field>...]` | the use case (unless it exists), the job struct in `adapters/jobs/<feature>.d` (the fields are its payload), its test in `tests/<feature>_jobs.d`, and the wiring in `jobs.d`. The first job also installs the jobs runtime: `andaime:jobs` in `dub.sdl`, `jobs.d` (process roles, the job store), and `main` serving through it |

- `--dry-run` shows what would change and writes nothing.
- A file that `generate` would create and that exists stops the whole run before anything is written. `--force`
  overwrites such files; the lines it inserts are never inserted twice.
- `--plural` gives a plural the simple English rules get wrong: `andaime g r person name:string --plural people`.
- `--queue` (default `default`), `--every` (`15.minutes`, `1.hours`...) and `--cron` (five fields) set a job's queue and
  schedule ([jobs-and-cron.md](jobs-and-cron.md)). A process runs the queues of `--queues` (`default:5` unless given).

Generators insert lines before **markers**, comments such as `// andaime:mount` in `app.d` or `// andaime:jobs` in
`jobs.d`. Keep them. If one is gone, the command prints the lines for you to add by hand.

## `andaime routes`

```sh
andaime routes            # in the folder of any andaime app, generated or not
andaime routes users      # only the lines that contain "users"
```

```
GET     /api/v1/users       adapters.http.users.UserController.list
POST    /api/v1/users       adapters.http.users.UserController.create
GET     /openapi.json       (andaime: OpenAPI)
```

It runs the app (`dub run`) with `ANDAIME_ROUTES=1`: `serve` then builds the app once, prints its route table and
returns without opening a port ([routing.md](routing.md#debugging)). Code in `main` before `serve` still runs.

## `andaime check`

```sh
andaime check
andaime check: domain.users imports andaime.web.application (domain may import: andaime.http.optional)
```

It compiles `source/` with `-deps` (type-checking only) and checks every import against the `layers` of `andaime.json`
([architecture.md](architecture.md#enforcing-the-rule)): one line per broken rule, and exit status 1. It uses `DC` (or
`dmd`, or `ldmd2`), and `dub describe` for the import paths. A layer may import its own modules, druntime and Phobos are
always allowed, and a glob `x.*` also matches `x` itself.

## Your own templates

A template is a folder of generators. Each generator is a subfolder with a `generator.json` and the files it renders:

```
my-template/
  new/generator.json             {"create": [{"tree": "files"}]}
  new/files/dub.sdl.tpl          every file under files/ becomes a file of the project (without .tpl)
  new/files/andaime.json.tpl
  resource/generator.json
  resource/controller.d.tpl
```

`generator.json` lists four kinds of action, run in this order:

```json
{
  "create":  [{ "path": "source/{{plural}}.d", "from": "module.d.tpl", "if": "pg" }],
  "append":  [{ "path": "source/usecases/{{feature}}.d", "from": "usecase.d.tpl", "unless": "class {{Name}}\n" }],
  "insert":  [{ "path": "source/app.d", "marker": "// andaime:mount", "text": "mount{{Name}}(app);\n" }],
  "replace": [{ "path": "source/main.d", "text": "serve(&buildApp, cfg);", "with": "serveWithJobs(args, cfg);" }]
}
```

- `create` writes a file (`tree` creates every file of a folder); `append` adds to the end of a file, creating it from
  `header` when it is missing, unless it already contains `unless`; `insert` puts the text before the marker line, with
  its indentation; `replace` changes the first occurrence. `text` may stand for `from`, `"if": "!pg"` negates a flag, and
  a `from` starting with `../` names another generator's file.
- Paths and contents are templates in a small subset of Mustache: `{{name}}`, `{{#list}}...{{/list}}` (also for a flag
  or a non-empty value), `{{^name}}...{{/name}}` (the opposite), and `first`/`last` inside a list. A section tag alone on
  its line takes the line with it. Any `{{` not followed by a name and `}}` is text, so D's `{{ }}` blocks pass through.
  A name that is not defined stops the run.
- The `andaime.json` your `new` generator writes needs `name`, `template` (`{{template}}`), `andaime_path`, `db` and
  `jobs`; `layers` is optional.
- `andaime generate <name> a b c` runs your template's generator `<name>` with the project's names plus `arg1`, `arg2`...
  The built-in names (`resource`, `usecase`, `job`) get the names listed below.

A project can also change one generator of its template: files in `.andaime/templates/<template>/<generator>/` replace
the template's files with the same path.

### The names a generator sees

| Generator | Names |
|-----------|-------|
| all | `app`, `appSnake`, `template`, `db`, `andaimePath`; flags `pg`, `jobs` |
| `resource` | `name`, `Name`, `camel`, `plural`, `Plural`, `pluralCamel`, `words`, `pluralWords`, `PluralWords`, `a`/`A` (the article), `path`, `table`, `migration`; the list `fields` (each `name`, `column`, `type`, `baseType`, `sqlType`, `sample1`..`sample4`, `json1`..`json4`, flags `optional`, `unique`) and `uniqueFields`; flags `hasUnique`, `hasOptional`, `hasRequired`; `uniqueText`; SQL: `selectList`, `insertColumns`, `insertParams`, `updateSets`; tests: `body1`, `body2`, `out1`, `out2`, `conflictBody`, `args1`..`args4`, `conflictArgs` |
| `usecase`, `job` | `feature`, `featureCamel`, `Entity`, `Name`, `instance`, `params`, `args`, `doc`, the list `fields`, flag `hasFields`; `job` adds `queue`, `schedule`, `payload` |
