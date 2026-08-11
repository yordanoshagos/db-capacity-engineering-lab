# Evidence comparison — before vs after

Source: k6 `--summary-export` under `evidence/**`. Baseline is `load-tests/00-baseline.js` (50 VUs, recent patients).

| Run | RPS | p95 | Error rate | Notes |
|-----|-----|-----|------------|-------|
| Baseline | 49.4 | 68 ms | 0% | Control group |
| OPS-2201 before | 16.7 | 19.4 s | 0% | Full table scan (`EXPLAIN`) |
| OPS-2201 after | 114 | still high under 200 VUs | mixed | Index + pool; payload-bound residual |
| OPS-2202 before | 1334 | 3.03 s | 0% | `Threads_running=2` = pool size |
| OPS-2202 after | 1505 | **565 ms** (successful) | ~3% | `connectionLimit` 2→50 |
| OPS-2203 before | 1.97 | 57 s | 0% (stall) | X lock + 500ms notify in txn |
| OPS-2203 after | **625** | **1.19 s** | 0% | Commit/release before notify |
| OPS-2204 before | 0.42 | ~120 s timeout | **100%** | Unbounded `SELECT *` |
| OPS-2204 after | **316** | **227 ms** | **0%** | Keyset pagination; mem ~95MB |

Artifacts per ticket: `evidence/<TICKET>/{before,after}/`.
