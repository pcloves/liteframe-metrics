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
  [ -n "${ADMIN_TOKEN}" ] || die "无法验证 Keycloak 管理员 ${KC_ADMIN_USER}"
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

kc_list_groups_full() {
  http_get "${KC_URL}/admin/realms/${REALM}/groups?briefRepresentation=false" "$(kc_admin_header)"
}

kc_get_group_json() {
  local group_id=$1
  http_get "${KC_URL}/admin/realms/${REALM}/groups/${group_id}" "$(kc_admin_header)"
}

kc_group_attribute() {
  local group_json=$1 attr=$2
  printf '%s' "${group_json}" | jq -r --arg attr "${attr}" '.attributes[$attr][0] // empty'
}

kc_find_group_by_account_id() {
  local account_id=$1 exclude_group_name=${2:-}
  kc_list_groups_full | jq -r \
    --arg account_id "${account_id}" \
    --arg exclude_group_name "${exclude_group_name}" \
    '[.[] | select(.name != $exclude_group_name) | select((.attributes.metrics_account_id // []) | index($account_id)) | .name][0] // empty'
}

kc_find_group_by_grafana_org_id() {
  local grafana_org_id=$1 exclude_group_name=${2:-}
  kc_list_groups_full | jq -r \
    --arg grafana_org_id "${grafana_org_id}" \
    --arg exclude_group_name "${exclude_group_name}" \
    '[.[] | select(.name != $exclude_group_name) | select((.attributes.grafana_org_id // []) | index($grafana_org_id)) | .name][0] // empty'
}

kc_next_account_id() {
  kc_list_groups_full | jq -r '[.[] | .attributes.metrics_account_id[0] // empty | select(test("^[0-9]+$")) | tonumber] | if length == 0 then 1 else (max + 1) end'
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
    log_info "已创建 Keycloak 组 ${group_name}"
  else
    log_info "Keycloak 组 ${group_name} 已存在"
  fi

  if [ -n "${account_id}" ]; then
    group_json="$(http_get "${KC_URL}/admin/realms/${REALM}/groups/${group_id}" "$(kc_admin_header)")"
    payload="$(printf '%s' "${group_json}" | jq --arg aid "${account_id}" '.attributes = ((.attributes // {}) + {metrics_account_id: [$aid]})')"
    http_put_json "${KC_URL}/admin/realms/${REALM}/groups/${group_id}" "${payload}" "$(kc_admin_header)" >/dev/null
    log_info "已设置组 ${group_name} 的 metrics_account_id=${account_id}"
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
  local user_id user_json payload
  user_id="$(kc_get_user_id "${username}")"
  if [ -z "${user_id}" ]; then
    payload="$(jq -n --arg u "${username}" --arg e "${email}" --arg p "${password}" \
      '{username: $u, email: $e, emailVerified: true, enabled: true, firstName: $u, lastName: "-", credentials: [{type: "password", value: $p, temporary: false}]}')"
    http_post_json "${KC_URL}/admin/realms/${REALM}/users" "${payload}" "$(kc_admin_header)" >/dev/null
    user_id="$(kc_get_user_id "${username}")"
    log_info "已创建 Keycloak 用户 ${username}"
  else
    log_info "Keycloak 用户 ${username} 已存在"
    user_json="$(http_get "${KC_URL}/admin/realms/${REALM}/users/${user_id}" "$(kc_admin_header)")"
    payload="$(printf '%s' "${user_json}" | jq --arg e "${email}" '.email = $e | .emailVerified = true | .enabled = true')"
    http_put_json "${KC_URL}/admin/realms/${REALM}/users/${user_id}" "${payload}" "$(kc_admin_header)" >/dev/null
    http_put_json "${KC_URL}/admin/realms/${REALM}/users/${user_id}/reset-password" \
      "$(jq -n --arg p "${password}" '{type: "password", value: $p, temporary: false}')" \
      "$(kc_admin_header)" >/dev/null
    log_info "已更新 Keycloak 用户 ${username}"
  fi
  printf '%s' "${user_id}"
}

kc_assign_user_group() {
  local user_id=$1 group_id=$2 label=$3
  http_request PUT "${KC_URL}/admin/realms/${REALM}/users/${user_id}/groups/${group_id}" "" "$(kc_admin_header)" >/dev/null
  log_info "已将用户分配到 ${label}"
}

kc_remove_user_group() {
  local user_id=$1 group_id=$2 label=$3
  http_delete "${KC_URL}/admin/realms/${REALM}/users/${user_id}/groups/${group_id}" "$(kc_admin_header)" >/dev/null
  log_info "已将用户从 ${label} 移除"
}

kc_list_user_groups() {
  local user_id=$1
  http_get "${KC_URL}/admin/realms/${REALM}/users/${user_id}/groups" "$(kc_admin_header)"
}

kc_disable_user() {
  local user_id=$1 username=$2
  local user_json payload
  user_json="$(http_get "${KC_URL}/admin/realms/${REALM}/users/${user_id}" "$(kc_admin_header)")"
  payload="$(printf '%s' "${user_json}" | jq '.enabled = false')"
  http_put_json "${KC_URL}/admin/realms/${REALM}/users/${user_id}" "${payload}" "$(kc_admin_header)" >/dev/null
  log_info "已禁用 Keycloak 用户 ${username}"
}

kc_delete_user() {
  local user_id=$1 username=$2
  http_delete "${KC_URL}/admin/realms/${REALM}/users/${user_id}" "$(kc_admin_header)" >/dev/null
  log_info "已删除 Keycloak 用户 ${username}"
}

kc_setup_base() {
  log_step "设置 Keycloak"
  local bootstrap_token admin_id admin_role_id bootstrap_id realms_json realm_exists realm_json client_uuid client_json payload existing_mappers existing_groups exists

  ADMIN_TOKEN="$(kc_token "${KC_ADMIN_USER}" "${KC_ADMIN_PASS}" || true)"
  if [ -z "${ADMIN_TOKEN}" ]; then
    log_info "正式管理员不可用，使用引导管理员"
    bootstrap_token="$(kc_token "${KC_BOOTSTRAP_ADMIN_USER}" "${KC_BOOTSTRAP_ADMIN_PASS}" || true)"
    [ -n "${bootstrap_token}" ] || die "引导用户 ${KC_BOOTSTRAP_ADMIN_USER} 无法通过验证"

    admin_id="$(http_get "${KC_URL}/admin/realms/master/users?username=${KC_ADMIN_USER}&exact=true" "Authorization: Bearer ${bootstrap_token}" | jq -r '.[0].id // empty')"
    if [ -z "${admin_id}" ]; then
      payload="$(jq -n --arg u "${KC_ADMIN_USER}" --arg e "${KC_ADMIN_EMAIL}" '{username: $u, email: $e, emailVerified: true, enabled: true, firstName: $u, lastName: "-"}')"
      http_post_json "${KC_URL}/admin/realms/master/users" "${payload}" "Authorization: Bearer ${bootstrap_token}" >/dev/null
      admin_id="$(http_get "${KC_URL}/admin/realms/master/users?username=${KC_ADMIN_USER}&exact=true" "Authorization: Bearer ${bootstrap_token}" | jq -r '.[0].id // empty')"
      log_info "已创建正式 Keycloak 管理员 ${KC_ADMIN_USER}"
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
    [ -n "${ADMIN_TOKEN}" ] || die "正式管理员在设置后无法通过身份验证"

    bootstrap_id="$(http_get "${KC_URL}/admin/realms/master/users?username=${KC_BOOTSTRAP_ADMIN_USER}&exact=true" "Authorization: Bearer ${bootstrap_token}" | jq -r '.[0].id // empty')"
    if [ -n "${bootstrap_id}" ]; then
      http_put_json "${KC_URL}/admin/realms/master/users/${bootstrap_id}" '{"enabled": false}' "Authorization: Bearer ${bootstrap_token}" >/dev/null
      log_info "已禁用引导用户 ${KC_BOOTSTRAP_ADMIN_USER}"
    fi
  else
    log_info "正式管理员令牌正常"
  fi

  realms_json="$(http_get "${KC_URL}/admin/realms" "$(kc_admin_header)")"
  realm_exists="$(printf '%s' "${realms_json}" | jq ". // [] | any(.realm == \"${REALM}\")")"
  if [ "${realm_exists}" != "true" ]; then
    http_post_json "${KC_URL}/admin/realms" "$(jq -n --arg r "${REALM}" --arg ssl_required "${KEYCLOAK_SSL_REQUIRED}" '{realm: $r, enabled: true, sslRequired: $ssl_required}')" "$(kc_admin_header)" >/dev/null
    log_info "已创建 realm ${REALM}"
  else
    log_info "Realm ${REALM} 已存在"
  fi

  realm_json="$(http_get "${KC_URL}/admin/realms/${REALM}" "$(kc_admin_header)")"
  payload="$(printf '%s' "${realm_json}" | jq -c --arg ssl_required "${KEYCLOAK_SSL_REQUIRED}" '.sslRequired = $ssl_required')"
  http_put_json "${KC_URL}/admin/realms/${REALM}" "${payload}" "$(kc_admin_header)" >/dev/null
  log_info "已同步 realm ${REALM} 的 sslRequired=${KEYCLOAK_SSL_REQUIRED}"

  client_uuid="$(http_get "${KC_URL}/admin/realms/${REALM}/clients?clientId=grafana" "$(kc_admin_header)" | jq -r '.[0].id // empty')"
  if [ -z "${client_uuid}" ]; then
    payload="$(jq -n \
      --arg login_uri "${GRAFANA_URL_EXTERNAL}/login/generic_oauth" \
      --arg logout_uri "${GRAFANA_URL_EXTERNAL}/login" \
      '{clientId: "grafana", name: "Grafana", protocol: "openid-connect", publicClient: false, authorizationServicesEnabled: true, serviceAccountsEnabled: true, standardFlowEnabled: true, directAccessGrantsEnabled: true, redirectUris: [$login_uri], attributes: {"post.logout.redirect.uris": $logout_uri}}')"
    http_post_json "${KC_URL}/admin/realms/${REALM}/clients" "${payload}" "$(kc_admin_header)" >/dev/null
    client_uuid="$(http_get "${KC_URL}/admin/realms/${REALM}/clients?clientId=grafana" "$(kc_admin_header)" | jq -r '.[0].id // empty')"
    log_info "已创建 Grafana 客户端"
  fi
  [ -n "${client_uuid}" ] || die "客户端 grafana 未创建或无法查询"

  client_json="$(http_get "${KC_URL}/admin/realms/${REALM}/clients/${client_uuid}" "$(kc_admin_header)")"
  payload="$(printf '%s' "${client_json}" | jq -c \
    --arg secret "${GRAFANA_CLIENT_SECRET}" \
    --arg login_uri "${GRAFANA_URL_EXTERNAL}/login/generic_oauth" \
    --arg logout_uri "${GRAFANA_URL_EXTERNAL}/login" \
    '.secret = $secret | .redirectUris = [$login_uri] | .attributes = ((.attributes // {}) + {"post.logout.redirect.uris": $logout_uri})')"
  http_put_json "${KC_URL}/admin/realms/${REALM}/clients/${client_uuid}" "${payload}" "$(kc_admin_header)" >/dev/null
  log_info "已同步 Grafana 客户端"

  existing_mappers="$(http_get "${KC_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models" "$(kc_admin_header)")"
  exists="$(printf '%s' "${existing_mappers}" | jq '. // [] | any(.name == "groups")')"
  if [ "${exists}" != "true" ]; then
    http_post_json "${KC_URL}/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models" '{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"claim.name":"groups","full.path":"false","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' "$(kc_admin_header)" >/dev/null
    log_info "已创建 groups 协议映射器"
  fi

  existing_groups="$(http_get "${KC_URL}/admin/realms/${REALM}/groups" "$(kc_admin_header)")"
  local group
  for group in role-grafanaAdmin role-admin role-editor; do
    exists="$(printf '%s' "${existing_groups}" | jq ". // [] | any(.name == \"${group}\")")"
    if [ "${exists}" != "true" ]; then
      http_post_json "${KC_URL}/admin/realms/${REALM}/groups" "{\"name\": \"${group}\"}" "$(kc_admin_header)" >/dev/null
      log_info "已创建组 ${group}"
    fi
  done

  log_ok "Keycloak 设置完成"
}
