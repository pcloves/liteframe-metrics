#!/bin/bash
# 新增租户用户（Keycloak + vmauth 同步）
#
# 用法: ./scripts/kc-add-user.sh <org-name> <username> <password> <role>
#   角色: admin | editor | viewer
# 示例:
#   ./scripts/kc-add-user.sh test userA passA editor
#   ./scripts/kc-add-user.sh test userB passB viewer
#
# 前置条件: 先运行 ./scripts/grafana-add-org.sh <org-name> <account_id>

set -euo pipefail

if [ $# -ne 5 ]; then
  echo "Usage: $0 <org-name> <username> <password> <role> <email>"
  echo "  role: admin | editor | viewer | grafanaAdmin"
  echo "Example: $0 org-test alice passA editor alice@example.com"
  exit 1
fi

ORG_NAME=$1
USERNAME=$2
PASSWORD=$3
ROLE=$4
EMAIL=$5

case "$ROLE" in
  grafanaAdmin|admin|editor|viewer) ;;
  *) echo "ERROR: role must be admin, editor, viewer, or grafanaAdmin"; exit 1 ;;
esac
GROUP_NAME="${ORG_NAME}"
[ "${ORG_NAME}" = "main" ] && GROUP_NAME="org-main"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

[ -f .env ] && source .env
: "${HOST_IP:?Required}"
: "${KC_PORT:?Required}"
: "${KC_REALM:=grafana}"
: "${KC_ADMIN_USER:=admin}"
: "${KC_ADMIN_PASS:=admin_pass}"
: "${GRAFANA_CLIENT_SECRET:?Required}"

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
echo "=== Step 2: Look up org group ${GROUP_NAME} ==="
GROUP_ID=$(curl -sf "${KC_URL}/admin/realms/${REALM}/groups" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r ".[] | select(.name == \"${GROUP_NAME}\") | .id // empty")
if [ -z "${GROUP_ID}" ]; then
  echo "ERROR: Group ${GROUP_NAME} not found in Keycloak."
  echo "  Run ./scripts/grafana-add-org.sh ${ORG_NAME} <account_id> first."
  exit 1
fi
  echo "  Found group ${GROUP_NAME} (id=${GROUP_ID})"

# Look up role group ID
ROLE_GROUP_ID=""
ROLE_GROUP_NAME=""
case "$ROLE" in
  grafanaAdmin) ROLE_GROUP_NAME="role-grafanaAdmin" ;;
  admin)        ROLE_GROUP_NAME="role-admin" ;;
  editor)       ROLE_GROUP_NAME="role-editor" ;;
esac
if [ -n "$ROLE_GROUP_NAME" ]; then
  ROLE_GROUP_ID=$(curl -sf "${KC_URL}/admin/realms/${REALM}/groups" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r ".[] | select(.name == \"${ROLE_GROUP_NAME}\") | .id // empty")
  if [ -z "$ROLE_GROUP_ID" ]; then
    echo "  WARNING: ${ROLE_GROUP_NAME} group not found in Keycloak, skipping role assignment"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Step 5: Create Keycloak user ==="
KC_UID=$(curl -sf "${KC_URL}/admin/realms/${REALM}/users?username=${USERNAME}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[0].id // empty')

if [ -n "${KC_UID}" ]; then
  echo "  User ${USERNAME} already exists (uid: ${KC_UID})"
else
  curl -sf -X POST "${KC_URL}/admin/realms/${REALM}/users" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg u "$USERNAME" --arg e "$EMAIL" --arg p "$PASSWORD" \
      '{username: $u, email: $e, emailVerified: true, enabled: true, firstName: $u, lastName: "-",
        credentials: [{type: "password", value: $p, temporary: false}]}')" > /dev/null

  KC_UID=$(curl -sf "${KC_URL}/admin/realms/${REALM}/users?username=${USERNAME}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[0].id')
  echo "  User ${USERNAME} created"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Step 6: Assign user to groups ==="
curl -sf -X PUT "${KC_URL}/admin/realms/${REALM}/users/${KC_UID}/groups/${GROUP_ID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" > /dev/null 2>&1 && echo "  Assigned to ${GROUP_NAME}"

if [ -n "${ROLE_GROUP_ID}" ]; then
  curl -sf -X PUT "${KC_URL}/admin/realms/${REALM}/users/${KC_UID}/groups/${ROLE_GROUP_ID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" > /dev/null 2>&1 && echo "  Assigned to ${ROLE} role group"
fi

echo ""
echo "Done"