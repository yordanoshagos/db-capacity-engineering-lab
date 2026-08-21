#!/usr/bin/env bash
# C4 — break the Secrets Manager password, prove /readyz → 503, restore.
# Run after `make up` with the app listening on APP_URL (default :3000).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/evidence/04-health/readyz-degraded.txt"
APP_URL="${APP_URL:-http://127.0.0.1:3000}"
TF_DIR="${TF_DIR:-${ROOT}/terraform}"
mkdir -p "$(dirname "$OUT")"

: "${AWS_ENDPOINT_URL:=http://localhost:4566}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

ARN="$(tflocal -chdir="${TF_DIR}" output -raw secret_arn)"
GOOD="$(awslocal secretsmanager get-secret-value --secret-id "$ARN" --query SecretString --output text)"
BAD="$(echo "$GOOD" | jq '.password = "definitely-wrong-password"')"

{
  echo "# C4 readyz-degraded  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "## 1. healthy"
  echo "GET ${APP_URL}/healthz -> $(curl -s -o /tmp/h.body -w '%{http_code}' "${APP_URL}/healthz")"
  cat /tmp/h.body; echo
  echo "GET ${APP_URL}/readyz  -> $(curl -s -o /tmp/r.body -w '%{http_code}' "${APP_URL}/readyz")"
  cat /tmp/r.body; echo
  echo "GET ${APP_URL}/debug/secret-source -> $(curl -s "${APP_URL}/debug/secret-source")"
  echo

  echo "## 2. break secret (wrong password in Secrets Manager) + restart app"
  awslocal secretsmanager put-secret-value --secret-id "$ARN" --secret-string "$BAD" >/dev/null
  docker restart capacity-api 2>/dev/null || true
  sleep 8
  echo "GET ${APP_URL}/healthz -> $(curl -s -o /tmp/h2.body -w '%{http_code}' "${APP_URL}/healthz")  (liveness must stay 200)"
  cat /tmp/h2.body; echo
  echo "GET ${APP_URL}/readyz  -> $(curl -s -o /tmp/r2.body -w '%{http_code}' "${APP_URL}/readyz")  (must be 503)"
  cat /tmp/r2.body; echo

  echo "## 3. restore secret + restart"
  awslocal secretsmanager put-secret-value --secret-id "$ARN" --secret-string "$GOOD" >/dev/null
  docker restart capacity-api 2>/dev/null || true
  sleep 8
  echo "GET ${APP_URL}/readyz  -> $(curl -s -o /tmp/r3.body -w '%{http_code}' "${APP_URL}/readyz")  (must be 200)"
  cat /tmp/r3.body; echo
} | tee "$OUT"

echo ">> wrote $OUT"
