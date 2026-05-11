#!/usr/bin/env bash

kc_token() {
  local username=$1 password=$2
  curl -s -f --connect-timeout 5 --max-time 10 \
    -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=admin-cli" \
    -d "grant_type=password" \
    -d "username=${username}" \
    -d "password=${password}" | jq -r '.access_token // empty'
}

kc_admin_header() {
  printf 'Authorization: Bearer %s' "${ADMIN_TOKEN}"
}

kc_get_admin_token() {
  ADMIN_TOKEN="$(kc_token "${KC_ADMIN_USER}" "${KC_ADMIN_PASS}" || true)"
  [ -n "${ADMIN_TOKEN}" ] || die "Unable to authenticate Keycloak admin ${KC_ADMIN_USER}"
}

kc_group_name_for_org() {
  local org_name=$1
  if [ "${org_name}" = "main" ]; then
    printf 'org-main'
  else
    printf '%s' "${org_name}"
  fi
}

kc_get_user_id() {
  local username=$1 realm=${2:-${REALM}}
  http_get "${KC_URL}/admin/realms/${realm}/users?username=${username}&exact=true" "$(kc_admin_header)" | jq -r '.[0].id // empty'
}

kc_get_group_id() {
  local group_name=$1 realm=${2:-${REALM}}
  http_get "${KC_URL}/admin/realms/${realm}/groups" "$(kc_admin_header)" | jq -r ".[] | select(.name == \"${group_name}\") | .id // empty"
}

kc_ensure_group() {
  local group_name=$1 account_id=${2:-}
  local group_id group_json payload
  group_id="$(kc_get_group_id "${group_name}")"
  if [ -z "${group_id}" ]; then
    if [ -n "${account_id}" ]; then
      payload="$(jq -n --arg name "${group_name}" --arg aid "${account_id}" '{name: $name, attributes: {metrics_account_id: [$aid]}}')"
    else
      payload="$(jq -n --arg name "${group_name}" '{name: $name}')"
    fi
    http_post_json "${KC_URL}/admin/realms/${REALM}/groups" "${payload}" "$(kc_admin_header)" >/dev/null
    group_id="$(kc_get_group_id "${group_name}")"
    log_info "Created Keycloak group ${group_name}"
  else
    log_info "Keycloak group ${group_name} already exists"
  fi

  if [ -n "${account_id}" ]; then
    group_json="$(http_get "${KC_URL}/admin/realms/${REALM}/groups/${group_id}" "$(kc_admin_header)")"
    payload="$(printf '%s' "${group_json}" | jq --arg aid "${account_id}" '.attributes = ((.attributes // {}) + {metrics_account_id: [$aid]})')"
    http_put_json "${KC_URL}/admin/realms/${REALM}/groups/${group_id}" "${payload}" "$(kc_admin_header)" >/dev/null
    log_info "Set metrics_account_id=${account_id} on group ${group_name}"
  fi

  printf '%s' "${group_id}"
}

kc_set_group_attribute() {
  local group_id=$1 attr=$2 value=$3
  local group_json payload
  group_json="$(http_get "${KC_URL}/admin/realms/${REALM}/groups/${group_id}" "$(kc_admin_header)")"
  payload="$(printf '%s' "${group_json}" | jq --arg attr "${attr}" --arg value "${value}" '.attributes = ((.attributes // {}) + {($attr): [$value]})')"
  http_put_json "${KC_URL}/admin/realms/${REALM}/groups/${group_id}" "${payload}" "$(kc_admin_header)" >/dev/null
}

kc_ensure_user() {
  local username=$1 password=$2 email=$3
  local user_id payload
  user_id="$(kc_get_user_id "${username}")"
  if [ -z "${user_id}" ]; then
    payload="$(jq -n --arg u "${username}" --arg e "${email}" --arg p "${password}" \
      '{username: $u, email: $e, emailVerified: true, enabled: true, firstName: $u, lastName: "-", credentials: [{type: "password", value: $p, temporary: false}]}')"
    http_post_json "${KC_URL}/admin/realms/${REALM}/users" "${payload}" "$(kc_admin_header)" >/dev/null
    user_id="$(kc_get_user_id "${username}")"
    log_info "Created Keycloak user ${username}"
  else
    log_info "Keycloak user ${username} already exists"
  fi
  printf '%s' "${user_id}"
}

kc_assign_user_group() {
  local user_id=$1 group_id=$2 label=$3
  http_request PUT "${KC_URL}/admin/realms/${REALM}/users/${user_id}/groups/${group_id}" "" "$(kc_admin_header)" >/dev/null
  log_info "Assigned user to ${label}"
}

kc_remove_user_group() {
  local user_id=$1 group_id=$2 label=$3
  http_delete "${KC_URL}/admin/realms/${REALM}/users/${user_id}/groups/${group_id}" "$(kc_admin_header)" >/dev/null
  log_info "Removed user from ${label}"
}

kc_disable_user() {
  local user_id=$1 username=$2
  local user_json payload
  user_json="$(http_get "${KC_URL}/admin/realms/${REALM}/users/${user_id}" "$(kc_admin_header)")"
  payload="$(printf '%s' "${user_json}" | jq '.enabled = false')"
  http_put_json "${KC_URL}/admin/realms/${REALM}/users/${user_id}" "${payload}" "$(kc_admin_header)" >/dev/null
  log_info "Disabled Keycloak user ${username}"
}

kc_delete_user() {
  local user_id=$1 username=$2
  http_delete "${KC_URL}/admin/realms/${REALM}/users/${user_id}" "$(kc_admin_header)" >/dev/null
  log_info "Deleted Keycloak user ${username}"
}

kc_setup_base() {
  log_step "Setup Keycloak"
  local bootstrap_token admin_id admin_role_id bootstrap_id realms_json realm_exists client_uuid client_json payload existing_mappers existing_groups exists

  ADMIN_TOKEN="$(kc_token "${KC_ADMIN_USER}" "${KC_ADMIN_PASS}" || true)"
  if [ -z "${ADMIN_TOKEN}" ]; then
    log_info "Permanent admin unavailable; using bootstrap admin"
    bootstrap_token="$(kc_token "${KC_BOOTSTRAP_ADMIN_USER}" "${KC_BOOTSTRAP_ADMIN_PASS}" || true)"
    [ -n "${bootstrap_token}" ] || die "Bootstrap user ${KC_BOOTSTRAP_ADMIN_USER} cannot authenticate"

    admin_id="$(http_get "${KC_URL}/admin/realms/master/users?username=${KC_ADMIN_USER}&exact=true" "Authorization: Bearer ${bootstrap_token}" | jq -r '.[0].id // empty')"
    if [ -z "${admin_id}" ]; then
      payload="$(jq -n --arg u "${KC_ADMIN_USER}" --arg e "${KC_ADMIN_EMAIL}" '{username: $u, email: $e, emailVerified: true, enabled: true, firstName: $u, lastName: "-"}')"
      http_post_json "${KC_URL}/admin/realms/master/users" "${payload}" "Authorization: Bearer ${bootstrap_token}" >/dev/null
      admin_id="$(http_get "${KC_URL}/admin/realms/master/users?username=${KC_ADMIN_USER}&exact=true" "Authorization: Bearer ${bootstrap_token}" | jq -r '.[0].id // empty')"
      log_info "Created permanent Keycloak admin ${KC_ADMIN_USER}"
    fi

    http_put_json "${KC_URL}/admin/realms/master/users/${admin_id}/reset-password" \
      "$(jq -n --arg p "${KC_ADMIN_PASS}" '{type: "password", value: $p, temporary: false}')" \
      "Authorization: Bearer ${bootstrap_token}" >/dev/null

    admin_role_id="$(http_get "${KC_URL}/admin/realms/master/roles" "Authorization: Bearer ${bootstrap_token}" | jq -r '.[] | select(.name == "admin") | .id // empty')"
    if [ -n "${admin_role_id}" ]; then
      http_post_json "${KC_URL}/admin/realms/master/users/${admin_id}/role-mappings/realm" \
        "[{\"id\": \"${admin_role_id}\", \"name\": \"admin\"}]" \
        "Authorization: Bearer ${bootstrap_token}" >/dev/null || true
    fi

    ADMIN_TOKEN="$(kc_token "${KC_ADMIN_USER}" "${KC_ADMIN_PASS}" || true)"
    [ -n "${ADMIN_TOKEN}" ] || die "Permanent admin cannot authenticate after setup"

    bootstrap_id="$(http_get "${KC_URL}/admin/realms/master/users?username=${KC_BOOTSTRAP_ADMIN_USER}&exact=true" "Authorization: Bearer ${bootstrap_token}" | jq -r '.[0].id // empty')"
    if [ -n "${bootstrap_id}" ]; then
      http_put_json "${KC_URL}/admin/realms/master/users/${bootstrap_id}" '{"enabled": false}' "Authorization: Bearer ${bootstrap_token}" >/dev/null
      log_info "Disabled bootstrap user ${KC_BOOTSTRAP_ADMIN_USER}"
    fi
  else
    log_info "Permanent admin token OK"
  fi

  realms_json="$(http_get "${KC_URL}/admin/realms" "$(kc_admin_header)")"
  realm_exists="$(printf '%s' "${realms_json}" | jq ". // [] | any(.realm == \"${REALM}\")")"
  if [ "${realm_exists}" != "true" ]; then
    http_post_json "${KC_URL}/admin/realms" "$(jq -n --arg r "${REALM}" '{realm: $r, enabled: true}')" "$(kc_admin_header)" >/dev/null
    log_info "Created realm ${REALM}"
  else
    log_info "Realm ${REALM} already exists"
  fi

  client_uuid="$(http_get "${KC_URL}/admin/realms/${REALM}/clients?clientId=grafana" "$(kc_admin_header)" | jq -r '.[0].id // empty')"
  if [ -z "${client_uuid}" ]; then
    payload="$(jq -n \
      --arg login_uri "${GRAFANA_URL}/login/generic_oauth" \
      --arg logout_uri "${GRAFANA_URL}/login" \
      '{clientId: "grafana", name: "Grafana", protocol: "openid-connect", publicClient: false, authorizationServicesEnabled: true, serviceAccountsEnabled: true, standardFlowEnabled: true, directAccessGrantsEnabled: true, redirectUris: [$login_uri], attributes: {"post.logout.redirect.uris": $logout_uri}}')"
    http_post_json "${KC_URL}/admin/realms/${REALM}/clients" "${payload}" "$(kc_admin_header)" >/dev/null
    client_uuid="$(http_get "${KC_URL}/admin/realms/${REALM}/clients?clientId=grafana" "$(kc_admin_header)" | jq -r '.[0].id // empty')"
    log_info "Created grafana client"
  fi
  [ -n "${client_uuid}" ] || die "Client grafana was not created or could not be queried"

  client_json="$(http_get "${KC_URL}/admin/realms/${REALM}/clients/${client_uuid}" "$(kc_admin_header)")"
  payload="$(printf '%s' "${client_json}" | jq -c \
    --arg secret "${GRAFANA_CLIENT_SECRET}" \
    --arg login_uri "${GRAFANA_URL}/login/generic_oauth" \
    --arg logout_uri "${GRAFANA_URL}/login" \
    '.secret = $secret | .redirectUris = [$login_uri] | .attributes = ((.attributes // {}) + {"post.logout.redirect.uris": $logout_uri})')"
  http_put_json "${KC_URL}/admin/realms/${REALM}/clients/${client_uuid}" "${payload}" "$(kc_admin_header)" >/dev/null
  log_info "Synced grafana client"

  existing_mappers="$(http_get "${KC_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models" "$(kc_admin_header)")"
  exists="$(printf '%s' "${existing_mappers}" | jq '. // [] | any(.name == "groups")')"
  if [ "${exists}" != "true" ]; then
    http_post_json "${KC_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models" '{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"claim.name":"groups","full.path":"false","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' "$(kc_admin_header)" >/dev/null
    log_info "Created groups protocol mapper"
  fi

  existing_groups="$(http_get "${KC_URL}/admin/realms/${REALM}/groups" "$(kc_admin_header)")"
  local group
  for group in role-grafanaAdmin role-admin role-editor; do
    exists="$(printf '%s' "${existing_groups}" | jq ". // [] | any(.name == \"${group}\")")"
    if [ "${exists}" != "true" ]; then
      http_post_json "${KC_URL}/admin/realms/${REALM}/groups" "{\"name\": \"${group}\"}" "$(kc_admin_header)" >/dev/null
      log_info "Created group ${group}"
    fi
  done

  log_ok "Keycloak setup complete"
}
