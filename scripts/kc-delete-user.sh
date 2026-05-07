#!/bin/bash
# 禁用 / 删除 Keycloak 用户
#
# 用法:
#   ./scripts/kc-delete-user.sh <username>          # 禁用（默认，安全）
#   ./scripts/kc-delete-user.sh <username> --force   # 彻底删除
#
# 示例:
#   ./scripts/kc-delete-user.sh admin          # 禁用 admin
#   ./scripts/kc-delete-user.sh alice --force   # 彻底删除 alice

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage:"
  echo "  $0 <username>            # disable user (safe)"
  echo "  $0 <username> --force    # permanently delete"
  exit 1
fi

USERNAME=$1
FORCE=false
if [ "${2:-}" = "--force" ]; then
  FORCE=true
elif [ $# -gt 1 ]; then
  echo "Usage:"
  echo "  $0 <username>            # disable user (safe)"
  echo "  $0 <username> --force    # permanently delete"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

[ -f .env ] && source .env
: "${HOST_IP:?Required}"
: "${KC_PORT:?Required}"
: "${KC_REALM:=grafana}"
: "${KC_ADMIN_USER:=admin}"
: "${KC_ADMIN_PASS:=admin_pass}"

KC_URL="http://${HOST_IP}:${KC_PORT}"
REALM="${KC_REALM}"

# ---------------------------------------------------------------------------
echo "=== Step 1: Get admin token (from master realm) ==="
ADMIN_TOKEN=$(curl -sf --connect-timeout 5 --max-time 10 \
  -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli" \
  -d "grant_type=password" \
  -d "username=${KC_ADMIN_USER}" \
  -d "password=${KC_ADMIN_PASS}" | jq -r '.access_token')
echo "OK"

# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Look up user ${USERNAME} ==="
KC_UID=$(curl -sf "${KC_URL}/admin/realms/${REALM}/users?username=${USERNAME}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[0].id // empty')

if [ -z "${KC_UID}" ]; then
  echo "  User ${USERNAME} not found in Keycloak"
  exit 1
fi
echo "  Found user ${USERNAME} (uid: ${KC_UID})"

# ---------------------------------------------------------------------------
echo ""
if [ "${FORCE}" = true ]; then
  echo "=== Step 3: Permanently delete user ${USERNAME} ==="
  curl -sf -X DELETE "${KC_URL}/admin/realms/${REALM}/users/${KC_UID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" > /dev/null && echo "  User ${USERNAME} deleted"
else
  echo "=== Step 3: Disable user ${USERNAME} ==="
  USER_JSON=$(curl -sf "${KC_URL}/admin/realms/${REALM}/users/${KC_UID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}")
  echo "${USER_JSON}" | jq '.enabled = false' | \
    curl -sf -X PUT "${KC_URL}/admin/realms/${REALM}/users/${KC_UID}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d @- > /dev/null && echo "  User ${USERNAME} disabled"
  echo "  (use --force to permanently delete)"
fi

echo ""
echo "Done"
