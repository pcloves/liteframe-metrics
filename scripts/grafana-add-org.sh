#!/bin/bash
# 新增 Grafana org + 创建共享 Keycloak 组 + 同步 datasource
#
# 用法:
#   ./scripts/grafana-add-org.sh --main           # 管理组（使用内置 Default 组织）
#   ./scripts/grafana-add-org.sh <org-name> <account_id> <display_name>  # 租户组
#
# 示例:
#   ./scripts/grafana-add-org.sh --main
#   ./scripts/grafana-add-org.sh org-test 10 测试组织
#
# 之后:
#   ./scripts/kc-add-user.sh <org-name> <username> <password> admin
#   ./scripts/kc-add-user.sh <org-name> <username> <password> editor
#   ./scripts/kc-add-user.sh <org-name> <username> <password> viewer

set -euo pipefail

IS_MAIN=false
if [ "${1:-}" = "--main" ]; then
  IS_MAIN=true
  ORG_NAME="main"
  ACCOUNT_ID="${2:-0}"
elif [ $# -eq 3 ]; then
  ORG_NAME=$1
  ACCOUNT_ID=$2
  DISPLAY_NAME=$3
  if ! [[ "$ACCOUNT_ID" =~ ^[0-9]+$ ]]; then
    echo "Error: account_id must be a number, got: $ACCOUNT_ID"
    exit 1
  fi
else
  echo "Usage:"
  echo "  $0 --main"
  echo "  $0 <org-name> <account_id> <display_name>"
  echo ""
  echo "Examples:"
  echo "  $0 --main"
  echo "  $0 org-test 10 测试组织"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

[ -f .env ] && source .env
: "${HOST_IP:?Required}"
: "${GRAFANA_PORT:=3001}"
: "${GF_ADMIN_USER:=admin}"
: "${GF_ADMIN_PASS:=admin}"
: "${GRAFANA_CLIENT_SECRET:?Required}"
: "${KC_PORT:?Required}"
: "${KC_ADMIN_USER:=admin}"
: "${KC_ADMIN_PASS:=admin_pass}"
: "${KC_ADMIN_EMAIL:=admin@example.com}"
: "${KC_REALM:=grafana}"

GRAFANA_URL="http://${HOST_IP}:${GRAFANA_PORT}"
BASIC_AUTH="${GF_ADMIN_USER}:${GF_ADMIN_PASS}"
B64_AUTH=$(echo -n "${BASIC_AUTH}" | base64 -w0)
SSO_API="${GRAFANA_URL}/api/v1/sso-settings/generic_oauth"
KC_URL="http://${HOST_IP}:${KC_PORT}"
REALM="${KC_REALM}"
GROUP_NAME="${ORG_NAME}"
ROLE_ATTRIBUTE_PATH="contains(groups[*], 'role-grafanaAdmin') && 'GrafanaAdmin' || contains(groups[*], 'role-admin') && 'Admin' || contains(groups[*], 'role-editor') && 'Editor' || 'Viewer'"
[ "${IS_MAIN}" = true ] && GROUP_NAME="org-main"

# ---------------------------------------------------------------------------
echo "=== Step 1: Get Keycloak admin token ==="
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
echo "=== Step 2: Create/ensure Keycloak group ${GROUP_NAME} ==="
GROUP_ID=$(curl -sf "${KC_URL}/admin/realms/${REALM}/groups" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r ".[] | select(.name == \"${GROUP_NAME}\") | .id // empty")

if [ -z "${GROUP_ID}" ]; then
  GROUP_ID=$(curl -sf -X POST "${KC_URL}/admin/realms/${REALM}/groups" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${GROUP_NAME}\", \"attributes\": {\"metrics_account_id\": [\"${ACCOUNT_ID}\"]}}" 2>/dev/null && \
    curl -sf "${KC_URL}/admin/realms/${REALM}/groups" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r ".[] | select(.name == \"${GROUP_NAME}\") | .id")
  echo "  Created group ${GROUP_NAME} with account_id=${ACCOUNT_ID}"
else
  GROUP_JSON=$(curl -sf "${KC_URL}/admin/realms/${REALM}/groups/${GROUP_ID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}")
  echo "${GROUP_JSON}" | jq --arg aid "$ACCOUNT_ID" '.attributes.metrics_account_id = [$aid]' | \
    curl -sf -X PUT "${KC_URL}/admin/realms/${REALM}/groups/${GROUP_ID}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d @- > /dev/null
  echo "  Group ${GROUP_NAME} already exists, updated account_id=${ACCOUNT_ID}"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2b: Add Keycloak admin to group ${GROUP_NAME} ==="
KC_ADMIN_UID=$(curl -sf "${KC_URL}/admin/realms/${REALM}/users?username=${KC_ADMIN_USER}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[0].id // empty')
if [ -n "${KC_ADMIN_UID}" ]; then
  ADMIN_IN_GROUP=$(curl -sf "${KC_URL}/admin/realms/${REALM}/users/${KC_ADMIN_UID}/groups" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r ".[] | select(.id == \"${GROUP_ID}\") | .id // empty")
  if [ -z "${ADMIN_IN_GROUP}" ]; then
    curl -sf -X PUT "${KC_URL}/admin/realms/${REALM}/users/${KC_ADMIN_UID}/groups/${GROUP_ID}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" > /dev/null
    echo "  Admin ${KC_ADMIN_USER} added to ${GROUP_NAME}"
  else
    echo "  Admin ${KC_ADMIN_USER} already in ${GROUP_NAME}"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3: Resolve Grafana org ==="
if [ "${IS_MAIN}" = true ]; then
  ORG_ID=1
  GRAFANA_ORG_NAME=$(curl -sf "${GRAFANA_URL}/api/orgs/${ORG_ID}" \
    -H "Authorization: Basic ${B64_AUTH}" | jq -r '.name // "Main Org."')
  echo "  Using built-in org: ${GRAFANA_ORG_NAME} (id=${ORG_ID})"
else
  GRAFANA_ORG_NAME="${DISPLAY_NAME}"
  ORGS_JSON=$(curl -sf "${GRAFANA_URL}/api/orgs" -H "Authorization: Basic ${B64_AUTH}")
  EXISTS=$(echo "${ORGS_JSON}" | jq ". // [] | any(.name == \"${GRAFANA_ORG_NAME}\")")
  if [ "${EXISTS}" = "true" ]; then
    ORG_ID=$(echo "${ORGS_JSON}" | jq -r ".[] | select(.name == \"${GRAFANA_ORG_NAME}\") | .id")
    echo "  Org ${GRAFANA_ORG_NAME} already exists (id=${ORG_ID})"
  else
    echo ""
    echo "--- Create org ---"
    RESULT=$(curl -sf -X POST "${GRAFANA_URL}/api/orgs" \
      -H "Authorization: Basic ${B64_AUTH}" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"${GRAFANA_ORG_NAME}\"}")
    ORG_ID=$(echo "${RESULT}" | jq -r '.orgId // "?"')
    echo "  Created org ${GRAFANA_ORG_NAME} (id=${ORG_ID})"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3b: Store grafana_org_id in Keycloak group ==="
GROUP_JSON=$(curl -sf "${KC_URL}/admin/realms/${REALM}/groups/${GROUP_ID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")
echo "${GROUP_JSON}" | jq --arg oid "$ORG_ID" '.attributes.grafana_org_id = [$oid]' | \
  curl -sf -X PUT "${KC_URL}/admin/realms/${REALM}/groups/${GROUP_ID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d @- > /dev/null
echo "  Set grafana_org_id=${ORG_ID} on group ${GROUP_NAME}"

# ---------------------------------------------------------------------------
echo ""
echo "=== Step 4: Add admins to org ==="
MEMBERS=$(curl -sf "${GRAFANA_URL}/api/orgs/${ORG_ID}/users" \
  -H "Authorization: Basic ${B64_AUTH}")
for LOGIN in "${GF_ADMIN_USER}" "${KC_ADMIN_EMAIL}"; do
  USER_ID=$(curl -s "${GRAFANA_URL}/api/users/lookup?loginOrEmail=${LOGIN}" \
    -H "Authorization: Basic ${B64_AUTH}" | jq -r '.id // empty')
  [ -z "${USER_ID}" ] && continue
  IS_MEMBER=$(echo "${MEMBERS}" | jq ". // [] | any(.userId == ${USER_ID})")
  if [ "${IS_MEMBER}" = "true" ]; then
    echo "  User ${LOGIN} already in org ${GRAFANA_ORG_NAME}"
  else
    curl -sf -X POST "${GRAFANA_URL}/api/orgs/${ORG_ID}/users" \
      -H "Authorization: Basic ${B64_AUTH}" \
      -H "Content-Type: application/json" \
      -d "{\"loginOrEmail\": \"${LOGIN}\", \"role\": \"Admin\"}" > /dev/null
    echo "  User ${LOGIN} added to org ${GRAFANA_ORG_NAME} as Admin"
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== Step 5: Update OAuth org mapping ==="
FULL=$(curl -sf "${SSO_API}" -H "Authorization: Basic ${B64_AUTH}")
CURRENT_MAPPING=$(echo "${FULL}" | jq -r '.settings.orgMapping // ""')
ORG_ROLE="Viewer"
NEW_ENTRY="${GROUP_NAME}:${ORG_ID}:${ORG_ROLE}"

if echo "${CURRENT_MAPPING}" | grep -qF "${NEW_ENTRY}"; then
  echo "  Org mapping already exists: ${NEW_ENTRY}"
  NEW_MAPPING="${CURRENT_MAPPING}"
else
  NEW_MAPPING="${CURRENT_MAPPING} ${NEW_ENTRY}"
  NEW_MAPPING=$(echo "${NEW_MAPPING}" | xargs)
fi
SIGNOUT_URL="${KC_URL}/realms/${REALM}/protocol/openid-connect/logout?post_logout_redirect_uri=${GRAFANA_URL}/login"
echo "${FULL}" | jq \
  --arg mapping "${NEW_MAPPING}" \
  --arg secret "${GRAFANA_CLIENT_SECRET}" \
  --arg rolePath "${ROLE_ATTRIBUTE_PATH}" \
  --arg logoutUrl "${SIGNOUT_URL}" \
  '.settings.orgAttributePath = "groups" | .settings.orgMapping = $mapping | .settings.clientSecret = $secret | .settings.roleAttributePath = $rolePath | .settings.allowAssignGrafanaAdmin = true | .settings.signoutRedirectUrl = $logoutUrl' | \
curl -sf -X PUT "${SSO_API}" \
  -H "Authorization: Basic ${B64_AUTH}" \
  -H "Content-Type: application/json" \
  -d @- > /dev/null
echo "  OAuth settings updated"

# ---------------------------------------------------------------------------
echo ""
echo "=== Step 6: Create per-org vmauth entry and datasource ==="

# Generate deterministic org password
ORG_PASS=$(echo -n "${ORG_NAME}:${GRAFANA_CLIENT_SECRET}" | sha256sum | cut -c1-20)

# Create vmauth auth.d entry
AUTH_D_FILE="vmauth/auth.d/${GROUP_NAME}.yaml"
jq -n \
  --arg u "${GROUP_NAME}" \
  --arg p "${ORG_PASS}" \
  --argjson a "${ACCOUNT_ID}" \
  '{
    username: $u,
    password: $p,
    url_map: [
      {
        src_paths: ["/select/.*"],
        drop_src_path_prefix_parts: 1,
        url_prefix: [
          "http://vmselect-1:8481/select/\($a)/prometheus/",
          "http://vmselect-2:8481/select/\($a)/prometheus/"
        ]
      },
      {
        src_paths: ["/api/v1/import/prometheus"],
        url_prefix: [
          "http://vminsert-1:8480/insert/\($a)/prometheus/",
          "http://vminsert-2:8480/insert/\($a)/prometheus/"
        ]
      }
    ]
  }' | yq -P > "${AUTH_D_FILE}"
echo "  Created ${AUTH_D_FILE}"

# Switch to the target org context
curl -sf -X POST "${GRAFANA_URL}/api/user/using/${ORG_ID}" \
  -H "Authorization: Basic ${B64_AUTH}" > /dev/null

# Check if datasource already exists in this org
DS_UID="vmauth-cluster"
DS_EXISTS=$(curl -s "${GRAFANA_URL}/api/datasources/uid/${DS_UID}" \
  -H "Authorization: Basic ${B64_AUTH}" | jq -r '.uid // ""' 2>/dev/null || echo "")

if [ -n "${DS_EXISTS}" ]; then
  echo "  Datasource ${DS_UID} already exists in org ${GRAFANA_ORG_NAME}"
else
  RESULT=$(curl -s -X POST "${GRAFANA_URL}/api/datasources" \
    -H "Authorization: Basic ${B64_AUTH}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${DS_UID}\",
      \"uid\": \"${DS_UID}\",
      \"type\": \"prometheus\",
      \"url\": \"http://vmauth:8427/select\",
      \"access\": \"proxy\",
      \"isDefault\": true,
      \"basicAuth\": true,
      \"basicAuthUser\": \"${GROUP_NAME}\",
      \"secureJsonData\": {
        \"basicAuthPassword\": \"${ORG_PASS}\"
      }
    }" 2>/dev/null)
  if echo "${RESULT}" | jq -e '.datasource.id' > /dev/null 2>&1; then
    echo "  Datasource ${DS_UID} created in org ${GRAFANA_ORG_NAME}"
  else
    echo "  ERROR: Failed to create datasource: $(echo "${RESULT}" | jq -r '.message // "unknown"')"
  fi
fi

# Switch back to default org
curl -sf -X POST "${GRAFANA_URL}/api/user/using/1" \
  -H "Authorization: Basic ${B64_AUTH}" > /dev/null

# ---------------------------------------------------------------------------
echo ""
echo "=== Step 7: Regenerate auth.yaml and reload vmauth ==="
bash "${SCRIPT_DIR}/gen-auth.sh"
docker compose exec vmauth kill -HUP 1 2>/dev/null || echo "  (vmauth reload skipped - may not be running)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Step 8: Import default dashboards ==="
bash "${SCRIPT_DIR}/grafana-import-dashboards.sh" "${ORG_NAME}" --grafana-name "${GRAFANA_ORG_NAME}"

echo ""
echo "Done"
echo ""
echo "  Next, add users to this org:"
echo "    ./scripts/kc-add-user.sh ${ORG_NAME} <username> <password> admin <email>"
echo "    ./scripts/kc-add-user.sh ${ORG_NAME} <username> <password> editor <email>"
echo "    ./scripts/kc-add-user.sh ${ORG_NAME} <username> <password> viewer <email>"