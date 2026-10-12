#!/usr/bin/env bash
# Verificação completa do vela. Uso: tools/check.sh   (DC=ldmd2 para usar o LDC)
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-dmd}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source -Idb/source"
fail=0

echo "== unittests dos módulos"
$DC -unittest -main $I -i -run engine/source/vela/engine/package.d
$DC -unittest -main $I -i -run web/source/vela/web/package.d
$DC -unittest -main $I -i -run db/source/vela/db/package.d

echo "== recursos da camada web (grupos, locals, onError, CORS, estáticos, OpenAPI, middlewares)"
for t in tests/web/*.d; do
    $DC -unittest -main $I -i -run "$t" > /dev/null 2>&1 || { echo "FALHOU: $t"; $DC -unittest -main $I -i -run "$t" 2>&1 | grep -v '^vela: erro em' | tail -15; fail=1; }
done
echo "ok  $(ls tests/web/*.d | wc -l) arquivos em tests/web"

echo "== parser HTTP: corpus de ataques e fuzz de mutação"
$DC $I -i -run tests/fuzz/corpus_test.d
$DC $I -Itests/fuzz -i -run tests/fuzz/fuzz_parse.d 300000

echo "== testes do exemplo (TestClient, sem rede)"
$DC -unittest -main $I -i -run examples/hello/source/app.d > /dev/null

echo "== caminho quente sem alocação no GC"
$DC $I -i -run tests/alloc/hot_path.d

echo "== testes de rede (EpollLoop + fibers: cancelamento, teto, prazos, pools)"
ulimit -n 20000 2>/dev/null || true
$DC $I -i -run tests/net/epoll_net.d

echo "== M3: PostgreSQL (libpq assíncrona), cliente HTTP/HTTPS e pool de threads"
tools/with_postgres.sh $DC $I -i -run tests/db/pg_net.d
tools/with_upstream.sh $DC $I -i -run tests/net/client_net.d

echo "== exemplo de API real de ponta a ponta (Postgres + API externa + auth + CORS + estáticos + OpenAPI)"
DC=$DC tools/with_postgres.sh tools/with_upstream.sh tools/api_e2e.sh

echo "== memória: 1.000 requisições em voo (meta do plano: RSS de pico < 30 MB)"
ulimit -n 20000 2>/dev/null || ulimit -n 4096 2>/dev/null || true
tmp=$(mktemp -d)
$DC -O -release tests/net/loadgen.d -of"$tmp/loadgen" > /dev/null
$DC -O -release $I -i -of"$tmp/serve_slow" tests/net/serve_slow.d > /dev/null
port=$(( 18700 + RANDOM % 200 ))
"$tmp/serve_slow" "$port" 1500 > "$tmp/srv.log" 2>&1 &
srv=$!
sleep 0.5
idle=$(awk '/VmRSS/{print $2}' /proc/$srv/status)
( while kill -0 $srv 2>/dev/null; do awk '/VmRSS/{print $2}' /proc/$srv/status 2>/dev/null; sleep 0.1; done > "$tmp/rss" ) &
if ! "$tmp/loadgen" "$port" 1000 500 1500 > "$tmp/load.log" 2>&1; then
    echo "FALHOU: carga de 1.000 requisições"; cat "$tmp/load.log"; fail=1
fi
peak=$(sort -n "$tmp/rss" | tail -1)
sleep 1
after=$(awk '/VmRSS/{print $2}' /proc/$srv/status)
kill -INT $srv
for _ in $(seq 1 30); do kill -0 $srv 2>/dev/null || break; sleep 0.1; done
if kill -0 $srv 2>/dev/null; then echo "FALHOU: servidor não encerrou com SIGINT"; kill -9 $srv; fail=1; fi
wait $srv 2>/dev/null || true
sed -n 2p "$tmp/load.log"
echo "RSS: repouso ${idle} KiB, pico ${peak} KiB, depois da rajada ${after} KiB"
(( peak < 30 * 1024 )) || { echo "ACIMA DE 30 MB"; fail=1; }
rm -rf "$tmp"

echo "== testes de erro de compilação (mensagem esperada + no máximo 2 linhas de erro)"
for f in tests/compile_fail/*.d; do
    expect=$(sed -n 's#^// EXPECT: ##p' "$f")
    out=$($DC $I -o- -c -verrors=simple "$f" 2>&1 || true)
    errlines=$(printf '%s\n' "$out" | grep -c . || true)
    if [[ "$out" != *"$expect"* ]]; then
        echo "FALHOU $f: mensagem não encontrada"; printf '%s\n' "$out" | head -5; fail=1
    elif (( errlines > 2 )); then
        echo "FALHOU $f: $errlines linhas de erro (máximo 2)"; printf '%s\n' "$out"; fail=1
    else
        echo "ok  $f"
    fi
done

echo "== orçamento de compilação (app.d sem codegen das libs; meta < 400 ms no DMD)"
best=999999
for _ in 1 2 3 4 5; do
    s=$(date +%s%N); $DC $I -o- -c examples/hello/source/app.d; e=$(date +%s%N)
    ms=$(( (e - s) / 1000000 )); (( ms < best )) && best=$ms
done
echo "app.d: ${best} ms (melhor de 5)"
(( best < 400 )) || { echo "ACIMA DO ORÇAMENTO"; fail=1; }

exit $fail
