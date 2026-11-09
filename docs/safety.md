# Memory safety and `@safe`

## `@safe` is recommended, not required

Handlers and middleware may be `@safe` or `@system`. The framework itself is `@safe`, and calls your code through a few small
`@trusted` call sites.

We recommend `@safe:` at the top of each module. The compiler then proves your handlers cannot corrupt memory, and the few lines
it cannot prove (a C call, a `__gshared` variable) go in a small `@trusted` function with a comment saying why it is sound:

```d
@safe:

import andaime;
import core.stdc.stdlib : getenv;
import core.stdc.string : strlen;

/// sound: getenv returns a NUL-terminated string or null, and the result is copied before returning
string env(const(char)* name) @trusted
{
    auto p = getenv(name);
    return p is null ? null : p[0 .. strlen(p)].idup;
}
```

The PostgreSQL driver, the HTTP client and `offload` are `@safe` to call. An `@system` handler can still call a C library
directly, without ceremony.

### Strict mode

To require `@safe` handlers in the whole app, add to `dub.sdl`:

```sdl
versions "AndaimeStrictSafe"
```

A `@system` handler then fails to compile with a one-line message. The old name, `VelaStrictSafe`, is an error that says
to rename it (it used to compile and drop the check).

### `-preview=dip1000`

The library, its tests and the examples type-check with `-preview=dip1000` (scoped pointers, the checks that
`scope` and `return scope` parameters do not escape), on DMD and LDC, and CI keeps it so. An application that builds with
the flag, or a test runner that turns it on (`unit-threaded` does), can use andaime and `AndaimeStrictSafe` together. A few
parameters that keep views into the caller's memory are not `scope` for that reason: the request parser's buffer and header
store, the multipart body (the parts point into it) and `Request.queryValues(name)`.

The code is written in language edition 2025 (`module x 2025;`, DMD 2.112 and later), which includes DIP1000. An
application in any edition can import andaime: a template follows the rules of the edition of the module that defines it,
not of the one that instantiates it.

## What you may keep from a request

| Value | Lifetime |
|-------|----------|
| Handler parameters (`string`, `const(char)[]`, text types, lists of them), `Header!"X"`, `Cookie!"x"`, `JsonBody!T`, `Query!T` and `Form!T` fields, `UploadedFile` (`filename`, `contentType`, `bytes`) | yours: copies on the GC heap |
| `ctx.request.path`, `.query`, `.target`, `.body`, `.header(...)`, `ctx.cookie(...)` | views into the connection's buffer, valid during the request |

**Everything a handler receives through its signature or a DTO is a copy.** Network buffers are pooled and reused, so a value
that pointed into one could change under you when the next request, from another user, lands in the same buffer. andaime
never hands you such a value through a parameter: a `string` or a `const(char)[]` is copied, a JSON string is decoded into
a new one, an uploaded file's bytes are copied, and the text a [text type](requests.md#your-own-types-dates-money) parses
is copied too when the type holds a slice or a pointer. You can put any of them in a cache, an audit record or an
in-memory queue.

The only views are the raw accessors on `ctx.request` and `ctx.cookie(...)`, which exist for code that wants to read
without allocating. Keeping one after the request is **memory-safe**: the buffer lives on the GC heap and stays allocated
while you hold it. But the buffer is reused, so the view may later show bytes of another request. Copy what you keep
(`.idup`).

### Text types and `scope`

`fromString` of a text type must take its text as `scope` (`static bool fromString(scope const(char)[] text, out T v)`): the
promise that it does not keep the text. A type that leaves out `scope` is refused with a one-line compile error, where
it is used as a parameter, a `Query!T` or `Form!T` field, or a JSON field, that says how to fix it. A type that holds no
slice and no pointer (`Uuid`, `Timestamp`, `CalendarDate`) reads the text in place and allocates nothing; one that does gets
a copy of the text, so it keeps nothing of the buffer even if its own code is compiled without `-preview=dip1000`.

The cost is the copy: a few bytes per `string` parameter or text, and the size of an uploaded file. A handler whose
parameters are numbers, enums, `bool` or `Uuid`-like values allocates nothing (`tests/alloc` checks it).

## Errors that are not exceptions

- A `RangeError`, a failed `assert` or another `Error` inside a handler answers 500, logs a full stack trace and retires the
  fiber (its cleanup may not have run). The server keeps serving.
- A fiber stack overflow (deep recursion) is a segmentation fault that ends the process; andaime first prints which request was
  running. Raise `ServerConfig.fiberStackBytes` (256 KiB) if you need deep recursion.

## Shared state

Module variables are thread-local, and `__gshared` data is `@system`. See [concurrency.md](concurrency.md#workers-and-state) for
sharing data between workers.
