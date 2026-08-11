# Phase 1 — Group Breakdown

**Lab:** Regional Health On-Call  
**Purpose:** Agree on symptom, endpoint, first hypothesis, and kill-test for each ticket *before* anyone opens a terminal.  
**Rule:** These are starting theories. Evidence in Phase 2 may kill them — that is expected and full marks.

---

## How we used this meeting

For each incident we answered:

1. What is the **symptom** in plain English?
2. Which **endpoint / resource** is implicated?
3. What is our **first hypothesis**?
4. What **one measurement** proves or disproves it?

We did **not** decide the final root cause or the fix.

---

## Summary table

| Ticket | Symptom (plain English) | Endpoint | First hypothesis | Kill-test (1 metric / query) |
|--------|-------------------------|----------|------------------|------------------------------|
| OPS-2201 | Search dies under concurrent last-name lookups; “recent” stays fast | `GET /api/patients/search` | Missing / unused index → full table scan under concurrency | `EXPLAIN ANALYZE` — rows examined vs index range |
| OPS-2202 | Whole API stalls; DB CPU/disk flat; recovers when load drops | All reads, esp. `GET /api/patients/recent` | App connection-pool exhaustion / queueing | App pool waits vs MySQL `Threads_running` |
| OPS-2203 | Concurrent admits to the **same** hospital fail; different hospitals OK | `POST /api/hospitals/:id/admit` | Hot-row lock / long transaction critical section | `sys.innodb_lock_waits` + throughput ≤ `1/W` |
| OPS-2204 | Export OOMs / restart loop; heap spikes; takes others down | `GET /api/patients/export` | Unbounded result materialization in app memory | `nodejs_heap_size_used_bytes` + `rows × bytes/row` |

---

## OPS-2201 — Patient search slow at shift change

| Decision | Agreement |
|----------|-----------|
| **Symptom** | Last-name patient search hangs or errors when many nurses search at once; alone it feels fine. The “recent patients” panel on the same screen stays fast. |
| **Endpoint** | `GET /api/patients/search` |
| **First hypothesis** | The search query does a **full table scan** (missing or unused index on last name). Fine for one user; under concurrency it saturates I/O/CPU and latency explodes. |
| **Kill-test** | While reproduction runs: `EXPLAIN ANALYZE` on the search SQL. |

**Pass / fail the hypothesis**

- **Hypothesis lives** if the plan shows `type=ALL` (or equivalent) and ~100k rows examined.
- **Hypothesis dies** if the query already uses an index and rows examined stay small → look elsewhere (locks, pool, app bug).

**Why not “the DB is overloaded”?** Other endpoints stay healthy during the incident, so this looks like a bad access path on *this* query, not a global machine outage.

**Reproduce (Phase 2):** `k6 run load-tests/reproduce-OPS-2201.js`

---

## OPS-2202 — Whole app freezes; DB looks idle

| Decision | Agreement |
|----------|-----------|
| **Symptom** | During a traffic surge the **whole API** stalls — even the trivial “recent patients” call. DB CPU and disk stay flat. Everything recovers when concurrency drops. |
| **Endpoint** | Effectively all read endpoints; use `GET /api/patients/recent` as the canary (cheap query still broken). |
| **First hypothesis** | **App connection-pool exhaustion / queueing** — requests wait for a free DB connection in the app tier, so MySQL looks idle while clients time out. |
| **Kill-test** | Under surge: compare app pool wait / timeout signals vs MySQL `Threads_running` (expect low) and `Threads_connected`. |

**Pass / fail the hypothesis**

- **Hypothesis lives** if the app is waiting on the pool while the DB is barely executing work.
- **Hypothesis dies** if MySQL is actually busy (high `Threads_running`, slow queries dominate) → not a pool paradox.

**Alternate hypothesis (keep in pocket):** MySQL `max_connections` exhausted (DB refusing new connections). Kill-test distinguishes **app pool wait** vs **DB connection refusal**.

**Why not “slow query”?** Even the cheapest query fails → bottleneck is getting *to* the DB, not query cost.

**Reproduce (Phase 2):** `k6 run load-tests/reproduce-OPS-2202.js`

---

## OPS-2203 — Bed admissions fail under load

| Decision | Agreement |
|----------|-----------|
| **Symptom** | Many concurrent admits to the **same hospital** crawl, then fail (DB error, timeout, or near-zero throughput). One-at-a-time works. Different hospitals interfere less with each other. |
| **Endpoint** | `POST /api/hospitals/:id/admit` |
| **First hypothesis** | **Hot-row lock contention** — writers serialize on one hospital row; a long critical section caps throughput at roughly `1/W` admits/sec for that hospital. |
| **Kill-test** | During reproduction: `performance_schema.data_locks`, `sys.innodb_lock_waits`, and `SHOW ENGINE INNODB STATUS` (TRANSACTIONS). |

**Pass / fail the hypothesis**

- **Hypothesis lives** if we see waiter → blocker on the same hospital row and throughput capped near `1/W`.
- **Hypothesis dies** if there are no lock waits and failures come from something else (constraint errors, pool exhaustion, etc.).

**Capacity math to fill in Phase 2**

```text
If critical section holds the row lock for W seconds:
max admits for that hospital ≈ 1 / W
Extra concurrency does not raise that ceiling — it only lengthens the wait queue.
```

**Why not “DB too small”?** Failure is **per-hospital**, not global → contention on one row, not raw machine capacity.

**Reproduce (Phase 2):** `k6 run load-tests/reproduce-OPS-2203.js`

---

## OPS-2204 — Nightly export crashes the service

| Decision | Agreement |
|----------|-----------|
| **Symptom** | Full patient export makes memory spike; the service restart-loops and pages on-call. Daytime small reads are fine. Other users on that instance also suffer during the export window. |
| **Endpoint** | `GET /api/patients/export` |
| **First hypothesis** | **Unbounded result loaded into app memory** (materialize ~100k rows) → heap exceeds container limit (160MB lab / 256MB prod) → OOM / restart. |
| **Kill-test** | During export: `nodejs_heap_size_used_bytes`, `docker stats`, restart logs, plus rough math `rows × bytes/row`. |

**Pass / fail the hypothesis**

- **Hypothesis lives** if heap climbs with payload size and the process dies near the memory ceiling.
- **Hypothesis dies** if heap stays flat and the crash is something else (DB timeout, connection storm, etc.).

**Capacity math to fill in Phase 2**

```text
full_payload_MB ≈ (row_count × bytes_per_row) / 1_000_000
with C concurrent exports ≈ C × full_payload_MB (+ overhead)
compare to container budget: 160MB local / 256MB prod
```

**Why not “MySQL ran out of memory”?** The visible failure is the **app container** heap / restarts, correlated with the export path.

**Reproduce (Phase 2):** `k6 run load-tests/reproduce-OPS-2204.js`

---

## One-page cheat sheet (for Phase 2)

```text
OPS-2201
  Symptom: concurrent last-name search dies; recent stays fast
  Where:   GET /api/patients/search
  Guess:   full scan / missing index
  Prove:   EXPLAIN ANALYZE → type=ALL / rows ~100k?

OPS-2202
  Symptom: whole API freezes; DB idle; recovers when load drops
  Where:   all reads (watch GET /api/patients/recent)
  Guess:   app connection pool queueing
  Prove:   pool waits high + Threads_running low?

OPS-2203
  Symptom: concurrent admits to SAME hospital fail; solo OK
  Where:   POST /api/hospitals/:id/admit
  Guess:   hot-row locks / long txn (throughput ≤ 1/W)
  Prove:   innodb_lock_waits shows waiter/blocker on hospital row?

OPS-2204
  Symptom: export → heap spike → restart loop; takes others down
  Where:   GET /api/patients/export
  Guess:   unbounded SELECT * in app memory
  Prove:   heap ≈ rows×bytes/row and hits container limit?
```

---

## Explicitly not decided in Phase 1

- Exact fix (index columns, pool size number, stream vs paginate)
- Final root cause (evidence can overturn us)
- Who implements what (each engineer works all four tickets solo)

---

## Next step — Phase 2

1. Clone / open your own copy of the lab.
2. `docker compose up -d --build` → seed → baseline (`k6 run load-tests/00-baseline.js`).
3. For each ticket: copy the hypothesis from this file into `LAB_JOURNAL.md` **before** running k6.
4. Run the kill-test. If the hypothesis dies, write that down — then form the next one from the evidence.
5. Fix, re-verify, fill `SCARS.md`.

**Baseline first. Numbers, not adjectives. Name the mechanism.**
