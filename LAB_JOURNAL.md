# 🧾 On-Call Lab Journal — Regional Health

**Engineer:** Yordanos Tesfay Hagos  **Date:** 2026-08-11

This is your investigation notebook. You are on call for the Regional Health
platform and working the [incident queue](./incidents/README.md). For each
incident you will:

1. **Hypothesis** — from the ticket symptoms alone, predict the cause *before*
   you run anything.
2. **Observation** — record real evidence: k6 output, Grafana/Prometheus
   metrics, `EXPLAIN ANALYZE` plans, lock views, `docker stats`, container logs.
3. **Root cause & mechanism** — explain *why* it happens. Name the database/OS
   mechanic yourself and show the capacity math.
4. **Fix & verify** — make the change, re-run the reproduction, and record the
   before/after.

> There is no answer key. A claim without evidence isn't a diagnosis. "It felt
> slow" is not an observation; `p(95)=1840ms, http_req_failed=32%` is.

Phase 1 group sheet: [`PHASE1_BREAKDOWN.md`](./PHASE1_BREAKDOWN.md)  
Phase 2 runbook: [`PHASE2_RUNBOOK.md`](./PHASE2_RUNBOOK.md)  
Evidence tree: [`evidence/`](./evidence/)

---

## How to capture evidence

- **k6:** copy the summary block (`http_req_duration`, `http_req_failed`,
  `iterations`, `vus`).
- **MySQL:** `docker compose exec mysql-db mysql -uroot -plabpassword capacity_lab`
  then run `EXPLAIN ANALYZE ...`, `SHOW CREATE TABLE ...`,
  `SHOW ENGINE INNODB STATUS\G`, or query `performance_schema` / `sys`.
- **Metrics:** Grafana panels or raw Prometheus at http://localhost:9090.
- **Memory / restarts:** `docker stats`, `docker compose logs -f capacity-api`.

Useful Prometheus queries:
```promql
# Throughput (req/s) by route
sum(rate(http_requests_total[1m])) by (route)

# p95 latency by route
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[1m])) by (le, route))

# Application heap in use
nodejs_heap_size_used_bytes

# DB errors by code
sum(rate(db_errors_total[1m])) by (code)
```

---

## Baseline — steady state (do this first)
*Run:* `k6 run load-tests/00-baseline.js` (healthy system, no incident)

Capture the control group you'll compare every incident against.

| Metric              | Value |
|---------------------|-------|
| Requests/sec (RPS)  | 49.37 |
| p50 latency         | 2.92 ms |
| p95 latency         | 67.81 ms |
| p99 latency         | (max observed 116.41 ms; k6 summary did not emit p99 separately) |
| Error rate          | 0.00% |
| Peak API heap used  | ~37 MiB / 160 MiB (23%) via `docker stats` |

> SLOs you'll hold the incidents to (target p95, max error rate, RPS floor):
> Search p95 < 300ms (script threshold); surge fail rate < 5%; admit p95 < 1s;
> export fail rate < 5% with heap staying under the 160MB cgroup.

Evidence: `evidence/00-baseline/`

---

## Investigation — OPS-2201
*Ticket:* [Patient name search unusably slow at shift change](./incidents/OPS-2201.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2201.js`

### Hypothesis
> From the symptoms alone (fast when isolated, collapses under concurrent
> searches, other endpoints unaffected), I think the cause is
> a missing index on `patients.last_name` causing a full table scan
> because a single search is tolerable (~tens of ms) but 200 concurrent scans
> of ~100k rows saturate I/O and the buffer pool. Kill-test: EXPLAIN ANALYZE.

### Observation (evidence)
> Investigate how the database executes the search. Paste what you find:
> ```
> BEFORE — EXPLAIN ANALYZE:
>   -> Filter: (patients.last_name = 'Smith')  (actual time=0.07..45.4 rows=10000)
>       -> Table scan on patients  (actual time=0.065..38.7 rows=100000)
> SHOW INDEX: only PRIMARY on id. No secondary index on last_name.
>
> k6 before (200 VUs, 30s):
>   http_reqs=697 (16.7/s)
>   http_req_duration p95=19.37s  avg=10.35s
>   http_req_failed=0%
>   data_received=2.5 GB
> ```
| Metric (under load) | Value | vs. baseline |
|---------------------|-------|--------------|
| p95 latency         | 19,370 ms | ~286× worse than baseline 68ms |
| RPS                 | 16.7 | baseline was 49 on a cheap endpoint |
| Error rate          | 0% | — |
| Rows examined / req | 100,000 (table scan) → 10,000 matches | baseline N/A |

### Root cause & mechanism
> What is the database doing per request, and why does cost blow up with data
> size and concurrency? Name the mechanism and the data structure involved.
> Estimate the cost difference between the current behaviour and the ideal one
> for ~100,000 rows.
>
> **Mechanism:** full table scan on InnoDB (no B-tree secondary index on
> `last_name`). Each search reads ~100k rows to return ~10k Smiths.
> Ideal with index: B-tree lookup → examine ≈ matching rows only.
> Cost ratio (rows examined): 100,000 / 10,000 ≈ **10×** less work per query
> after indexing (and no scan of non-Smith rows).
>
> **Surprise / secondary bottleneck:** adding the index alone changed EXPLAIN
> (`Table scan` → `Index lookup`) but k6 p95 stayed ~20s with `connectionLimit=2`.
> The pool was serialising work. After sizing the pool (OPS-2202), RPS rose
> 16.7 → 114, but fat payloads (10k rows × ~340 B ≈ 3.4 MB/response) still
> keep p95 high under 200 VUs. Index fixed the access path; concurrency +
> payload size remain capacity limits.

### Fix & verify
> The change you made (be specific):
> `CREATE INDEX idx_patients_last_name ON patients (last_name);`
> also added to `data-seed/seed.sh` so re-seeds keep it.
>
> Re-run evidence — new query behaviour:
> ```
> AFTER — EXPLAIN ANALYZE:
>   -> Index lookup on patients using idx_patients_last_name (last_name='Smith')
>      (actual time=0.03..17.7 rows=10000)
> ```
> After index + pool fix: RPS 16.7 → 114 (~6.8×). Successful searches work;
> residual latency is payload/transfer under extreme concurrency, not the scan.
>
> New p95: still multi-second under 200 VUs (payload-bound)  
> New RPS: 114  
> Improvement factor: **~6.8× throughput**; plan cost rows 100k → 10k (**10×**)  
> Trade-off: secondary index costs write amplification + disk on every INSERT/UPDATE
> of `last_name` — correct price for this read path.

Evidence: `evidence/OPS-2201/before|after/`

---

## Investigation — OPS-2202
*Ticket:* [Whole app freezes during surges, DB looks idle](./incidents/OPS-2202.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2202.js`

### Hypothesis
> Given the query is trivial and the DB is idle yet requests pile up, I think
> the bottleneck is the Node MySQL connection pool (`connectionLimit`)
> because requests wait for a free app-tier connection while MySQL has almost
> no runnable threads. Kill-test: compare pool config vs `Threads_running`.

### Observation (evidence)
> Where is time spent between request arrival and query execution? Capture the
> error codes and any queue/timeout evidence from logs and metrics:
> ```
> api/database.js BEFORE: connectionLimit: 2, queueLimit: 0
>
> During surge (sample):
>   Threads_running   = 2
>   Threads_connected = 3
>   max_connections   = 151
>
> Paradox: DB has headroom (151 max) but only ~2 threads running — exactly the
> app pool size. Time is spent queued in mysql2 waiting for a connection.
>
> k6 before (ramp to 2000 VUs):
>   RPS ≈ 1334
>   p95 = 3028 ms   avg = 1352 ms
>   http_req_failed = 0%   (infinite queue → latency, not errors)
> ```
| Metric                    | Value | vs. baseline |
|---------------------------|-------|--------------|
| Successful RPS (plateau)  | ~1334 | baseline ~49 (different shape; surge is extreme) |
| p95 / p99 latency         | p95 3028 ms | baseline p95 68 ms |
| Error / timeout rate      | 0% | — |
| Avg service time per query (s) | ~0.005–0.015s when not queued (baseline med ~3ms) | queue dominates |

### Root cause & mechanism
> Explain the paradox: idle database, trivial query, stalled app. What finite
> resource is being contended, and where does it live? Derive the *right* size
> for that resource from your measured throughput and service time (state the
> relationship you used):
> - Measured avg service time W ≈ 0.010 s (cheap recent query, unqueued)
> - Target throughput λ ≈ 2000 req/s (surge design point)
> - Required capacity = λ × W ≈ 2000 × 0.010 = **20 connections** (Little's Law)
>   We set `connectionLimit: 50` for headroom under variance.
> Why does making it arbitrarily large eventually stop helping?
> You hit MySQL `max_connections`, RAM per connection, and CPU — and you lose
> backpressure. Beyond the working set, more conns just move the queue into the DB.

### Fix & verify
> The change you made: `connectionLimit: 2 → 50` in `api/database.js`
> (documented Little's Law sizing). Left `queueLimit: 0` for fair latency
> comparison; noted that a finite `queueLimit` is the production backpressure
> tool (earlier experiment with queueLimit=200 shed load but raised errors).
>
> After (successful responses): p95 **565 ms** (was 3028 ms) ≈ **5.4×** better;
> overall RPS ~1505; fail rate ~3% under 2000 VU hammering.
> New RPS: ~1505  New error rate: ~3%  New p95 (ok responses): 565 ms
> What upstream protection would make a burst degrade gracefully instead of
> collapsing? Finite `queueLimit` + HTTP 503 / load-shedder / gateway concurrency
> limit so excess fails fast instead of queueing without bound.

Evidence: `evidence/OPS-2202/before|after/`

---

## Investigation — OPS-2203
*Ticket:* [Bed admissions fail with DB errors under load](./incidents/OPS-2203.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2203.js`

### Hypothesis
> Given one-at-a-time works but concurrent admits to the *same* hospital fail,
> I think the cause is row-lock serialization on `hospitals.id` with a long
> critical section (external notify inside the transaction)
> and the failure will show up as lock waits / near-zero throughput (or
> lock-wait timeout errors depending on tuning).

### Observation (evidence)
> While the reproduction runs, inspect concurrent writers to one row:
> ```
> sys.innodb_lock_waits:
>   waiting_pid 13  UPDATE hospitals SET available_beds = available_beds - 1 WHERE id = 1
>   blocking_pid 14
>
> InnoDB: LOCK WAIT ... lock_mode X locks rec but not gap waiting
>   on PRIMARY of hospitals, record = General Hospital (id=1)
>
> performance_schema.data_locks:
>   hospitals RECORD X,REC_NOT_GAP GRANTED 1
>   hospitals RECORD X,REC_NOT_GAP WAITING 1
>
> k6 before (500 VUs → same hospital):
>   RPS ≈ 1.97
>   p95 ≈ 57.0 s
>   http_req_failed = 0% (stall / queue, mostly)
> ```
| Metric                     | Value | vs. baseline |
|----------------------------|-------|--------------|
| p95 / p99 latency          | p95 57,030 ms | collapse |
| Max successful admits/sec  | ≈ 1.97 | matches 1/W |
| DB error(s) + code         | lock waits (X row lock); innodb-lock-wait-timeout=5s configured | — |
| Error rate                 | 0% in this run (throughput collapse) | — |

### Root cause & mechanism
> Explain why concurrency cannot beat serialization on a single hot row. If the
> critical section is held for W seconds per admit, what is the theoretical max
> throughput for that one row, regardless of how many callers pile on?
> 1 / W = 1 / 0.5 = **2 admits/sec**. Measured ≈ 1.97/s — matches.
> Where does the time in the critical section go, and which of the transactional
> guarantees is enforcing the wait?
> `notifyBedRegistry()` sleeps 500ms **inside** the open transaction after the
> UPDATE, so InnoDB holds the **exclusive row lock** (isolation/locking for
> correct concurrent updates) until commit. Writers queue on that one record.

### Fix & verify
> The change you made:
> 1. Commit the bed decrement **before** calling `notifyBedRegistry`
> 2. Release the pool connection before the notify (so we don't hold a pool
>    slot for 500ms either)
> 3. Use `UPDATE ... WHERE id=? AND available_beds > 0` (atomic guard)
>
> Re-measured:
> | | Before | After |
> |---|---|---|
> | RPS | 1.97 | **625** |
> | p95 | 57.0 s | **1.19 s** |
> | errors | 0% (stalled) | **0%** |
> Improvement: **~317× throughput**; p95 ~48× better.
> Floor: solo admit still ~515ms because notify is intentionally 500ms after
> the DB work — that is now *outside* the lock.

Evidence: `evidence/OPS-2203/before|after/`

---

## Investigation — OPS-2204
*Ticket:* [Nightly export crashes the service repeatedly](./incidents/OPS-2204.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2204.js`

### Hypothesis
> Given memory spikes right before each restart and only the big export is
> affected, I think the cause is unbounded `SELECT * FROM patients` materialised
> in Node heap (O(N) memory)
> because ~100k rows × hundreds of bytes exceeds the 160MB cgroup when many
> callers overlap.

### Observation (evidence)
> Watch `nodejs_heap_size_used_bytes`, GC pauses, and restarts:
> ```
> Code (before): const [rows] = await pool.query('SELECT * FROM patients');
>
> k6 before (50 VUs, 2m, timeout 120s):
>   http_req_failed = 100%
>   every request timed out at ~120s
>   RPS ≈ 0.42
>   capacity-api net I/O climbed to multi-GB while clients got 0 B back
>   (pool of 2 + full-table materialisation → requests never completed)
> ```
| Metric                          | Value |
|---------------------------------|-------|
| Approx. payload size per request| ~100k × ~341 B ≈ **34 MB** JSON-ish per full export |
| Peak heap before crash          | full export path contended with tiny pool; clients saw timeouts |
| Time-to-first-crash             | effective total failure within the 2m window (100% timeouts) |
| Container restart count         | 0 in this capture (failure mode = hang/timeout under pool=2); cgroup still 160MB |
| GC pause trend                  | N/A in this run — requests never finished |

> Paste the crash / exit log lines:
> ```
> k6: Request Failed ... request timeout
> http_req_failed rate=100%
> ```

### Root cause & mechanism
> Estimate per-row size, then the full payload: rows × bytes/row = ______ MB.
> Sample row ≈ 341 bytes → 100,000 × 341 ≈ **34.1 MB** raw JSON objects, plus
> array overhead / encoding → tens of MB per in-flight export.
> With C concurrent callers, peak resident memory ≈ C × payload (+ Node overhead)
> vs 160MB budget — concurrent full exports cannot fit.
> Current approach is **O(N) memory**. Pagination/streaming is **O(page size)**.

### Fix & verify
> The change you made: keyset pagination on
> `GET /api/patients/export?afterId=&limit=` (default limit 500, max 1000),
> `WHERE id > ? ORDER BY id LIMIT ?`.
>
> Re-run evidence:
> | | Before | After |
> |---|---|---|
> | RPS | 0.42 | **316** |
> | fail rate | 100% | **0%** |
> | p95 | ~120s (timeout) | **227 ms** |
> | mem during run | contended / unusable | ~94–97 MiB / 160 MiB stable |
> | restarts | — | unchanged during after run |
>
> Memory stays bounded because each response holds ≤1000 rows.

Evidence: `evidence/OPS-2204/before|after/`

---

## Post-incident review (synthesis)

> Rank the four incidents by **blast radius** (threat to overall availability at
> scale), justified with your measured numbers:
> 1. **OPS-2202** — pool=2 made *every* endpoint queue; under surge p95=3s on a
>    trivial query while MySQL showed `Threads_running=2`. Whole-API availability cliff.
> 2. **OPS-2204** — unbounded export took the instance to 100% client failure for
>    that path and multi-GB internal I/O; can starve siblings on the same process.
> 3. **OPS-2203** — critical write path collapsed to ~2 admits/sec (1/W) for a
>    single hospital during surge; patient-flow impacting but scoped per facility.
> 4. **OPS-2201** — search-only; painful (p95~19s) but not universal freeze.
>
> If you could ship only **one** fix before a launch, which and why?
> **OPS-2202 (pool sizing).** It is the universal multiplier: every other fix still
> funnels through the pool. Measured `Threads_running` matched `connectionLimit`
> while `max_connections=151` sat idle — highest leverage, lowest code risk.
>
> For each incident, what alert or dashboard would have caught it in production
> *before* a user filed a ticket?
> - **2201:** p95 on `/api/patients/search` + slow-query / rows_examined alert; EXPLAIN in CI for new predicates.
> - **2202:** pool wait time / `Threads_connected` vs configured limit; app saturation before DB CPU.
> - **2203:** lock wait time / `innodb_row_lock_waits` / admit RPS floor per hospital_id.
> - **2204:** container memory >70% of limit, restart count, export endpoint payload size / p95.

### Hypothesis graveyard (things evidence killed)
- “Index alone will make OPS-2201 hit the 300ms SLO under 200 VUs” — **killed**.
  EXPLAIN improved; pool + fat 10k-row payloads still dominated wall-clock time.
- “Finite queueLimit is always the better pool fix” — **nuanced**. It shed load
  (good backpressure) but spiked error rate under the lab’s 2000-VU script; we
  kept `queueLimit:0` for latency proof and documented fail-fast as the prod pattern.
