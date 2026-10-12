# Quickstart

Do zero a uma API com validação, middleware, OpenAPI e arquivos estáticos em poucos minutos.
Tudo aqui foi compilado e testado com DMD 2.113 e LDC 1.43 em Linux x86_64.

> O código usa o nome provisório **vela** (`import vela;`); o repositório se chama `dapi`.

## 1. Pré-requisitos

- Um compilador D (DMD ou LDC) e o DUB.
- Linux para o servidor de produção (epoll). Em outros sistemas, `serve` cai num servidor de desenvolvimento bloqueante.
- Nada mais. Banco de dados é um pacote opcional (veja a seção 8).

## 2. Projeto novo

```sh
git clone https://github.com/leotada/dapi
mkdir minha-api && cd minha-api
```

`dub.sdl`:

```sdl
name "minha-api"
targetType "executable"
dependency "vela" path="../dapi"
```

## 3. Primeira rota

`source/app.d`:

```d
import vela;

string ola(string nome = "mundo") => "olá, " ~ nome;

void main()
{
    auto app = new App;
    app.get!("/ola", ola);
    app.serve(8080);
}
```

```sh
dub run
curl 'localhost:8080/ola?nome=Ana'     # olá, Ana
```

Não existe `req.query["nome"]` aqui: a **assinatura da função é o contrato HTTP**. O parâmetro `nome`
não está na rota, então vem da query string; o valor padrão o torna opcional.

## 4. De onde vem cada parâmetro

| Na assinatura                         | O vela extrai                                         |
|---------------------------------------|-------------------------------------------------------|
| `long id` com `{id}` na rota          | parâmetro de caminho, convertido e validado           |
| `int limit = 20` (fora da rota)       | query string; o default a torna opcional              |
| `JsonBody!UserInput body_`            | corpo JSON tipado, validado pelas anotações do struct |
| `Header!"Authorization" auth`         | header, sem cópia (fatia do buffer de rede)           |
| `Optional!X`                          | presente ou ausente, sem erro                         |
| `Local!T`                             | valor posto por um middleware em `ctx.locals`         |
| `Context ctx`                         | acesso direto a request/response                      |

Falhou a conversão ou a validação? O cliente recebe **422** no formato do FastAPI, e o seu handler nem roda.

## 5. Um CRUD pequeno com JSON

```d
import vela;

struct UserInput
{
    @minLength(2) @maxLength(60) string name;
    @inRange(0, 150) int age;
    Optional!string email;
}

struct User { long id; string name; int age; Optional!string email; }

private User[long] users;     // atenção: variável de módulo é thread-local; veja "Armadilhas" no README
private long nextId = 1;

User getUser(long id)
{
    if (auto u = id in users) return *u;
    throw new HttpError(404, "usuário não encontrado");
}

WithStatus!User createUser(JsonBody!UserInput body_)      // 201
{
    auto u = User(nextId++, body_.name, body_.age, body_.email);
    users[u.id] = u;
    return withStatus(201, u);
}

void deleteUser(long id)                                   // void => 204
{
    if (!users.remove(id)) throw new HttpError(404, "usuário não encontrado");
}

void main()
{
    auto app = new App;
    app.get!("/users/{id}", getUser);
    app.post!("/users", createUser);
    app.del!("/users/{id}", deleteUser);

    ServerConfig cfg;
    cfg.port = 8080;
    cfg.workers = 1;          // o "banco" é uma variável de módulo; com banco de verdade, deixe 0 (um por núcleo)
    app.serve(cfg);
}
```

```sh
curl -X POST localhost:8080/users -d '{"name":"Ana","age":31}'     # 201 {"id":1,...}
curl -X POST localhost:8080/users -d '{"name":"A","age":200}'      # 422 com os dois erros
curl localhost:8080/users/1
```

**O que cada retorno vira:** `void` → 204 · `string` → texto · struct/array → JSON ·
`WithStatus!T` → JSON com o status escolhido · `Response` → controle total · `throw new HttpError(status, msg)`.

## 6. Middleware, grupos e dados por requisição

Middleware é uma função `void(Context, Next)` em camadas (cebola):

```d
void logger(Context ctx, Next next)
{
    next();
    // depois da resposta: ctx.response.status já está definido
}

auto api = app.group("/api/v1");
api.use((Context ctx, Next next) {
    auto token = bearerToken(ctx);
    if (token.length == 0) throw new HttpError(401, "token ausente");
    ctx.locals.set(Caller(token.idup));     // guardado, tipado, para esta requisição
    next();
});

string quemSou(Local!Caller c) => c.token;  // o handler recebe o valor pronto
api.get!("/quem", quemSou);
```

Já vêm prontos: `accessLog()`, `requestId()`, `cors(CorsConfig(...))`. Erros: `app.onError(...)`,
`app.onNotFound(...)`; `app.redirectTrailingSlash = true` liga o 308 para barra final.

## 7. Estáticos e documentação automática

```d
app.serveStatic("/assets", "public");                       // ETag/304, index.html, bloqueia traversal
app.serveOpenApi(OpenApiInfo("Minha API", "1.0.0"));        // /openapi.json e /docs (Swagger UI)
```

O OpenAPI é montado a partir das **mesmas assinaturas** que geram o dispatch: rotas, parâmetros, corpos,
validações (`@minLength`, `@inRange`...) e `@summary("...")`. Não há segunda fonte de verdade para ficar desatualizada.

## 8. Banco, API externa e trabalho pesado sem travar o servidor

Cada requisição roda num *fiber*. Esperar rede suspende só aquele fiber, nunca o worker:

```d
// dub.sdl:  dependency "vela-pg" path="../dapi/drivers/pg"     (pacote opcional; precisa de libpq5)
import vela.db;

string usuario(int id)
{
    auto db = pgPool("host=meu-rds.exemplo.com dbname=app user=app");
    auto linhas = db.query("select name from users where id = $1", id);   // parâmetros $1..$n: sem SQL injection
    return linhas.rows ? linhas.get!string(0, 0) : "?";
}

Response cotacao()
{
    auto r = httpClient().get("https://api.exemplo.com/v1/cotacao");      // HTTPS verificado, keep-alive
    return Response(r.status, "application/json", r.body);
}

string pesado() => offload(() => calculoCaro());                         // pool de threads limitado
```

Cliente desconectou ou o prazo estourou no meio de uma consulta? O driver cancela no servidor e descarta a conexão.

## 9. Configuração do servidor

```d
ServerConfig cfg;
cfg.port = 8080;
cfg.workers = 0;            // 0 = um por núcleo (SO_REUSEPORT)
cfg.maxInFlight = 1024;     // acima disso: 503 + Retry-After
cfg.requestTimeoutMs = 30_000;
app.serve(cfg);
```

Há prazos para head, ocioso, escrita e requisição; parada graciosa por SIGINT/SIGTERM; e um aviso no log
quando um handler segura o worker por mais de 50 ms sem ceder (código bloqueante).

## 10. Erros de compilação legíveis

Assinatura inválida vira uma linha explicando o que corrigir, sem *backtrace* de templates:

```
web/source/vela/web/application.d(398): Error: static assert:  "app.d(4): vela: handler 'getUser' em GET /users/{id}: a rota declara {id}, mas a função não tem parâmetro chamado 'id'"
app.d(4):        instantiated from here: `get!("/users/{id}", getUser, ...)`
```

Os casos estão em `tests/compile_fail/` (cada um confere a mensagem e que não passa de 2 linhas de erro).

## 11. Rodar os testes e os exemplos

```sh
tools/check.sh                 # tudo: unittests, rede, Postgres, cliente HTTP, fuzz, e2e, memória, compile-fail
DC=ldmd2 tools/check.sh        # o mesmo com LDC
cd examples/hello && dub run   # CRUD em memória
cd examples/api   && dub run   # API real: Postgres + API externa + CORS + estáticos + OpenAPI
```

Sem PostgreSQL, Python ou OpenSSL na máquina, os testes que dependem deles se declaram pulados.

## Próximos passos

- `examples/api/source/app.d`: a aplicação completa, com autenticação, banco e `onError` mapeando erros.
- `README.md`: referência de recursos, pacotes e armadilhas.
