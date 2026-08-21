# C7 — one folder per incident. Capture k6 console + Prometheus alert JSON + Grafana PNG.

Full treatment (Loom): **2204** — `./scripts/c7-inject-2204.sh`

Alert-only: 2201 / 2202 / 2203

```bash
export BASE_URL=http://127.0.0.1:3000
k6 run load-tests/reproduce-OPS-2201.js | tee evidence/07-incidents/2201/k6.txt
curl -s http://127.0.0.1:9090/api/v1/alerts | jq . > evidence/07-incidents/2201/alerts.json
```
