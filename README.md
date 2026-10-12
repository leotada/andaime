# dapi

O código usa o nome provisório **vela** (pacote DUB e `import vela;`).

Micro framework web em D com ergonomia estilo FastAPI: a assinatura da função é o
contrato HTTP, e o dispatch é gerado em tempo de compilação.

```d
import vela;

struct UserInput { @minLength(2) string name; @inRange(0, 150) int age; }
struct User { long id; string name; int age; }

User getUser(long id) { ... }                                   // GET /users/{id}
WithStatus!User createUser(JsonBody!UserInput body) { ... }     // POST /users -> 201

void main()
{
    auto app = new App;
    app.get!("/users/{id}", getUser);
    app.post!("/users", createUser);
    app.serve(8080);
}
```

## Potencial

**Para quem escreve a API**
- Assinatura é contrato: parâmetros de caminho, query, headers e corpo JSON tipado são extraídos e validados
  a partir dos tipos e nomes da função. Erro de entrada vira 422 no formato do FastAPI; o handler só roda com dados válidos.
- Documentação que não desatualiza: o `openapi.json` e o Swagger UI saem das mesmas assinaturas que geram o dispatch.
- Respostas fluidas: devolva `string`, struct, array, `WithStatus!T` ou `Response`; `throw new HttpError(...)` para falhas.
- Erros de compilação de uma linha dizendo o que corrigir, bons para humanos e para agentes de IA (sem *backtrace*
  de templates), e tipos previsíveis que mantêm o `serve-d` responsivo.

**Para quem opera o servidor**
- Não bloqueia: um fiber por requisição; banco, API externa e DNS suspendem só o fiber, qualquer que seja o número
  de requisições em voo. Trabalho pesado vai para um pool de threads limitado (`offload`), que recusa com `PoolSaturated`
  em vez de crescer sem teto.
- Memória pensada para VPS barata: buffers de rede reaproveitados, tabela de headers por fiber, teto de requisições
  em voo (503 + `Retry-After`). Medido: 1.000 requisições simultâneas em ~25 MB de RSS; o caminho quente não aloca no GC.
- Robusto por padrão: prazos de head/ocioso/escrita/requisição, proteção contra slowloris, cancelamento quando o
  cliente some (o `scope(exit)` do handler roda), parada graciosa, parser HTTP/1.1 zero-copy fuzzado com ASan.
- Compilação rápida: o `app.d` do exemplo compila em ~250 ms no DMD, porque o dispatch usa `static foreach` e
  `static if` rasos em vez de cadeias profundas de templates.

**Para crescer**
- Camadas separadas (`http` sem I/O, `web`, `engine`) e drivers opcionais fora do núcleo (`drivers/pg`): o `vela`
  não depende de libpq. Novos drivers e backends (kqueue, io_uring) entram sem mexer na camada de aplicação.
- Middleware em cebola com grupos de rotas, `ctx.locals`, CORS, arquivos estáticos e `onError`, tudo com D idiomático
  (slices, strings, delegates, DTOs), sem anotações defensivas de `@nogc`.

Comece por [docs/quickstart.md](docs/quickstart.md).

## Estado

Camada web completa e testada (M1). O M2 está fechado no Linux: `EpollLoop` com epoll
edge-triggered, um fiber por requisição, `SO_REUSEPORT`, prazos, teto de requisições em voo,
cancelamento, header `Date`, detector de loop travado, limpeza de memória depois de rajadas e
parada graciosa. Faltam o kqueue (M5) e o io_uring (M6). Fora do Linux, `serve` cai no servidor
de desenvolvimento bloqueante.

O M3 também está pronto no Linux: pool de threads limitado (`offload`), driver PostgreSQL sobre
libpq assíncrona (pacote separado `vela-pg`, em `drivers/pg`) e cliente HTTP/HTTPS cooperativo (`httpClient()`). Os três suspendem
só o fiber da requisição.

Dentro de um handler, esperar sem bloquear o worker:

```d
import core.time : msecs;
string slow() { sleep(500.msecs); return "ok"; }   // o worker atende outras conexões enquanto isso
```

### Banco, APIs externas e trabalho pesado (M3)

```d
import vela.db;                       // dependency "vela-pg" path="drivers/pg"; precisa de libpq5 instalada

struct User { int id; string name; Maybe!string email; }

string user(int id)
{
    auto db = pgPool("host=meu-rds.exemplo.rds.amazonaws.com dbname=app user=app");   // um pool por worker
    auto u = db.query("select id, name, email from users where id = $1", id).rowsAs!User;
    return u.length ? u[0].name : "?";
}

string cotacao()
{
    auto r = httpClient().get("https://api.exemplo.com/v1/cotacao");   // HTTPS verificado, keep-alive
    return r.ok ? r.body : "indisponível";
}

string pesado()
{
    return offload(() => calculoQueNaoDaParaFazerCooperativamente());   // pool de threads (configureOffload)
}
```

- Consultas usam parâmetros `$1..$n` em texto: nunca monte SQL com valores do usuário.
- Cliente some ou o prazo estoura no meio de uma consulta: o driver pede o cancelamento ao servidor e
  descarta a conexão. O mesmo vale para chamadas HTTP de saída (a conexão é fechada).
- libpq e OpenSSL são carregadas em tempo de execução (dlopen): o vela compila sem elas instaladas.
- `offload` lança `PoolSaturated` quando a fila enche; decida se isso vira 503.

### Aplicação real: grupos, locals, erros, CORS, estáticos, OpenAPI

Exemplo completo (Postgres + API externa + estáticos + docs): `examples/api`.

```d
auto app = new App;
app.use(accessLog());                       // log de acesso; requestId("X-Request-Id") propaga o id
app.use(cors(CorsConfig(["https://app.exemplo.com"])));   // preflight 204 antes do roteamento
app.onError((Context ctx, Exception e) { /* resposta de erro própria */ });
app.onNotFound((Context ctx) { /* 404 próprio */ });
app.redirectTrailingSlash();                // /users/ -> 308 /users/ (query preservada)

auto admin = app.group("/admin");           // prefixo literal (sem {param}); middlewares só valem p/ rotas registradas depois
admin.use((Context ctx, Next next) { ctx.locals.set(Usuario(bearerToken(ctx))); next(); });
admin.get!("/me", me);                      // UserResponse me(Local!Usuario u) { ... }  -> Local ausente = 500

app.serveStatic("/assets", "./public");     // ETag/304, Last-Modified, index, bloqueia .., dotfiles e symlinks que saem da raiz
app.serveOpenApi(OpenApiInfo("Minha API", "1.0"));   // /openapi.json (gerado dos handlers) e /docs (Swagger UI via CDN)
```

- Anotações para o OpenAPI/validação: `@summary`, `@jsonKey`, `@jsonIgnore`, `@optional`, `@minLength`, `@maxLength`, `@inRange`.
- `Expect: 100-continue` é respondido pelo motor; outro valor de `Expect` dá 417.
- `PgConfig.cacheStatements = true` usa statements preparados (até 128 por conexão, com nova tentativa
  se o plano for invalidado). Fica desligado por padrão: não use atrás de PgBouncer em modo transaction.
- Parser: `tests/fuzz/corpus/` (55 requisições de ataque, `<nome>.<ok|incomplete|status>.http`),
  fuzz de mutação com invariantes (`fuzz_parse.d [iterações] [semente]`) e libFuzzer+ASan com `tools/fuzz.sh [segundos]`.
- Limites conhecidos: corpo de requisição chunked não é suportado (501); `/docs` carrega o Swagger UI de um CDN;
  arquivos estáticos até 256 KiB são lidos no worker (maiores vão para o `offload`); handler só de CPU não é cancelável.

## Comandos

```sh
tools/check.sh                       # tudo: unittests, exemplo, alocação, rede, Postgres, cliente HTTP, memória, compile-fail, orçamento
                                     # (sobe um PostgreSQL descartável e um upstream Python; sem eles, esses testes são pulados)
DC=ldmd2 tools/check.sh              # o mesmo com LDC

cd examples/hello && dub run         # sobe o exemplo em http://localhost:8080
curl -X POST localhost:8080/users -d '{"name":"Ana","age":31}'
```

Testado com DMD 2.113 e LDC 1.43 (Linux x86_64).

Requisitos: um compilador D (DMD ou LDC) e DUB. O núcleo (`vela`) não precisa de banco algum. Só quem usa o driver opcional `vela-pg` precisa de `libpq5` em tempo de execução; para HTTPS de saída do cliente HTTP, OpenSSL 3 (ambas carregadas por dlopen).

## Pacotes

| Pacote        | Papel                                                       | Depende de |
|---------------|-------------------------------------------------------------|------------|
| `vela:http`   | tipos, parser HTTP/1.1 zero-copy, writer. Sem I/O.          | —          |
| `vela:web`    | App, router, introspecção de handlers, JSON, middleware     | http       |
| `vela:engine` | event loop, buffers, conexões, `offload`, cliente HTTP/TLS. Não conhece rotas. | http |
| `vela-pg` (`drivers/pg`) | driver PostgreSQL cooperativo (libpq assíncrona). **Pacote DUB independente**: o núcleo não depende dele nem do libpq | vela:engine |
| `vela`        | `import vela;` e `vela.server` (cola entre web e engine)    | todos      |

## Regras que os testes garantem

- O caminho quente do framework não aloca no GC (`tests/alloc/hot_path.d`).
- Assinatura inválida = erro de compilação de uma linha (`tests/compile_fail/`).
- `app.d` do exemplo compila em menos de 400 ms no DMD (`tools/check.sh`).
- O motor aguenta cancelamento, teto de requisições, prazos e escrita parcial (`tests/net/epoll_net.d`).
- O driver Postgres não bloqueia o worker, respeita o pool, cancela no servidor e descarta a conexão (`tests/db/pg_net.d`).
- O cliente HTTP/HTTPS não bloqueia, reaproveita conexões, repete em conexão velha e respeita prazos (`tests/net/client_net.d`).
- O parser sobrevive ao corpus de ataques e ao fuzz (`tests/fuzz/`), e o exemplo `examples/api` passa 31 checagens de ponta a ponta (`tests/example/api_e2e.py`).
- 1.000 requisições em voo cabem em menos de 30 MB de RSS (`tools/check.sh`, seção de memória).

## Spikes

- `spikes/epoll_fibers/`: epoll + um fiber por requisição, 10.000 requisições em voo (ver o README de lá).

## Armadilhas

- Tabelas de funções carregadas por dlopen ficam numa `struct`, nunca em variáveis `extern (C)` soltas:
  uma variável `extern (C)` chamada `ERR_clear_error` vira símbolo global e a própria libssl passa a chamá-la.
- Um `Group.use` só afeta rotas registradas depois dele (semântica do Express).
- `pgPool`/`httpClient` são thread-local (um por worker); não passe conexões entre workers.

- Variáveis de módulo em D são thread-local: com vários workers, cada um tem a sua cópia.
- Um `get`/`post` seu na mesma unidade esconde o `get`/`post` do vela; use `vela.get!(...)(app)`.
- Código bloqueante num handler (um `Thread.sleep`, uma lib C síncrona) trava o worker inteiro.
  O loop avisa no log quando um handler passa de `stallWarnMs` (50 ms) sem ceder.
  Esperas de I/O passam por `sleep`/`awaitFd`. Um handler que passa de `requestTimeoutMs` sem esperar
  nada só é cancelado quando voltar a esperar.
- O GC do D interrompe `read`/`send` bloqueantes (clientes de teste, ferramentas) com `EINTR`; trate-o.
- `Header!"X"` e `const(char)[]` são fatias do buffer de rede, válidas só durante a
  requisição. Use `string` (copiado) ou `.idup` para guardar.
- Handlers são funções de módulo, lambdas (podem capturar variáveis locais) ou
  métodos de controllers com `@Get(...)` montados via `app.mount(obj)`.

## Licença

[MIT](LICENSE).
