#!/bin/bash
# CardFrame VM Cluster - 一键部署入口
#
# 用法:
#   1. cp .env.example .env && vi .env    # 按实际环境修改
#   2. bash init.sh                        # 一键部署
#
# 步骤: gen-auth → docker compose up → kc-setup → grafana-add-org --main → kc-add-user main admin → grafana-oauth-sync

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo " CardFrame VM Cluster - Initialization"
echo "=========================================="

# ------------------------------------------------------------------
echo ""
echo "=== [1/5] Check prerequisites ==="
FAIL=0
for cmd in curl jq docker; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "  MISSING: $cmd"
    FAIL=1
  fi
done
if ! command -v yq &>/dev/null; then
  echo "  MISSING: yq (mikefarah/yq)"
  echo "  Install: https://github.com/mikefarah/yq#install"
  FAIL=1
elif ! yq --version 2>/dev/null | grep -qi mikefarah; then
  echo "  WRONG yq: $(yq --version 2>&1)"
  echo "  Required: mikefarah/yq v4.18+"
  echo "  Install: https://github.com/mikefarah/yq#install"
  FAIL=1
fi
if [ $FAIL -eq 1 ]; then
  exit 1
fi
echo "  All prerequisites found"

# ------------------------------------------------------------------
echo ""
echo "=== [2/5] Check .env ==="
if [ ! -f .env ]; then
  echo "  .env not found. Creating from .env.example..."
  cp .env.example .env
  echo "  Edit .env with your settings, then re-run init.sh"
  exit 1
fi
source .env
: "${HOST_IP:?Required - set HOST_IP in .env}"
: "${KC_BOOTSTRAP_ADMIN_PASS:?Required}"
: "${KC_ADMIN_PASS:?Required}"
: "${GRAFANA_CLIENT_SECRET:?Required}"
echo "  .env loaded (HOST_IP=${HOST_IP})"

# ------------------------------------------------------------------
echo ""
echo "=== [3/5] Generate vmauth config ==="
echo "  Cleaning up old tenant configs..."
find vmauth/auth.d -maxdepth 1 -name '[!_]*.yaml' -delete
bash scripts/gen-auth.sh

# ------------------------------------------------------------------
echo ""
echo "=== [4/5] Start Docker services ==="
docker compose up -d
echo "  Waiting for services..."
sleep 5

# ------------------------------------------------------------------
echo ""
echo "=== [5/7] Initialize Keycloak ==="
echo "  (waiting for Keycloak...)"
for i in $(seq 1 30); do
  if curl -sf "http://${HOST_IP}:${KC_PORT}/realms/master" > /dev/null 2>&1; then
    echo "  Keycloak ready"
    break
  fi
  echo "    waiting... ($i/30)"
  sleep 3
done

bash scripts/kc-setup.sh

# ------------------------------------------------------------------
echo ""
echo "=== [6/7] Setup main org ==="
echo "  (waiting for Grafana...)"

grafana_ready=false

# Pre-check: skip wait loop if Grafana is already responsive
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 \
  "http://${HOST_IP}:${GRAFANA_PORT}/api/orgs" -H "Authorization: Basic $(echo -n "admin:${GF_ADMIN_PASS}" | base64 -w0)" 2>/dev/null || echo "ERR")
if [ "${HTTP_CODE}" = "200" ]; then
  grafana_ready=true
  echo "  Grafana ready (already running)"
else
  for i in $(seq 1 60); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 \
      "http://${HOST_IP}:${GRAFANA_PORT}/api/orgs" -H "Authorization: Basic $(echo -n "admin:${GF_ADMIN_PASS}" | base64 -w0)" 2>/dev/null || echo "ERR")
    if [ "${HTTP_CODE}" = "200" ]; then
      grafana_ready=true
      echo "  Grafana ready"
      break
    fi
    echo "    waiting... ($i/60) HTTP=${HTTP_CODE}"
    sleep 2
  done
fi

if [ "${grafana_ready}" != "true" ]; then
  echo "  ERROR: Grafana not ready (HTTP=${HTTP_CODE})"
  echo "  Possible causes:"
  echo "    - Grafana is still starting up (try increasing the wait loop)"
  echo "    - GF_ADMIN_PASS in .env (current: '${GF_ADMIN_PASS}') doesn't match Grafana's admin password"
  echo "    - Fix: docker compose exec grafana grafana-cli admin reset-admin-password <new-password>"
  echo "           Then update GF_ADMIN_PASS in .env to match"
  exit 1
fi

bash scripts/grafana-add-org.sh --main
bash scripts/kc-add-user.sh main admin "${GF_ADMIN_PASS}" grafanaAdmin "${KC_ADMIN_EMAIL}"

echo ""
echo "=== [7/7] Sync Grafana OAuth ==="
bash scripts/grafana-oauth-sync.sh

echo ""
echo "=== Verify JWT ==="
TOKEN=$(curl -s \
  -X POST "http://${HOST_IP}:${KC_PORT}/realms/${KC_REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=grafana" \
  -d "client_secret=${GRAFANA_CLIENT_SECRET}" \
  -d "grant_type=password" \
  -d "username=${GF_ADMIN_USER}" \
  -d "password=${GF_ADMIN_PASS}" | jq -r '.access_token // "ERROR"')
if [ "${TOKEN}" != "ERROR" ]; then
  echo "${TOKEN}" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{
    username: .preferred_username,
    groups: .groups
  }' || true
fi

# ------------------------------------------------------------------
echo ""
echo "=========================================="
echo " Deployment complete!"
echo "=========================================="
echo ""
echo "  Grafana:   http://${HOST_IP}:${GRAFANA_PORT:-3001}"
echo "  Keycloak:  http://${HOST_IP}:${KC_PORT:-3002}"
echo "  vmauth:    http://${HOST_IP}:${VMAUTH_PORT:-8427}"
echo ""
echo "  Grafana OIDC (realm: ${KC_REALM:-grafana})"
echo "    admin user: admin / ${GF_ADMIN_PASS}"
echo "  Keycloak Admin (master realm):"
echo "    ${KC_ADMIN_USER} / ${KC_ADMIN_PASS}"
echo ""
echo "  Add a new tenant:"
echo "    ./scripts/grafana-add-org.sh <org-name> <account_id> <display_name>"
echo "    ./scripts/kc-add-user.sh  <org-name> <username> <password> <role>"

echo ""
echo "  Examples:"
echo "    ./scripts/grafana-add-org.sh --main"
echo "    ./scripts/grafana-add-org.sh org-test 10 测试组织"
  echo "    ./scripts/kc-add-user.sh  org-test alice  passA admin  alice@example.com"
  echo "    ./scripts/kc-add-user.sh  org-test bob    passB viewer bob@example.com"
echo ""
echo '  Login to Grafana:'
echo "    Keycloak OIDC user: admin / ${GF_ADMIN_PASS}"
echo '    OAuth org mapping: {group_name}:{org_id}:{role} (immutable org ID, survives rename)'
