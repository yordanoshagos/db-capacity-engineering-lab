# SCARS.md — Regional Health On-Call

Scar logs for the next engineer at 2am. One screen per wound.

---

## OPS-2201 — Patient search full-scans under shift-change load

- **S — Symptom:** Concurrent last-name search p95 **19.4s** (200 VUs); “recent” path stayed the healthy contrast. Baseline recent p95 was **68ms**.
- **C — Cause:** No secondary index on `patients.last_name` → InnoDB **full table scan** (~100k rows examined per request). Confirmed with `EXPLAIN ANALYZE` (`Table scan on patients`). Secondary: unbounded `SELECT *` (incl. `notes`) returned ~10k fat rows so index alone still missed the 300ms SLO.
- **A — Action:** (1) `CREATE INDEX idx_patients_last_name ON patients (last_name);` (2) `LIMIT 50` + drop `notes` from the search SELECT.
- **R — Result:** Plan → index lookup; final after-slo p95 **19.4s → 158.61ms** (SLO green), RPS **16.7 → 1839**, 0% errors.
- **Scar / lesson:** EXPLAIN before you ship predicates — and a diagnosis in the graveyard isn’t a fix until the reproduction **passes**. Index fixed access path; LIMIT/columns closed the payload cliff.
- **Evidence:** `evidence/OPS-2201/`, especially `after-slo/`, `LAB_JOURNAL.md` §OPS-2201.

**Alert that would have caught it:** p95(`/api/patients/search`) + slow query / rows_examined.

---

## OPS-2202 — API freezes while MySQL looks idle

- **S — Symptom:** Registration surge: trivial `/api/patients/recent` p95 **3.03s**, RPS ~1334, **0% errors**. DBAs see idle CPU/disk.
- **C — Cause:** App pool **`connectionLimit: 2`**. During incident `Threads_running=2`, `Threads_connected=3`, `max_connections=151`. Time spent in **pool queue**, not SQL.
- **A — Action:** Sized pool with Little’s Law → `connectionLimit: 50` in `api/database.js`.
- **R — Result:** Successful-response p95 **3028ms → 565ms (~5.4×)**; RPS ~1505. Idle-DB paradox explained.
- **Scar / lesson:** Idle DB ≠ healthy request path. Always check the **app pool** when cheap queries are slow under concurrency. Don’t size pools by superstition — use `λ × W`.
- **Evidence:** `evidence/OPS-2202/`, pool config diff, MySQL thread status captures.

**Alert that would have caught it:** pool wait / connections_in_use near limit (leading indicator before p99 dies).

---

## OPS-2203 — Hot hospital row lock + I/O inside the transaction

- **S — Symptom:** 500 concurrent admits to hospital `1`: throughput **≈1.97/s**, p95 **57s**. Solo admits fine; different hospitals interfere less.
- **C — Cause:** `UPDATE` then **`notifyBedRegistry` (500ms)** before `commit` → exclusive **row lock** held ~0.5s. Max ≈ `1/W = 2/s`. Confirmed via `sys.innodb_lock_waits` + InnoDB X lock on `hospitals` id=1.
- **A — Action:** Commit + release connection **before** notify; atomic `UPDATE ... AND available_beds > 0`.
- **R — Result:** RPS **1.97 → 625 (~317×)**; p95 **57s → 1.19s**; **0%** errors. Solo still ~515ms (notify floor, outside the lock).
- **Scar / lesson:** Never do external I/O inside a transaction that holds row locks. Concurrency cannot beat `1/W` on one hot row.
- **Evidence:** `evidence/OPS-2203/before/locks.txt`, after k6 summary, `api/server.js` admit handler.

**Alert that would have caught it:** InnoDB lock wait time / admit RPS floor per `hospital_id`.

---

## OPS-2204 — Unbounded export materialises the table in heap

- **S — Symptom:** With pool=2: **100%** timeouts (hang). With pool=50 mechanism repro: RSS **152 MiB/160 MiB**, **12 restarts** in 2 minutes.
- **C — Cause:** `SELECT * FROM patients` loaded entirely into Node (`O(N)` memory). Tiny pool **masked** the OOM; sized pool revealed the cgroup kill.
- **A — Action:** Keyset pagination: `WHERE id > ? ORDER BY id LIMIT ?` (default 500, max 1000) with `nextAfterId` / `hasMore`.
- **R — Result:** fail **100% → 0%**; **0 restarts** on verify; p95 ~304ms under the same k6 script.
- **Scar / lesson:** Always bound result sets. Reproduce the mechanism the ticket names — if pool starvation hides OOM, resize the pool and capture heap/RSS/RestartCount.
- **Evidence:** `evidence/OPS-2204/before-with-pool50/`, `after/`, export handler in `api/server.js`.

**Alert that would have caught it:** container memory >70% of limit, restart count, export p95 / response size.
