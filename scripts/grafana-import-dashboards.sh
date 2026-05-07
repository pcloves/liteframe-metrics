#!/bin/bash
# 将默认 dashboards 导入到指定 Grafana org
#
# 用法:
#   ./scripts/grafana-import-dashboards.sh <org-name> [--grafana-name <name>] [--overwrite]
#   ./scripts/grafana-import-dashboards.sh --main [--overwrite]
#
# 依赖: curl, jq

set -euo pipefail

IS_MAIN=false
OVERWRITE=false
ORG_NAME=""

if [ "${1:-}" = "--main" ]; then
  IS_MAIN=true
  ORG_NAME="main"
  shift
elif [ -n "${1:-}" ]; then
  ORG_NAME=$1
  shift
fi

if [ "${1:-}" = "--grafana-name" ]; then
  GRAFANA_ORG_NAME=$2
  shift 2
fi

if [ "${1:-}" = "--overwrite" ]; then
  OVERWRITE=true
fi

if [ -z "${ORG_NAME}" ]; then
  echo "Usage:"
  echo "  $0 <org-name> [--grafana-name <name>] [--overwrite]"
  echo "  $0 --main [--overwrite]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

[ -f .env ] && source .env
: "${HOST_IP:?Required — set HOST_IP in .env}"
: "${GRAFANA_PORT:=3001}"
: "${GF_ADMIN_USER:=admin}"
: "${GF_ADMIN_PASS:=admin}"

GRAFANA_URL="http://${HOST_IP}:${GRAFANA_PORT}"
BASIC_AUTH="${GF_ADMIN_USER}:${GF_ADMIN_PASS}"
B64_AUTH=$(echo -n "${BASIC_AUTH}" | base64 -w0)

if [ "${IS_MAIN}" = true ] && [ -z "${GRAFANA_ORG_NAME}" ]; then
  GRAFANA_ORG_NAME=$(curl -sf "${GRAFANA_URL}/api/orgs/1" \
    -H "Authorization: Basic ${B64_AUTH}" | jq -r '.name // "Main Org."')
elif [ -z "${GRAFANA_ORG_NAME}" ]; then
  GRAFANA_ORG_NAME="${ORG_NAME}"
fi

DASHBOARDS_DIR="${PROJECT_DIR}/grafana/dashboards/default"

if [ ! -d "${DASHBOARDS_DIR}" ]; then
  echo "Dashboard directory not found: ${DASHBOARDS_DIR}"
  exit 0
fi

ORGS_JSON=$(curl -sf "${GRAFANA_URL}/api/orgs" -H "Authorization: Basic ${B64_AUTH}")
ORG_ID=$(echo "${ORGS_JSON}" | jq -r ".[] | select(.name == \"${GRAFANA_ORG_NAME}\") | .id // empty")

if [ -z "${ORG_ID}" ]; then
  echo "Org ${GRAFANA_ORG_NAME} not found — skipping dashboard import"
  exit 0
fi

echo "=== Importing dashboards into org ${GRAFANA_ORG_NAME} (id=${ORG_ID}) ==="

curl -sf -X POST "${GRAFANA_URL}/api/user/using/${ORG_ID}" \
  -H "Authorization: Basic ${B64_AUTH}" > /dev/null

i=0
for DASHBOARD_FILE in "${DASHBOARDS_DIR}"/*.json; do
  [ -f "${DASHBOARD_FILE}" ] || continue
  i=$((i + 1))
  DASHBOARD_NAME=$(basename "${DASHBOARD_FILE}" .json)

  TMP_FILE="/tmp/_import_${$}.json"
  trap "rm -f '${TMP_FILE}' 2>/dev/null" EXIT

  cp "${DASHBOARD_FILE}" "${TMP_FILE}"

  # Derive per-org uid
  BASE_UID=$(jq -r '.uid // ""' "${TMP_FILE}")
  [ -z "${BASE_UID}" ] && BASE_UID="${DASHBOARD_NAME}"
  NEW_UID="${BASE_UID}-${ORG_NAME}"

  jq --arg uid "${NEW_UID}" '.uid = $uid | .version = 1' "${TMP_FILE}" > "${TMP_FILE}.$$" && mv "${TMP_FILE}.$$" "${TMP_FILE}"

  # Skip if exists (unless overwrite)
  if [ "${OVERWRITE}" != "true" ]; then
    EXISTS=$(curl -s "${GRAFANA_URL}/api/dashboards/uid/${NEW_UID}" \
      -H "Authorization: Basic ${B64_AUTH}" | jq -r '.dashboard.uid // ""' 2>/dev/null || echo "")
    if [ -n "${EXISTS}" ]; then
      echo "  [SKIP] ${DASHBOARD_NAME} → uid=${NEW_UID} (exists)"
      rm -f "${TMP_FILE}"
      continue
    fi
  fi

  IMPORT_PAYLOAD=$(jq -n --slurpfile dashboard "${TMP_FILE}" '{
    dashboard: $dashboard[0],
    overwrite: true,
    message: "Imported by grafana-import-dashboards.sh"
  }')

  RESULT=$(curl -s -X POST "${GRAFANA_URL}/api/dashboards/db" \
    -H "Authorization: Basic ${B64_AUTH}" \
    -H "Content-Type: application/json" \
    -d "${IMPORT_PAYLOAD}")

  if echo "${RESULT}" | jq -e '.uid' > /dev/null 2>&1; then
    echo "  [OK]   ${DASHBOARD_NAME} → uid=${NEW_UID}"
  else
    echo "  [FAIL] ${DASHBOARD_NAME}: $(echo "${RESULT}" | jq -r '.message // "unknown"')"
  fi

  rm -f "${TMP_FILE}"
done

if [ "${i}" -eq 0 ]; then
  echo "  No dashboard JSONs found in ${DASHBOARDS_DIR}"
fi

curl -sf -X POST "${GRAFANA_URL}/api/user/using/1" \
  -H "Authorization: Basic ${B64_AUTH}" > /dev/null

echo "Done"
