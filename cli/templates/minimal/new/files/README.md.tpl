# {{app}}

An [andaime](https://github.com/leotada/andaime) application in one module: `source/app.d` holds the routes, the
handlers and their tests, and `source/main.d` serves them.

```sh
dub run                 # http://localhost:8080/items, documentation at /docs
dub test
andaime routes          # every route and its handler
```

When it grows, `andaime new <dir>` (the clean template) shows a structure in layers: domain, use cases, adapters.
