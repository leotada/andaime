# M2 spike: epoll + one fiber per request

A throwaway proof of concept (not part of the DUB packages). A single-threaded, edge-triggered
epoll server; each request runs on a reused `Fiber`, and the handler "waits for an external API" with
`awaitSleep` (the fiber suspends, no thread is blocked). A load generator lives in the same file.

```sh
ldmd2 -O3 -release spike.d -ofspike
ulimit -n 20000
./spike server 18081 3000 100000 &     # port, simulated wait (ms), in-flight request ceiling
./spike client 18081 10000 1500 3000   # port, connections, ramp (ms), expected wait (ms)
```

## Results (LDC 1.43 -O3, 2 vCPU container, loopback, minimal handler)

| Scenario                        | Server RSS | Overhead over the wait (p50 / p99 / max)   |
|---------------------------------|------------|--------------------------------------------|
| idle                            | 6.2 MB     | —                                          |
| 1,000 in flight (3 s wait)      | 14.7 MB    | 1.0 / 3.1 / 3.2 ms                         |
| 10,000 in flight (3 s wait)     | 88.5 MB    | 1.1 / 4.8 / 8.2 ms                         |
| ceiling of 256 with 1,000 conns | 8.7 MB     | 744 immediate 503 responses (p50 0.1 ms)   |

- Cost per in-flight request: ~8.2 KiB (4 KiB buffer + ~4 KiB fiber).
- No failures with 10,000 simultaneous connections on a single thread.
- RSS does not come back after the load (89.7 MB at the end): fibers and buffers stay pooled.
  The real engine needs a policy to shrink the pools.
- Not counted: kernel memory for the sockets (outside RSS) and the real stack of an actual handler
  (the spike's handler barely uses any stack).
- Not covered: cancellation when the client disconnects with the fiber suspended, a real HTTP parser,
  more than one thread, TLS.
