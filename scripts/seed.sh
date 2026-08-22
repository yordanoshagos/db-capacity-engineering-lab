#!/usr/bin/env bash
# =============================================================================
# scripts/seed.sh — C2: schema + 10k patients onto Aiven MySQL via mysqldump
# -----------------------------------------------------------------------------
# Migration path (assignment still requires mysqldump | mysql — no Cloud Pods):
#   1. spin a throwaway mysql:8.0
#   2. run data-seed/seed.sh (ROW_COUNT=10000); optional data-seed/01-fixes.sql
#   3. mysqldump
#   4. restore into Aiven over TLS
#
# Credentials come from Secrets Manager (never from git). Terraform wrote the
# Aiven envelope there at apply. Optional AIVEN_CA_PATH for VERIFY_CA.
# Aiven free-plan services sleep when idle — we retry until the host wakes.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${TF_DIR:-${ROOT}/terraform}"
ROW_COUNT="${ROW_COUNT:-10000}"
EVIDENCE="${ROOT}/evidence/02-data"
SRC_NAME="seed-src-$$"

: "${LOCALSTACK_AUTH_TOKEN:?export LOCALSTACK_AUTH_TOKEN}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

if ! command -v awslocal >/dev/null 2>&1; then
  echo "FAIL: awslocal not on PATH" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq not on PATH" >&2
  exit 1
fi
if ! command -v mysql >/dev/null 2>&1; then
  echo "FAIL: mysql client not on PATH" >&2
  exit 1
fi
if [[ ! -d "${TF_DIR}" ]]; then
  echo "FAIL: no Terraform root at ${TF_DIR}" >&2
  echo "      expected ${ROOT}/terraform or pass TF_DIR=..." >&2
  exit 1
fi

mkdir -p "${EVIDENCE}"
exec > >(tee -a "${EVIDENCE}/seed.log") 2>&1

echo ">> reading Terraform outputs from ${TF_DIR}"
pushd "${TF_DIR}" >/dev/null
SECRET_ARN="$(terraform output -raw secret_arn)"
popd >/dev/null

echo ">> fetching DB credentials from Secrets Manager ${SECRET_ARN}"
CREDS_JSON="$(awslocal secretsmanager get-secret-value \
  --secret-id "${SECRET_ARN}" --query SecretString --output text)"
DB_USER="$(echo "${CREDS_JSON}" | jq -r .username)"
DB_PASS="$(echo "${CREDS_JSON}" | jq -r .password)"
ENDPOINT="$(echo "${CREDS_JSON}" | jq -r .host)"
PORT="$(echo "${CREDS_JSON}" | jq -r .port)"
DB_NAME="$(echo "${CREDS_JSON}" | jq -r .dbname)"
unset CREDS_JSON

ssl_args=()
if [[ -n "${AIVEN_CA_PATH:-}" ]]; then
  if [[ ! -f "${AIVEN_CA_PATH}" ]]; then
    echo "FAIL: AIVEN_CA_PATH=${AIVEN_CA_PATH} is not a file" >&2
    exit 1
  fi
  ssl_args=(--ssl-mode=VERIFY_CA --ssl-ca="${AIVEN_CA_PATH}")
  echo ">> TLS: VERIFY_CA with ${AIVEN_CA_PATH}"
else
  ssl_args=(--ssl-mode=REQUIRED)
  echo ">> TLS: REQUIRED (set AIVEN_CA_PATH to the downloaded Aiven CA for VERIFY_CA)"
fi

mysql_aiven() {
  mysql -h "${ENDPOINT}" -P "${PORT}" -u "${DB_USER}" -p"${DB_PASS}" \
    --connect-timeout=20 "${ssl_args[@]}" "$@"
}

echo ">> waiting for Aiven ${ENDPOINT}:${PORT} (free plan sleeps when idle) ..."
awake=0
for _ in $(seq 1 36); do
  if mysql_aiven -e "SELECT 1" >/dev/null 2>&1; then
    awake=1
    break
  fi
  sleep 5
done
if [[ "${awake}" -ne 1 ]]; then
  echo "FAIL: Aiven never answered. Open the service in the Aiven console to wake it, then retry." >&2
  exit 1
fi
echo ">> Aiven is up"
echo ">> ensuring database ${DB_NAME} exists"
mysql_aiven -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"

cleanup() {
  docker rm -f "${SRC_NAME}" >/dev/null 2>&1 || true
  rm -f /tmp/capacity_lab.dump.sql
}
trap cleanup EXIT

echo ">> starting throwaway mysql:8.0 to generate a mysqldump (ROW_COUNT=${ROW_COUNT})"
# Do not pass --default-authentication-plugin: current mysql:8.0 images reject it
# and the container exits. Do not mysqladmin ping -p during first-boot: the
# entrypoint has not set the root password yet, so CI times out on a live init.
docker run -d --name "${SRC_NAME}" \
  -e MYSQL_ROOT_PASSWORD=labpassword \
  -e MYSQL_DATABASE=capacity_lab \
  mysql:8.0 >/dev/null

echo ">> waiting for throwaway MySQL ..."
ready=0
for i in $(seq 1 90); do
  if ! docker inspect -f '{{.State.Running}}' "${SRC_NAME}" 2>/dev/null | grep -qx true; then
    echo "FAIL: throwaway MySQL container is not running"
    docker ps -a --filter "name=${SRC_NAME}" || true
    docker logs "${SRC_NAME}" 2>&1 | tail -40 || true
    exit 1
  fi
  if docker exec "${SRC_NAME}" mysql -uroot -plabpassword --connect-timeout=2 -e "SELECT 1" >/dev/null 2>&1; then
    ready=1
    break
  fi
  echo "   ...still initialising (${i}/90)"
  sleep 3
done
if [[ "${ready}" -ne 1 ]]; then
  echo "FAIL: throwaway MySQL never became ready"
  docker logs "${SRC_NAME}" 2>&1 | tail -80 || true
  exit 1
fi

echo ">> loading schema + ${ROW_COUNT} patients into throwaway MySQL"
docker exec -e MYSQL_HOST=127.0.0.1 \
            -e MYSQL_PORT=3306 \
            -e MYSQL_USER=root \
            -e MYSQL_PASSWORD=labpassword \
            -e MYSQL_DATABASE=capacity_lab \
            -e ROW_COUNT="${ROW_COUNT}" \
            -i "${SRC_NAME}" bash < "${ROOT}/data-seed/seed.sh"
if [[ -f "${ROOT}/data-seed/01-fixes.sql" ]]; then
  docker exec -i "${SRC_NAME}" mysql -uroot -plabpassword capacity_lab \
    < "${ROOT}/data-seed/01-fixes.sql"
fi

echo ">> mysqldump throwaway → /tmp/capacity_lab.dump.sql"
docker exec "${SRC_NAME}" mysqldump -uroot -plabpassword \
  --single-transaction --routines --triggers capacity_lab \
  > /tmp/capacity_lab.dump.sql

echo ">> restoring dump into Aiven ${ENDPOINT}:${PORT}/${DB_NAME} as ${DB_USER} (TLS)"
mysql_aiven "${DB_NAME}" < /tmp/capacity_lab.dump.sql

echo ">> row counts (C2 evidence)"
{
  echo "# captured $(date -u +%Y-%m-%dT%H:%M:%SZ)  ROW_COUNT=${ROW_COUNT}"
  mysql_aiven "${DB_NAME}" -N -e "
      SELECT CONCAT('patients=', COUNT(*)) FROM patients;
      SELECT CONCAT('hospitals=', COUNT(*)) FROM hospitals;
    "
} | tee "${EVIDENCE}/row-counts.txt"

PATIENTS="$(awk -F= '/^patients=/{print $2}' "${EVIDENCE}/row-counts.txt")"
if [[ -z "${PATIENTS}" || "${PATIENTS}" -lt "${ROW_COUNT}" ]]; then
  echo "FAIL: expected ${ROW_COUNT} patients, got ${PATIENTS:-<empty>}" >&2
  exit 1
fi

echo ">> seed complete — ${PATIENTS} patients in Aiven ${DB_NAME}"
unset DB_PASS
