# Spike do M2: epoll + um fiber por requisição

Prova de conceito descartável (não faz parte dos pacotes DUB). Um servidor epoll
edge-triggered de uma thread; cada requisição roda num `Fiber` reaproveitado, e o
handler "espera uma API externa" com `awaitSleep` (suspende o fiber, nenhuma thread
bloqueada). Há também um gerador de carga no mesmo arquivo.

```sh
ldmd2 -O3 -release spike.d -ofspike
ulimit -n 20000
./spike server 18081 3000 100000 &     # porta, espera simulada (ms), teto de requisições em voo
./spike client 18081 10000 1500 3000   # porta, conexões, rampa (ms), espera esperada (ms)
```

## Resultados (LDC 1.43 -O3, container de 2 vCPU, loopback, handler mínimo)

| Cenário                         | RSS do servidor | Sobrecusto sobre a espera (p50 / p99 / máx) |
|---------------------------------|-----------------|---------------------------------------------|
| repouso                         | 6,2 MB          | —                                           |
| 1.000 em voo (espera de 3 s)    | 14,7 MB         | 1,0 / 3,1 / 3,2 ms                          |
| 10.000 em voo (espera de 3 s)   | 88,5 MB         | 1,1 / 4,8 / 8,2 ms                          |
| teto de 256 com 1.000 conexões  | 8,7 MB          | 744 respostas 503 imediatas (p50 0,1 ms)    |

- Custo por requisição em voo: ~8,2 KiB (4 KiB de buffer + ~4 KiB de fiber).
- Sem falhas em 10.000 conexões simultâneas, numa única thread.
- O RSS não volta depois da carga (89,7 MB ao terminar): fibers e buffers ficam em pool.
  O engine real precisa de uma política para encolher os pools.
- Não entram na conta: memória do kernel dos sockets (fora do RSS) e a stack real de um handler
  de verdade (o handler do spike quase não usa stack).
- Não cobre: cancelamento quando o cliente desconecta com o fiber suspenso, parser HTTP de
  verdade, mais de uma thread, TLS.
