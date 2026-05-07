#!/bin/bash
# Grafana 初始化（等待就绪 + 显示 org 状态）
# 在 kc-setup.sh 之后执行
#
# 依赖: curl, jq
# 用法: ./scripts/grafana-init.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

[ -f .env ] && source .env
: "${HOST_IP:?Required}"
: "${GRAFANA_PORT:=3001}"
: "${GF_ADMIN_PASS:=admin}"

GRAFANA_URL="http://${HOST_IP}:${GRAFANA_PORT}"
B64_AUTH=$(echo -n "admin:${GF_ADMIN_PASS}" | base64 -w0)

# ---------------------------------------------------------------------------
echo "=== Step 1: Wait for Grafana ==="
READY=false
for i in $(seq 1 60); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 \
    "${GRAFANA_URL}/api/orgs" -H "Authorization: Basic ${B64_AUTH}" 2>/dev/null || echo "ERR")
  if [ "${HTTP_CODE}" = "200" ]; then
    READY=true
    echo "Grafana ready"
    break
  fi
  echo "  waiting... ($i/60) HTTP=${HTTP_CODE}"
  sleep 2
done

if [ "${READY}" != "true" ]; then
  echo "  Grafana not ready after 120s - deployment continues, check Grafana manually"
  echo "  URL: ${GRAFANA_URL}  user: admin  pass: ${GF_ADMIN_PASS}"
  exit 0
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Show existing orgs ==="
curl -sf "${GRAFANA_URL}/api/orgs" -H "Authorization: Basic ${B64_AUTH}" | \
  jq -r '.[] | "  id=\(.id) name=\(.name)"'

echo "Grafana ready"
