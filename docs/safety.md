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
| `string` parameters, `Header!"X"`, `Cookie!"x"`, JSON bodies decoded into `string` fields, `UploadedFile.filename`, `UploadedFile.contentType` | yours: copies on the GC heap |
| `ctx.request.path`, `.query`, `.body`, `.header(...)`, `ctx.cookie(...)`, `const(char)[]` parameters, `UploadedFile.bytes` | views into the connection's buffer, valid during the request |

Keeping a view after the request is **memory-safe**: the buffer lives on the GC heap and stays allocated while you hold it. But
the buffer is reused, so the view may later show bytes of another request. Copy what you keep (`.idup`).

## Errors that are not exceptions

- A `RangeError`, a failed `assert` or another `Error` inside a handler answers 500, logs a full stack trace and retires the
  fiber (its cleanup may not have run). The server keeps serving.
- A fiber stack overflow (deep recursion) is a segmentation fault that ends the process; andaime first prints which request was
  running. Raise `ServerConfig.fiberStackBytes` (256 KiB) if you need deep recursion.

## Shared state

Module variables are thread-local, and `__gshared` data is `@system`. See [concurrency.md](concurrency.md#workers-and-state) for
sharing data between workers.
