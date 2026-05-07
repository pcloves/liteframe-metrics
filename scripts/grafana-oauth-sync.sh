#!/bin/bash
# 全量同步 Grafana OAuth Org Mapping
# 根据当前存在的 Grafana orgs，动态构建 org_mapping
# 并在 admin 没有加入的 org 中自动加入 admin
#
# 依赖: curl, jq
# 用法: ./scripts/grafana-oauth-sync.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

[ -f .env ] && source .env
: "${HOST_IP:?Required}"
: "${GRAFANA_PORT:=3001}"
: "${GF_ADMIN_USER:=admin}"
: "${GF_ADMIN_PASS:=admin}"
: "${GRAFANA_CLIENT_SECRET:?Required}"
: "${KC_ADMIN_EMAIL:=admin@example.com}"
: "${KC_PORT:?Required}"
: "${KC_REALM:=grafana}"
: "${KC_ADMIN_USER:=admin}"
: "${KC_ADMIN_PASS:=admin_pass}"

ROLE_ATTRIBUTE_PATH="contains(groups[*], 'role-grafanaAdmin') && 'GrafanaAdmin' || contains(groups[*], 'role-admin') && 'Admin' || contains(groups[*], 'role-editor') && 'Editor' || 'Viewer'"

GRAFANA_URL="http://${HOST_IP}:${GRAFANA_PORT}"
BASIC_AUTH="${GF_ADMIN_USER}:${GF_ADMIN_PASS}"
B64_AUTH=$(echo -n "${BASIC_AUTH}" | base64 -w0)
SSO_API="${GRAFANA_URL}/api/v1/sso-settings/generic_oauth"
KC_URL="http://${HOST_IP}:${KC_PORT}"
REALM="${KC_REALM}"

echo "=== Step 1: Get current OAuth settings ==="
FULL=$(curl -sf "${SSO_API}" -H "Authorization: Basic ${B64_AUTH}")
CURRENT_MAPPING=$(echo "${FULL}" | jq -r '.settings.orgMapping // ""')
echo "  Current org_mapping: ${CURRENT_MAPPING}"

echo ""
echo "=== Step 2: Get Keycloak admin token ==="
ADMIN_TOKEN=$(curl -sf --connect-timeout 5 --max-time 10 \
  -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli" \
  -d "grant_type=password" \
  -d "username=${KC_ADMIN_USER}" \
  -d "password=${KC_ADMIN_PASS}" | jq -r '.access_token')
echo "OK"

echo ""
echo "=== Step 3: Scan all Grafana orgs ==="
ORGS_JSON=$(curl -sf "${GRAFANA_URL}/api/orgs" \
  -H "Authorization: Basic ${B64_AUTH}")

# Pre-fetch all KC groups (list API doesn't return attributes, so fetch each group individually)
KC_GROUPS=$(curl -sf "${KC_URL}/admin/realms/${REALM}/groups" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")

# Build a mapping of grafana_org_id -> group_name by fetching full details per group
declare -A KC_ORG_MAP
while read -r group; do
  GID=$(echo "${group}" | jq -r '.id // ""')
  GNAME=$(echo "${group}" | jq -r '.name // ""')
  [ -z "${GID}" ] && continue
  GRAFANA_ORG_ID=$(curl -sf "${KC_URL}/admin/realms/${REALM}/groups/${GID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.attributes.grafana_org_id[0] // ""')
  if [ -n "${GRAFANA_ORG_ID}" ]; then
    KC_ORG_MAP[${GRAFANA_ORG_ID}]="${GNAME}"
    echo "  KC group ${GNAME} -> grafana_org_id=${GRAFANA_ORG_ID}"
  fi
done < <(echo "${KC_GROUPS}" | jq -c '.[]')

MAPPING_ENTRIES=()
while read -r org; do
  ORG_NAME=$(echo "${org}" | jq -r '.name')
  ORG_ID=$(echo "${org}" | jq -r '.id')
  ORG_ROLE="Viewer"

  # Look up KC group by grafana_org_id attribute
  GROUP_NAME="${KC_ORG_MAP[${ORG_ID}]:-}"
  if [ -z "${GROUP_NAME}" ]; then
    echo "  WARNING: No KC group found for org \"${ORG_NAME}\" (id=${ORG_ID}), skipping"
    continue
  fi
  MAPPING_ENTRIES+=("${GROUP_NAME}:${ORG_ID}:${ORG_ROLE}")
  echo "  Org: ${ORG_NAME} (id=${ORG_ID}) -> ${GROUP_NAME}:${ORG_ID}:${ORG_ROLE}"
done < <(echo "${ORGS_JSON}" | jq -c '.[]')

if [ ${#MAPPING_ENTRIES[@]} -eq 0 ]; then
  echo "  No orgs found, skipping"
  exit 0
fi

NEW_MAPPING=$(
  IFS=' '
  echo "${MAPPING_ENTRIES[*]}"
)

echo ""
echo "=== Step 4: Update OAuth settings ==="
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

echo ""
echo "=== Step 5: Ensure admins are members of all orgs ==="
while read -r org; do
  ORG_NAME=$(echo "${org}" | jq -r '.name')
  ORG_ID=$(echo "${org}" | jq -r '.id')

  MEMBERS=$(curl -sf "${GRAFANA_URL}/api/orgs/${ORG_ID}/users" \
    -H "Authorization: Basic ${B64_AUTH}")

  for LOGIN in "${GF_ADMIN_USER}" "${KC_ADMIN_EMAIL}"; do
    USER_ID=$(curl -s "${GRAFANA_URL}/api/users/lookup?loginOrEmail=${LOGIN}" \
      -H "Authorization: Basic ${B64_AUTH}" | jq -r '.id // empty')
    [ -z "${USER_ID}" ] && continue
    IS_MEMBER=$(echo "${MEMBERS}" | jq ". // [] | any(.userId == ${USER_ID})")
    if [ "${IS_MEMBER}" = "true" ]; then
      echo "  ${LOGIN} already in org ${ORG_NAME}"
    else
      curl -sf -X POST "${GRAFANA_URL}/api/orgs/${ORG_ID}/users" \
        -H "Authorization: Basic ${B64_AUTH}" \
        -H "Content-Type: application/json" \
        -d "{\"loginOrEmail\": \"${LOGIN}\", \"role\": \"Admin\"}" > /dev/null
      echo "  ${LOGIN} added to org ${ORG_NAME} as Admin"
    fi
  done
done < <(echo "${ORGS_JSON}" | jq -c '.[]')

# ---------------------------------------------------------------------------
echo ""
echo "=== Step 6: Ensure datasource exists in all orgs ==="
while read -r org; do
  ORG_NAME=$(echo "${org}" | jq -r '.name')
  ORG_ID=$(echo "${org}" | jq -r '.id')

  # Switch to this org
  curl -s -X POST "${GRAFANA_URL}/api/user/using/${ORG_ID}" \
    -H "Authorization: Basic ${B64_AUTH}" > /dev/null 2>&1 || true

  DS_EXISTS=$(curl -s "${GRAFANA_URL}/api/datasources/uid/vmauth-cluster" \
    -H "Authorization: Basic ${B64_AUTH}" | jq -r '.uid // ""' 2>/dev/null || echo "")

  if [ -n "${DS_EXISTS}" ]; then
    echo "  Datasource OK in org ${ORG_NAME}"
  else
    RESULT=$(curl -s -X POST "${GRAFANA_URL}/api/datasources" \
      -H "Authorization: Basic ${B64_AUTH}" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"vmauth-cluster\", \"uid\": \"vmauth-cluster\", \"type\": \"prometheus\", \"url\": \"http://vmauth:8427/select\", \"access\": \"proxy\", \"isDefault\": true, \"jsonData\": {\"oauthPassThru\": true}}" 2>/dev/null)
    if echo "${RESULT}" | jq -e '.datasource.id' > /dev/null 2>&1; then
      echo "  Datasource created in org ${ORG_NAME}"
    else
      echo "  ERROR: Datasource failed in org ${ORG_NAME}: $(echo "${RESULT}" | jq -r '.message // "unknown"')"
    fi
  fi
done < <(echo "${ORGS_JSON}" | jq -c '.[]')

# Switch back to Main Org.
curl -s -X POST "${GRAFANA_URL}/api/user/using/1" \
  -H "Authorization: Basic ${B64_AUTH}" > /dev/null 2>&1 || true

echo ""
echo "OAuth sync complete"
