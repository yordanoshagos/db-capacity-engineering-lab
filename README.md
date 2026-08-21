# Regional Health — Reliability On-Call Lab 🧪

A hands-on "Lab-in-a-Box" for learning **database mechanics, performance tuning,
and capacity engineering** the way you actually learn them on the job: by picking
up an incident ticket, reproducing the symptom, and investigating until you find
the root cause.

You are the on-call engineer for the **Regional Health** platform — a healthcare
API backed by MySQL. There is an [incident queue](./incidents/README.md) of open
tickets. Each ticket is a symptom report from a user or another team. **No ticket
tells you the cause, and there is no answer key in this repo.** You diagnose it
from evidence: query plans, connection behaviour, locks, and memory, observed
through Prometheus and Grafana.

> This is a training environment seeded with realistic data and realistic
> problems. Treat it like production you've just been handed.

---

## The environment

| Component        | Tech                  | Port  | Role                                  |
|------------------|-----------------------|-------|---------------------------------------|
| `capacity-api`   | Node.js + Express     | 3000  | The application under investigation   |
| `mysql-db`       | MySQL 8.0             | 3306  | Primary relational store              |
| `mongo-db`       | MongoDB 6.0           | 27017 | Audit store                           |
| `prometheus`     | Prometheus            | 9090  | Metrics scraping                      |
| `grafana`        | Grafana               | 3001  | Dashboards                            |
| load generator   | k6                    | —     | Reproduces each incident's traffic    |

---

## Quick start (3 steps)

### 1. Start the environment
```bash
docker compose up -d --build
```
Wait ~30–60s for MySQL to become healthy (`docker compose ps`).

### 2. Seed realistic data (100,000 patients, 5 hospitals)
The seed script runs *inside* the API container:
```bash
docker compose exec capacity-api bash /usr/local/bin/seed.sh
```

### 3. Open the dashboards
- **Grafana:**    http://localhost:3001  (user `admin` / pass `admin`; anonymous admin is also enabled)
- **Prometheus:** http://localhost:9090
- **API health:** http://localhost:3000/health
- **API metrics:** http://localhost:3000/metrics

In Grafana, add Prometheus as a data source at `http://prometheus:9090`, then
chart `http_request_duration_seconds`, `http_requests_total`,
`db_errors_total`, and `nodejs_heap_size_used_bytes`. Suggested queries are in
[`LAB_JOURNAL.md`](./LAB_JOURNAL.md).

---

## Your job: work the incident queue

Open **[`incidents/README.md`](./incidents/README.md)** and pick a ticket.

The general loop for every incident:

1. **Baseline** the healthy system so you have a control group:
   ```bash
   k6 run load-tests/00-baseline.js
   ```
2. **Reproduce** the reported symptom using that ticket's script, e.g.:
   ```bash
   k6 run load-tests/reproduce-OPS-2201.js
   ```
   (Each `reproduce-OPS-XXXX.js` recreates the *traffic pattern* from ticket
   `OPS-XXXX` — it does not tell you the cause.)
3. **Investigate** with the tools below while the load runs.
4. **Diagnose, fix, and re-run** to prove the fix.
5. **Write it up** in [`LAB_JOURNAL.md`](./LAB_JOURNAL.md).

> No installed k6? Run it in Docker (Linux host networking):
> ```bash
> docker run --rm -i --network host grafana/k6 run - < load-tests/reproduce-OPS-2201.js
> ```

---

## Investigation toolbox

```bash
# Follow the application logs (crashes, errors, restarts)
docker compose logs -f capacity-api

# Live memory / CPU / restart counts per container
docker stats

# Open a MySQL shell to inspect plans, locks, and schema
docker compose exec mysql-db mysql -uroot -plabpassword capacity_lab
```

Inside the MySQL shell, techniques worth knowing:
`EXPLAIN ANALYZE <query>`, `SHOW CREATE TABLE <t>`, `SHOW ENGINE INNODB STATUS`,
and the `performance_schema` / `sys` views for locking. Which ones matter for a
given ticket is part of the exercise.

---

## Teardown
```bash
docker compose down -v
```

---

## Assignment 2 — individual rehost

This repo is **Yordanos's individual half**. Shared modules and the golden
pipeline live in [akezasaloi/regional-health-platform](https://github.com/akezasaloi/regional-health-platform)
and are consumed by **pinned commit** `d56f94d742cb4238a19a707f416a945423b74ae2`
(`terraform/main.tf`, `.github/workflows/ci.yml`).

Linux only (Codespace 4-core / 16 GB). Put Aiven + LocalStack values in `.env`
(gitignored). Add the same names as **GitHub Actions secrets** on this repo.

```bash
git config core.hooksPath .githooks
set -a && source .env && set +a
make up
make verify
make down
```

### E2 — OIDC (`sub` must not be `repo:<org>/*`)

See `docs/oidc-trust-policy.json`. If `sub` is `repo:<org>/*`, any repository
in the organisation can assume the deploy role (a fork, a compromised
Dependabot branch, a teammate's throwaway). Scope `sub` to
`repo:yordanoshagos/db-capacity-engineering-lab:ref:refs/heads/main`.

### Ordering

Group `main` is already at `d56f94d…` (reusable `app_dir` / `terraform_dir`). This repo pins that SHA in `terraform/main.tf` and `.github/workflows/ci.yml`.

See `FIDELITY.md` and `CONTRIBUTIONS.md`.
