#!/bin/bash
# Keycloak 全量初始化（幂等）
# 两阶段设计:
#   Phase 1 - master realm: 创建永久 Keycloak 管理员，禁用 bootstrap 管理员
#   Phase 2 - grafana realm: 创建 realm、client、用户、groups 等
#
# 依赖: curl, jq
# 用法: ./scripts/kc-setup.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

[ -f .env ] && source .env

: "${HOST_IP:?Required}"
: "${KC_PORT:?Required}"
: "${KC_REALM:=grafana}"
: "${KC_BOOTSTRAP_ADMIN_USER:=admin-temporay}"
: "${KC_BOOTSTRAP_ADMIN_PASS:=change_me}"
: "${KC_ADMIN_USER:=admin}"
: "${KC_ADMIN_PASS:=admin_pass}"
: "${KC_ADMIN_EMAIL:=admin@example.com}"
: "${GF_ADMIN_USER:=admin}"
: "${GF_ADMIN_PASS:=admin}"
: "${GRAFANA_CLIENT_SECRET:?Required}"
: "${VMADMIN_PASS:=vmadmin_pass}"

KC_URL="http://${HOST_IP}:${KC_PORT}"

jq_raw() { echo "$1" | jq -r "${2:-.} // empty" 2>/dev/null || echo ""; }

get_token() {
  curl -sf --connect-timeout 5 --max-time 10 \
    -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=admin-cli" \
    -d "grant_type=password" \
    -d "username=$1" \
    -d "password=$2" | jq -r '.access_token // empty'
}

# ------------------------------------------------------------------
# Phase 0: Check if permanent admin already works
# ------------------------------------------------------------------
echo "=== Phase 0: Check permanent admin ==="
ADMIN_TOKEN=$(get_token "${KC_ADMIN_USER}" "${KC_ADMIN_PASS}")
if [ -n "${ADMIN_TOKEN}" ]; then
  echo "  Permanent admin token OK - skipping Phase 1"
  BOOTSTRAP_USED=false
else
  BOOTSTRAP_USED=true
  echo "  Permanent admin not available - need bootstrap"
fi

# ------------------------------------------------------------------
# Phase 1: Bootstrap in master realm
# ------------------------------------------------------------------
if [ "${BOOTSTRAP_USED}" = true ]; then
  echo ""
  echo "=== Phase 1: Bootstrap permanent admin ==="

  BOOTSTRAP_TOKEN=$(get_token "${KC_BOOTSTRAP_ADMIN_USER}" "${KC_BOOTSTRAP_ADMIN_PASS}")
  if [ -z "${BOOTSTRAP_TOKEN}" ]; then
    echo "ERROR: Bootstrap user ${KC_BOOTSTRAP_ADMIN_USER} cannot authenticate"
    exit 1
  fi
  echo "  Bootstrap token OK"

  ADMIN_UID=$(jq_raw "$(curl -sf "${KC_URL}/admin/realms/master/users?username=${KC_ADMIN_USER}&exact=true" \
    -H "Authorization: Bearer ${BOOTSTRAP_TOKEN}")" '.[0].id')

  if [ -z "${ADMIN_UID}" ]; then
    curl -sf -X POST "${KC_URL}/admin/realms/master/users" \
      -H "Authorization: Bearer ${BOOTSTRAP_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg u "${KC_ADMIN_USER}" \
        --arg e "${KC_ADMIN_EMAIL}" \
        '{username: $u, email: $e, emailVerified: true, enabled: true, firstName: $u, lastName: "-"}')" > /dev/null
    ADMIN_UID=$(jq_raw "$(curl -sf "${KC_URL}/admin/realms/master/users?username=${KC_ADMIN_USER}&exact=true" \
      -H "Authorization: Bearer ${BOOTSTRAP_TOKEN}")" '.[0].id')
    echo "  User ${KC_ADMIN_USER} created"
  else
    echo "  User ${KC_ADMIN_USER} already exists"
  fi

  curl -sf -X PUT "${KC_URL}/admin/realms/master/users/${ADMIN_UID}/reset-password" \
    -H "Authorization: Bearer ${BOOTSTRAP_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"type\": \"password\", \"value\": \"${KC_ADMIN_PASS}\", \"temporary\": false}" > /dev/null
  echo "  Password set for ${KC_ADMIN_USER}"

  ADMIN_ROLE_ID=$(jq_raw "$(curl -sf "${KC_URL}/admin/realms/master/roles" \
    -H "Authorization: Bearer ${BOOTSTRAP_TOKEN}")" '.[] | select(.name == "admin") | .id')
  if [ -n "${ADMIN_ROLE_ID}" ]; then
    curl -sf -X POST "${KC_URL}/admin/realms/master/users/${ADMIN_UID}/role-mappings/realm" \
      -H "Authorization: Bearer ${BOOTSTRAP_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "[{\"id\": \"${ADMIN_ROLE_ID}\", \"name\": \"admin\"}]" > /dev/null
    echo "  Admin role assigned"
  fi

  ADMIN_TOKEN=$(get_token "${KC_ADMIN_USER}" "${KC_ADMIN_PASS}")
  if [ -z "${ADMIN_TOKEN}" ]; then
    echo "ERROR: Permanent admin cannot authenticate after setup"
    exit 1
  fi
  echo "  Permanent admin verified"

  BOOTSTRAP_UID=$(jq_raw "$(curl -sf "${KC_URL}/admin/realms/master/users?username=${KC_BOOTSTRAP_ADMIN_USER}&exact=true" \
    -H "Authorization: Bearer ${BOOTSTRAP_TOKEN}")" '.[0].id')
  if [ -n "${BOOTSTRAP_UID}" ]; then
    curl -sf -X PUT "${KC_URL}/admin/realms/master/users/${BOOTSTRAP_UID}" \
      -H "Authorization: Bearer ${BOOTSTRAP_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"enabled": false}' > /dev/null
    echo "  Bootstrap user ${KC_BOOTSTRAP_ADMIN_USER} disabled"
  fi
fi

# ------------------------------------------------------------------
# Phase 2: Setup grafana realm
# ------------------------------------------------------------------
echo ""
echo "=== Phase 2: Setup ${KC_REALM} realm ==="

GRAFANA_LOGIN_REDIRECT_URI="http://${HOST_IP}:${GRAFANA_PORT:-3001}/login/generic_oauth"
GRAFANA_POST_LOGOUT_REDIRECT_URI="http://${HOST_IP}:${GRAFANA_PORT:-3001}/login"

REALMS_JSON=$(curl -sf "${KC_URL}/admin/realms" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")
REALM_EXISTS=$(echo "${REALMS_JSON}" | jq ". // [] | any(.realm == \"${KC_REALM}\")")

if [ "${REALM_EXISTS}" != "true" ]; then
  curl -sf -X POST "${KC_URL}/admin/realms" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg r "${KC_REALM}" '{realm: $r, enabled: true}')" > /dev/null
  echo "  Realm ${KC_REALM} created"
else
  echo "  Realm ${KC_REALM} already exists"
fi

CLIENT_UUID=$(jq_raw "$(curl -sf "${KC_URL}/admin/realms/${KC_REALM}/clients?clientId=grafana" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")" '.[0].id // empty')

if [ -z "${CLIENT_UUID}" ]; then
  curl -sf -X POST "${KC_URL}/admin/realms/${KC_REALM}/clients" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg login_uri "${GRAFANA_LOGIN_REDIRECT_URI}" \
      --arg logout_uri "${GRAFANA_POST_LOGOUT_REDIRECT_URI}" \
      '{
        clientId: "grafana",
        name: "Grafana",
        protocol: "openid-connect",
        publicClient: false,
        authorizationServicesEnabled: true,
        serviceAccountsEnabled: true,
        standardFlowEnabled: true,
        directAccessGrantsEnabled: true,
        redirectUris: [$login_uri],
        attributes: {
          "post.logout.redirect.uris": $logout_uri
        }
      }')" > /dev/null
  CLIENT_UUID=$(jq_raw "$(curl -sf "${KC_URL}/admin/realms/${KC_REALM}/clients?clientId=grafana" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}")" '.[0].id')
  echo "  Client grafana created"
else
  echo "  Client grafana already exists"
fi

if [ -z "${CLIENT_UUID}" ]; then
  echo "ERROR: Client grafana was not created or could not be queried"
  exit 1
fi

CLIENT_JSON=$(curl -sf "${KC_URL}/admin/realms/${KC_REALM}/clients/${CLIENT_UUID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")

curl -sf -X PUT "${KC_URL}/admin/realms/${KC_REALM}/clients/${CLIENT_UUID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(printf '%s' "${CLIENT_JSON}" | jq -c \
    --arg secret "${GRAFANA_CLIENT_SECRET}" \
    --arg login_uri "${GRAFANA_LOGIN_REDIRECT_URI}" \
    --arg logout_uri "${GRAFANA_POST_LOGOUT_REDIRECT_URI}" \
    '.secret = $secret
    | .redirectUris = [$login_uri]
    | .attributes = ((.attributes // {}) + {"post.logout.redirect.uris": $logout_uri})')" > /dev/null
echo "  Client grafana synced (UUID: ${CLIENT_UUID})"

echo ""
echo "--- Step: Add protocol mappers ---"
EXISTING_MAPPERS=$(curl -sf "${KC_URL}/admin/realms/${KC_REALM}/clients/${CLIENT_UUID}/protocol-mappers/models" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")

create_mapper() {
  local name=$1 json=$2
  local exists=$(echo "${EXISTING_MAPPERS}" | jq ". // [] | any(.name == \"${name}\")")
  if [ "${exists}" = "true" ]; then
    echo "  Mapper ${name} already exists"
  else
    echo "${json}" | curl -sf -X POST "${KC_URL}/admin/realms/${KC_REALM}/clients/${CLIENT_UUID}/protocol-mappers/models" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d @- > /dev/null && echo "  Mapper ${name} created"
  fi
}

create_mapper "groups" '{
  "name": "groups",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-group-membership-mapper",
  "config": {
    "claim.name": "groups",
    "full.path": "false",
    "id.token.claim": "true",
    "access.token.claim": "true",
    "userinfo.token.claim": "true"
  }
}'

echo ""
echo "--- Step: Create groups ---"
EXISTING_GROUPS=$(curl -sf "${KC_URL}/admin/realms/${KC_REALM}/groups" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")

for group in role-grafanaAdmin role-admin role-editor; do
  exists=$(echo "${EXISTING_GROUPS}" | jq ". // [] | any(.name == \"${group}\")")
  if [ "${exists}" = "true" ]; then
    echo "  Group ${group} already exists"
  else
    curl -sf -X POST "${KC_URL}/admin/realms/${KC_REALM}/groups" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"${group}\"}" > /dev/null && echo "  Group ${group} created"
  fi
done



echo ""
echo "KC init complete"
