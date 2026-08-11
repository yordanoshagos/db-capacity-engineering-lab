# Phase 2 — Solo Investigation Runbook

**Goal:** For each ticket: hypothesis → reproduce → evidence → mechanism + math → fix → verify.  
**Inputs:** [`PHASE1_BREAKDOWN.md`](./PHASE1_BREAKDOWN.md)  
**Outputs:** filled [`LAB_JOURNAL.md`](./LAB_JOURNAL.md), [`SCARS.md`](./SCARS.md), `evidence/`, fix commits

---

## 0. One-time setup

```bash
# From repo root
docker compose up -d --build
# Wait until mysql is healthy
docker compose ps

# Seed ~100k patients
docker compose exec capacity-api bash /usr/local/bin/seed.sh

# Dashboards
open http://localhost:3001   # Grafana (admin/admin)
open http://localhost:9090   # Prometheus
curl -s http://localhost:3000/health
```

**Prereqs:** Docker, k6 (`brew install k6`), git.

---

## 1. Baseline (mandatory control group)

```bash
mkdir -p evidence/00-baseline
k6 run --summary-export=evidence/00-baseline/k6-summary.json \
  load-tests/00-baseline.js | tee evidence/00-baseline/k6-console.txt

docker stats --no-stream > evidence/00-baseline/docker-stats.txt
```

Paste the k6 summary into `LAB_JOURNAL.md` → **Baseline** table:
`http_reqs`, `http_req_failed`, `http_req_duration` p95/p99, iterations, VUs.

Every incident later gets a **vs baseline** column.

---

## 2. Per-incident loop (do this 4×)

```text
A. Copy Phase-1 hypothesis into LAB_JOURNAL BEFORE running k6
B. Reproduce → save evidence/<TICKET>/before/
C. Run the kill-test while load is live
D. Name mechanism + fill capacity math
E. One focused fix + rebuild if needed
F. Re-run SAME k6 → evidence/<TICKET>/after/
G. Fill SCARS.md entry same day
```

### Evidence capture snippet

```bash
TICKET=OPS-2201   # change per incident
PHASE=before      # or after
mkdir -p evidence/$TICKET/$PHASE

k6 run --summary-export=evidence/$TICKET/$PHASE/k6-summary.json \
  load-tests/reproduce-$TICKET.js | tee evidence/$TICKET/$PHASE/k6-console.txt

docker stats --no-stream > evidence/$TICKET/$PHASE/docker-stats.txt
# Optional while broken:
# docker compose logs --tail=80 capacity-api > evidence/$TICKET/$PHASE/api-logs.txt
```

After code/config fixes that live in the image:

```bash
docker compose up -d --build capacity-api
# wait a few seconds for healthy
```

Schema-only fixes (indexes) do **not** need a rebuild — run SQL against MySQL.

---

## 3. Ticket playbooks

### OPS-2201 — Search slow at shift change

| Step | Do this |
|------|---------|
| Hypothesis | Missing/unused index → full scan on `last_name` |
| Reproduce | `k6 run load-tests/reproduce-OPS-2201.js` (200 VUs, search `Smith`) |
| Kill-test | MySQL: `EXPLAIN ANALYZE SELECT * FROM patients WHERE last_name = 'Smith';` and `SHOW INDEX FROM patients;` |
| Watch | Grafana p95 for `/api/patients/search`; compare to `/api/patients/recent` |
| Mechanism | B-tree miss → type=ALL → ~100k rows examined; concurrency amplifies I/O |
| Math | rows_examined ≈ N; after index ≈ matches for that name (~N/10 for lab seed) |
| Fix direction | `CREATE INDEX ... ON patients (last_name);` then re-EXPLAIN + re-k6 |
| Verify | p95 under SLO (~300ms threshold in script) or large improvement vs before |

```bash
docker compose exec mysql-db mysql -uroot -plabpassword capacity_lab \
  -e "EXPLAIN ANALYZE SELECT * FROM patients WHERE last_name = 'Smith'; SHOW INDEX FROM patients;"
```

---

### OPS-2202 — Whole app freezes; DB idle

| Step | Do this |
|------|---------|
| Hypothesis | App pool too small → requests queue in app; DB looks idle |
| Reproduce | `k6 run load-tests/reproduce-OPS-2202.js` |
| Kill-test | Check `api/database.js` `connectionLimit`; under load: MySQL `Threads_running` (low) vs app latency/errors |
| Watch | Even `/api/patients/recent` dies; DB CPU flat |
| Mechanism | Connection-pool queueing (contention for a scarce app-tier resource) |
| Math | Little’s Law: connections ≈ λ × W ; pool=2 caps concurrency hard |
| Fix direction | Raise `connectionLimit` to a reasoned size; optionally fail-fast (`queueLimit`) so bursts degrade |
| Verify | Higher RPS, lower error %, lower p95 on recent under same k6 |

```bash
docker compose exec mysql-db mysql -uroot -plabpassword -e \
  "SHOW GLOBAL STATUS LIKE 'Threads_running'; SHOW GLOBAL STATUS LIKE 'Threads_connected';"
```

---

### OPS-2203 — Bed admits fail under load

| Step | Do this |
|------|---------|
| Hypothesis | Hot-row lock held across slow external notify (~500ms) |
| Reproduce | `k6 run load-tests/reproduce-OPS-2203.js` |
| Kill-test | While running: lock waits / InnoDB status; read admit handler in `api/server.js` |
| Watch | Same hospital contends; different hospitals less so |
| Mechanism | Row-lock serialization; critical section includes simulated network I/O |
| Math | If W≈0.5s lock hold → max ≈ `1/W` ≈ 2 admits/sec **per hospital** |
| Fix direction | Commit (or use atomic guarded update) **before** `notifyBedRegistry`; keep txn short |
| Verify | Higher successful admits/sec, fewer lock-wait errors |

```bash
# In another terminal WHILE k6 runs:
docker compose exec mysql-db mysql -uroot -plabpassword capacity_lab -e \
  "SELECT * FROM sys.innodb_lock_waits\G"
```

---

### OPS-2204 — Nightly export crash-loops

| Step | Do this |
|------|---------|
| Hypothesis | Unbounded `SELECT *` materialised in Node heap → OOM |
| Reproduce | `k6 run load-tests/reproduce-OPS-2204.js` |
| Kill-test | `docker stats`, `docker compose logs -f capacity-api`, Prometheus `nodejs_heap_size_used_bytes` |
| Watch | Heap climbs; RestartCount increases; other routes suffer |
| Mechanism | O(N) memory for N patients vs 160MB cgroup limit |
| Math | rows × bytes/row ≈ payload MB; × concurrent callers vs 160MB |
| Fix direction | Paginate and/or stream; never hold full table in one array |
| Verify | Peak heap stable, restart count 0, export still usable |

```bash
docker stats --no-stream capacity-api
docker inspect capacity-api --format '{{.RestartCount}}'
```

---

## 4. Suggested order tonight

1. Baseline  
2. **OPS-2201** (index — SQL only)  
3. **OPS-2202** (pool — rebuild API)  
4. **OPS-2203** (shorten txn — rebuild API)  
5. **OPS-2204** (paginate/stream — rebuild API)  
6. Fill journal + SCARS + comparison table  
7. Commit, push, Slack link + surprise line  

**Note:** The tiny pool (`connectionLimit: 2`) pollutes *every* high-concurrency test. Still investigate 2201’s EXPLAIN first (the scan is real). After 2202’s pool fix, re-check 2201 after-numbers if you want cleaner latency — document that interaction; it’s senior-level insight.

---

## 5. Commit style

```text
fix(OPS-2201): add index on patients(last_name) for search
fix(OPS-2202): size MySQL pool via Little's Law
fix(OPS-2203): release hospital row lock before bed-registry notify
fix(OPS-2204): paginate patient export to bound memory
docs: Phase 1 breakdown, Phase 2 runbook, journal, scars, evidence
```

Put index SQL in something like `api/migrations/001_patients_last_name_idx.sql` **and** run it on the live DB (seed drops tables — re-apply index after re-seed, or add index to `seed.sh` after CREATE TABLE so rebuilds stay fixed).

---

## 6. Definition of done (Phase 2)

- [ ] Baseline numbers in journal  
- [ ] Four before/after evidence folders with k6 output  
- [ ] Mechanism + math for each  
- [ ] Fixes committed  
- [ ] `LAB_JOURNAL.md` complete including synthesis  
- [ ] `SCARS.md` with four entries  
- [ ] Repo public (or `@devBoya` added) + Slack DM ready  
