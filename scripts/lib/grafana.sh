#!/usr/bin/env bash

grafana_header() {
  printf 'Authorization: Basic %s' "${GF_BASIC_AUTH}"
}

grafana_get_org_name() {
  local org_id=$1
  http_get "${GRAFANA_URL}/api/orgs/${org_id}" "$(grafana_header)" | jq -r '.name // empty'
}

grafana_get_org_id_by_name() {
  local org_name=$1
  http_get "${GRAFANA_URL}/api/orgs" "$(grafana_header)" | jq -r ".[] | select(.name == \"${org_name}\") | .id // empty"
}

grafana_ensure_org() {
  local display_name=$1
  local org_id result
  org_id="$(grafana_get_org_id_by_name "${display_name}")"
  if [ -z "${org_id}" ]; then
    result="$(http_post_json "${GRAFANA_URL}/api/orgs" "$(jq -n --arg name "${display_name}" '{name: $name}')" "$(grafana_header)")"
    org_id="$(printf '%s' "${result}" | jq -r '.orgId // empty')"
    log_info "已创建 Grafana 组织 ${display_name}（id=${org_id}）"
  else
    log_info "Grafana 组织 ${display_name} 已存在（id=${org_id}）"
  fi
  printf '%s' "${org_id}"
}

grafana_rename_org() {
  local org_id=$1 org_name=$2
  http_put_json "${GRAFANA_URL}/api/orgs/${org_id}" \
    "$(jq -n --arg name "${org_name}" '{name: $name}')" \
    "$(grafana_header)" >/dev/null
  log_info "已将 Grafana 组织 id=${org_id} 重命名为 ${org_name}"
}

grafana_switch_org() {
  local org_id=$1
  http_request POST "${GRAFANA_URL}/api/user/using/${org_id}" "" "$(grafana_header)" >/dev/null
}

grafana_user_id() {
  local login=$1
  curl -sS "${GRAFANA_URL}/api/users/lookup?loginOrEmail=${login}" \
    -H "$(grafana_header)" | jq -r '.id // empty' 2>/dev/null || true
}

grafana_ensure_admins_in_org() {
  local org_id=$1 org_name=$2
  local members login user_id is_member
  members="$(http_get "${GRAFANA_URL}/api/orgs/${org_id}/users" "$(grafana_header)")"
  for login in "${GF_SECURITY_ADMIN_USER}" "${KC_ADMIN_EMAIL}"; do
    user_id="$(grafana_user_id "${login}")"
    [ -n "${user_id}" ] || continue
    is_member="$(printf '%s' "${members}" | jq ". // [] | any(.userId == ${user_id})")"
    if [ "${is_member}" = "true" ]; then
      log_info "Grafana 用户 ${login} 已在组织 ${org_name} 中"
    else
      http_post_json "${GRAFANA_URL}/api/orgs/${org_id}/users" \
        "$(jq -n --arg login "${login}" '{loginOrEmail: $login, role: "Admin"}')" \
        "$(grafana_header)" >/dev/null
      log_info "已将 Grafana 用户 ${login} 以管理员角色添加到组织 ${org_name}"
    fi
  done
}

grafana_update_oauth_mapping() {
  local mapping=$1
  local full payload signout_url
  full="$(http_get "${SSO_API}" "$(grafana_header)")"
  signout_url="${KC_URL_EXTERNAL}/realms/${REALM}/protocol/openid-connect/logout?post_logout_redirect_uri=${GRAFANA_URL_EXTERNAL}/login"
  payload="$(printf '%s' "${full}" | jq \
    --arg mapping "${mapping}" \
    --arg secret "${GRAFANA_CLIENT_SECRET}" \
    --arg rolePath "${ROLE_ATTRIBUTE_PATH}" \
    --arg logoutUrl "${signout_url}" \
    '.settings.orgAttributePath = "groups" | .settings.orgMapping = $mapping | .settings.clientSecret = $secret | .settings.roleAttributePath = $rolePath | .settings.allowAssignGrafanaAdmin = true | .settings.signoutRedirectUrl = $logoutUrl')"
  http_put_json "${SSO_API}" "${payload}" "$(grafana_header)" >/dev/null
}

grafana_ensure_basic_datasource() {
  local org_id=$1 org_name=$2 group_name=$3 org_password=$4
  local ds_uid="vmauth-cluster" exists result payload
  grafana_switch_org "${org_id}"
  payload="$(jq -n \
    --arg name "${ds_uid}" \
    --arg uid "${ds_uid}" \
    --arg user "${group_name}" \
    --arg password "${org_password}" \
    '{name: $name, uid: $uid, type: "prometheus", url: "http://vmauth:8427/select/prometheus", access: "proxy", isDefault: true, basicAuth: true, basicAuthUser: $user, secureJsonData: {basicAuthPassword: $password}}')"
  exists="$(curl -sS "${GRAFANA_URL}/api/datasources/uid/${ds_uid}" -H "$(grafana_header)" | jq -r '.uid // empty' 2>/dev/null || true)"
  if [ -n "${exists}" ]; then
    http_put_json "${GRAFANA_URL}/api/datasources/uid/${ds_uid}" "${payload}" "$(grafana_header)" >/dev/null
    log_info "已更新组织 ${org_name} 中的数据源 ${ds_uid}（Basic Auth 用户名/密码）"
  else
    result="$(curl -sS -X POST "${GRAFANA_URL}/api/datasources" -H "$(grafana_header)" -H "Content-Type: application/json" -d "${payload}")"
    if printf '%s' "${result}" | jq -e '.datasource.id' >/dev/null 2>&1; then
      log_info "已在组织 ${org_name} 中创建数据源 ${ds_uid}"
    else
      die "在组织 ${org_name} 中创建数据源失败：$(printf '%s' "${result}" | jq -r '.message // "未知错误"')"
    fi
  fi
  grafana_switch_org 1
}

grafana_sync_oauth_from_keycloak() {
  log_step "同步 Grafana OAuth 映射"
  local orgs_json kc_groups group group_id group_name grafana_org_id org org_id org_name mapping_entries=() mapping
  orgs_json="$(http_get "${GRAFANA_URL}/api/orgs" "$(grafana_header)")"
  kc_groups="$(http_get "${KC_URL}/admin/realms/${REALM}/groups" "$(kc_admin_header)")"

  declare -A kc_org_map=()
  while read -r group; do
    group_id="$(printf '%s' "${group}" | jq -r '.id // empty')"
    group_name="$(printf '%s' "${group}" | jq -r '.name // empty')"
    [ -n "${group_id}" ] || continue
    grafana_org_id="$(http_get "${KC_URL}/admin/realms/${REALM}/groups/${group_id}" "$(kc_admin_header)" | jq -r '.attributes.grafana_org_id[0] // empty')"
    [ -n "${grafana_org_id}" ] || continue
    if [ -n "${kc_org_map[${grafana_org_id}]+set}" ]; then
      die "Grafana 组织 id=${grafana_org_id} 同时绑定到 Keycloak group ${kc_org_map[${grafana_org_id}]} 和 ${group_name}"
    fi
    kc_org_map[${grafana_org_id}]="${group_name}"
  done < <(printf '%s' "${kc_groups}" | jq -c '.[]')

  while read -r org; do
    org_id="$(printf '%s' "${org}" | jq -r '.id')"
    org_name="$(printf '%s' "${org}" | jq -r '.name')"
    group_name="${kc_org_map[${org_id}]:-}"
    if [ -z "${group_name}" ]; then
      log_warn "未找到 Grafana 组织 ${org_name}（id=${org_id}）对应的 Keycloak 组，已跳过"
      continue
    fi
    mapping_entries+=("${group_name}:${org_id}:Viewer")
    grafana_ensure_admins_in_org "${org_id}" "${org_name}"
  done < <(printf '%s' "${orgs_json}" | jq -c '.[]')

  [ ${#mapping_entries[@]} -gt 0 ] || die "未生成 OAuth 映射条目"
  mapping="$(IFS=' '; printf '%s' "${mapping_entries[*]}")"
  grafana_update_oauth_mapping "${mapping}"
  log_ok "Grafana OAuth 映射已同步：${mapping}"
}
