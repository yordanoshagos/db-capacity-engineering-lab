#!/usr/bin/env bash
# C7 — inject OPS-2204 (docker kill) and wait until Prometheus shows firing.
# Other incidents: BASE_URL=... k6 run load-tests/reproduce-OPS-220X.js
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROM="${PROM_URL:-http://127.0.0.1:9090}"
OUT="${ROOT}/evidence/07-incidents/2204"
mkdir -p "$OUT"

echo "# 2204 inject $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee "$OUT/inject.txt"
echo "up before: $(curl -fsS "${PROM}/api/v1/query?query=up%7Bjob%3D%22capacity-api%22%7D" | jq -c .data.result)" | tee -a "$OUT/inject.txt"
docker kill capacity-api 2>/dev/null || docker stop capacity-api
sleep 20
echo "up after:  $(curl -fsS "${PROM}/api/v1/query?query=up%7Bjob%3D%22capacity-api%22%7D" | jq -c .data.result)" | tee -a "$OUT/inject.txt"
curl -fsS "${PROM}/api/v1/alerts" | jq '.data.alerts[] | {alertname:.labels.alertname, state:.state, incident:.labels.incident}' | tee "$OUT/alerts.json"
echo "Open Grafana A2 dashboard (OPS-2204 up panel) and screenshot → evidence/06-observability/panels/2204.png"
echo "Then: docker start capacity-api   (or docker compose up -d capacity-api)"
