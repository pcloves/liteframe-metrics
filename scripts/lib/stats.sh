#!/usr/bin/env bash

STATS_FORMAT="table"
STATS_OUTPUT=""
STATS_FORMAT_EXPLICIT="no"

stats_parse_output_args() {
  STATS_FORMAT="table"
  STATS_OUTPUT=""
  STATS_FORMAT_EXPLICIT="no"

  while [ $# -gt 0 ]; do
    case "$1" in
      --format)
        [ $# -ge 2 ] || die "--format 需要参数：table 或 csv"
        STATS_FORMAT=$2
        STATS_FORMAT_EXPLICIT="yes"
        case "${STATS_FORMAT}" in
          table|csv) ;;
          *) die "--format 仅支持 table 或 csv" ;;
        esac
        shift 2
        ;;
      --output)
        [ $# -ge 2 ] || die "--output 需要文件路径"
        STATS_OUTPUT=$2
        shift 2
        ;;
      *) return 1 ;;
    esac
  done

  if [ "${STATS_FORMAT_EXPLICIT}" = "no" ]; then
    case "${STATS_OUTPUT}" in
      *.csv) STATS_FORMAT="csv" ;;
    esac
  fi
}

stats_write_output() {
  local content=$1
  if [ -n "${STATS_OUTPUT}" ]; then
    printf '%s\n' "${content}" > "${STATS_OUTPUT}"
    log_ok "已写入 ${STATS_OUTPUT}"
  else
    printf '%s\n' "${content}"
  fi
}

stats_emit_rows() {
  local rows_json=$1 columns_json=$2 header_json=$3 content

  case "${STATS_FORMAT}" in
    csv)
      content="$(jq -r --argjson columns "${columns_json}" --argjson header "${header_json}" '
        ($header | @csv),
        (.[] | . as $row | [$columns[] as $column | ($row[$column] // "" | tostring)] | @csv)
      ' <<< "${rows_json}")"
      ;;
    table)
      content="$(jq -r --argjson columns "${columns_json}" --argjson header "${header_json}" '
        ($header | @tsv),
        (.[] | . as $row | [$columns[] as $column | ($row[$column] // "" | tostring)] | @tsv)
      ' <<< "${rows_json}")"
      if command -v column >/dev/null 2>&1; then
        content="$(printf '%s\n' "${content}" | column -t -s $'\t')"
      fi
      ;;
  esac

  stats_write_output "${content}"
}

stats_join_names() {
  jq -r '[.[].name] | sort | join(";")'
}

stats_role_from_groups_json() {
  local groups_json=$1 role_groups role_count
  role_groups="$(printf '%s' "${groups_json}" | jq -r '[.[].name | select(startswith("role-"))] | sort | join(";")')"
  role_count="$(printf '%s' "${role_groups}" | awk -F';' '{ if ($0 == "") print 0; else print NF } END { if (NR == 0) print 0 }')"
  if [ "${role_count}" -gt 1 ]; then
    printf 'conflict'
  elif [ "${role_groups}" = "role-grafanaAdmin" ]; then
    printf 'grafanaAdmin'
  elif [ "${role_groups}" = "role-admin" ]; then
    printf 'admin'
  elif [ "${role_groups}" = "role-editor" ]; then
    printf 'editor'
  else
    printf 'viewer'
  fi
}

stats_grafana_datasource_exists() {
  local org_id=$1 ds_uid=${2:-vmauth-cluster}
  curl -sS "${GRAFANA_URL}/api/datasources/uid/${ds_uid}" \
    -H "$(grafana_header)" \
    -H "X-Grafana-Org-Id: ${org_id}" | jq -e '.uid == "'"${ds_uid}"'"' >/dev/null 2>&1
}

stats_grafana_datasource_user() {
  local org_id=$1 ds_uid=${2:-vmauth-cluster}
  curl -sS "${GRAFANA_URL}/api/datasources/uid/${ds_uid}" \
    -H "$(grafana_header)" \
    -H "X-Grafana-Org-Id: ${org_id}" | jq -r '.basicAuthUser // empty' 2>/dev/null || true
}

stats_vmauth_user_exists() {
  local username=$1
  [ -f vmauth/auth.yaml ] || return 1
  yq eval -o=json vmauth/auth.yaml | jq -e --arg username "${username}" '.users[]? | select(.username == $username)' >/dev/null 2>&1
}

stats_vmauth_usernames_json() {
  if [ -f vmauth/auth.yaml ]; then
    yq eval -o=json vmauth/auth.yaml | jq '[.users[]?.username | select(. != "vmadmin")]' 2>/dev/null || printf '[]\n'
  else
    printf '[]\n'
  fi
}

stats_kc_list_users() {
  http_get "${KC_URL}/admin/realms/${REALM}/users?max=10000" "$(kc_admin_header)"
}

stats_kc_group_members() {
  local group_id=$1
  http_get "${KC_URL}/admin/realms/${REALM}/groups/${group_id}/members?max=10000" "$(kc_admin_header)"
}

stats_is_org_group_json() {
  local group_json=$1
  printf '%s' "${group_json}" | jq -e '.attributes.metrics_account_id[0]? and .attributes.vmauth_password[0]? and .attributes.grafana_org_id[0]?' >/dev/null 2>&1
}

stats_is_partial_org_group_json() {
  local group_json=$1
  printf '%s' "${group_json}" | jq -e '
    (.attributes.metrics_account_id[0]? or .attributes.vmauth_password[0]? or .attributes.grafana_org_id[0]?)
    and ((.attributes.metrics_account_id[0]? and .attributes.vmauth_password[0]? and .attributes.grafana_org_id[0]?) | not)
  ' >/dev/null 2>&1
}

stats_org_rows() {
  local kc_groups group group_id group_name group_json account_id has_password grafana_org_id grafana_org_name
  local vmauth_entry_exists datasource_exists members_json member_count admin_count editor_count viewer_count member user_id user_groups user_role status rows_file

  kc_groups="$(kc_list_groups_full)"
  rows_file="$(mktemp)"

  while read -r group; do
    group_id="$(printf '%s' "${group}" | jq -r '.id // empty')"
    group_name="$(printf '%s' "${group}" | jq -r '.name // empty')"
    [ -n "${group_id}" ] || continue
    [ -n "${group_name}" ] || continue

    group_json="$(kc_get_group_json "${group_id}")"
    if ! stats_is_org_group_json "${group_json}" && ! stats_is_partial_org_group_json "${group_json}"; then
      continue
    fi

    account_id="$(kc_group_attribute "${group_json}" metrics_account_id)"
    has_password="no"
    [ -n "$(kc_group_attribute "${group_json}" vmauth_password)" ] && has_password="yes"
    grafana_org_id="$(kc_group_attribute "${group_json}" grafana_org_id)"
    grafana_org_name=""
    if [ -n "${grafana_org_id}" ]; then
      grafana_org_name="$(grafana_get_org_name "${grafana_org_id}" || true)"
    fi

    vmauth_entry_exists="no"
    stats_vmauth_user_exists "${group_name}" && vmauth_entry_exists="yes"
    datasource_exists="no"
    if [ -n "${grafana_org_id}" ] && [ -n "${grafana_org_name}" ] && stats_grafana_datasource_exists "${grafana_org_id}"; then
      datasource_exists="yes"
    fi

    members_json="$(stats_kc_group_members "${group_id}")"
    member_count="$(printf '%s' "${members_json}" | jq 'length')"
    admin_count=0
    editor_count=0
    viewer_count=0
    while read -r member; do
      user_id="$(printf '%s' "${member}" | jq -r '.id // empty')"
      [ -n "${user_id}" ] || continue
      user_groups="$(kc_list_user_groups "${user_id}")"
      user_role="$(stats_role_from_groups_json "${user_groups}")"
      case "${user_role}" in
        grafanaAdmin|admin) admin_count=$((admin_count + 1)) ;;
        editor) editor_count=$((editor_count + 1)) ;;
        viewer) viewer_count=$((viewer_count + 1)) ;;
      esac
    done < <(printf '%s' "${members_json}" | jq -c '.[]')

    status="ok"
    if stats_is_partial_org_group_json "${group_json}"; then
      status="incomplete_attributes"
    elif [ -z "${grafana_org_name}" ]; then
      status="missing_grafana_org"
    elif [ "${vmauth_entry_exists}" != "yes" ]; then
      status="missing_vmauth_entry"
    elif [ "${datasource_exists}" != "yes" ]; then
      status="missing_datasource"
    fi

    jq -n \
      --arg group_name "${group_name}" \
      --arg grafana_org_id "${grafana_org_id}" \
      --arg grafana_org_name "${grafana_org_name}" \
      --arg vm_account_id "${account_id}" \
      --arg has_vmauth_password "${has_password}" \
      --arg vmauth_entry_exists "${vmauth_entry_exists}" \
      --arg datasource_exists "${datasource_exists}" \
      --argjson member_count "${member_count}" \
      --argjson admin_count "${admin_count}" \
      --argjson editor_count "${editor_count}" \
      --argjson viewer_count "${viewer_count}" \
      --arg status "${status}" \
      '{group_name:$group_name,grafana_org_id:$grafana_org_id,grafana_org_name:$grafana_org_name,vm_account_id:$vm_account_id,has_vmauth_password:$has_vmauth_password,vmauth_entry_exists:$vmauth_entry_exists,datasource_exists:$datasource_exists,member_count:$member_count,admin_count:$admin_count,editor_count:$editor_count,viewer_count:$viewer_count,status:$status}' >> "${rows_file}"
  done < <(printf '%s' "${kc_groups}" | jq -c '.[]')

  jq -s 'sort_by(.group_name)' "${rows_file}"
  rm -f "${rows_file}"
}

stats_user_rows() {
  local kc_groups users user user_id username email enabled user_groups role org_groups role_groups other_groups org_count grafana_admin status rows_file org_names_json

  kc_groups="$(kc_list_groups_full)"
  org_names_json="$(printf '%s' "${kc_groups}" | jq '[.[] | select(.attributes.metrics_account_id[0]? or .attributes.vmauth_password[0]? or .attributes.grafana_org_id[0]?) | .name]')"
  users="$(stats_kc_list_users)"
  rows_file="$(mktemp)"

  while read -r user; do
    user_id="$(printf '%s' "${user}" | jq -r '.id // empty')"
    [ -n "${user_id}" ] || continue
    username="$(printf '%s' "${user}" | jq -r '.username // empty')"
    email="$(printf '%s' "${user}" | jq -r '.email // empty')"
    enabled="$(printf '%s' "${user}" | jq -r '.enabled // false')"
    user_groups="$(kc_list_user_groups "${user_id}")"
    role="$(stats_role_from_groups_json "${user_groups}")"
    org_groups="$(printf '%s' "${user_groups}" | jq -r --argjson org_names "${org_names_json}" '[.[].name as $name | select($org_names | index($name)) | $name] | sort | join(";")')"
    role_groups="$(printf '%s' "${user_groups}" | jq -r '[.[].name | select(startswith("role-"))] | sort | join(";")')"
    other_groups="$(printf '%s' "${user_groups}" | jq -r --argjson org_names "${org_names_json}" '[.[].name as $name | select((($name | startswith("role-")) | not) and (($org_names | index($name)) | not)) | $name] | sort | join(";")')"
    org_count="$(printf '%s' "${org_groups}" | awk -F';' '{ if ($0 == "") print 0; else print NF } END { if (NR == 0) print 0 }')"
    grafana_admin="no"
    [ "${role}" = "grafanaAdmin" ] && grafana_admin="yes"

    status="ok"
    if [ "${enabled}" != "true" ]; then
      status="disabled"
    elif [ "${role}" = "conflict" ]; then
      status="role_conflict"
    elif [ "${org_count}" -eq 0 ]; then
      status="no_org"
    fi

    jq -n \
      --arg username "${username}" \
      --arg email "${email}" \
      --arg enabled "${enabled}" \
      --arg role "${role}" \
      --arg grafana_admin "${grafana_admin}" \
      --argjson org_count "${org_count}" \
      --arg org_groups "${org_groups}" \
      --arg role_groups "${role_groups}" \
      --arg other_groups "${other_groups}" \
      --arg status "${status}" \
      '{username:$username,email:$email,enabled:$enabled,role:$role,grafana_admin:$grafana_admin,org_count:$org_count,org_groups:$org_groups,role_groups:$role_groups,other_groups:$other_groups,status:$status}' >> "${rows_file}"
  done < <(printf '%s' "${users}" | jq -c '.[]')

  jq -s 'sort_by(.username)' "${rows_file}"
  rm -f "${rows_file}"
}

stats_add_health_issue() {
  local rows_file=$1 scope=$2 object=$3 severity=$4 issue=$5 suggestion=$6
  jq -n \
    --arg scope "${scope}" \
    --arg object "${object}" \
    --arg severity "${severity}" \
    --arg issue "${issue}" \
    --arg suggestion "${suggestion}" \
    '{scope:$scope,object:$object,severity:$severity,issue:$issue,suggestion:$suggestion}' >> "${rows_file}"
}

stats_health_rows() {
  local kc_groups grafana_orgs group group_id group_name group_json account_id vmauth_password grafana_org_id grafana_org_name datasource_user
  local rows_file username users user status bound_ids_json current_group_names_json org_id org_name vmauth_usernames_json
  declare -A seen_org_ids=()

  kc_groups="$(kc_list_groups_full)"
  grafana_orgs="$(http_get "${GRAFANA_URL}/api/orgs" "$(grafana_header)")"
  rows_file="$(mktemp)"

  while read -r group; do
    group_id="$(printf '%s' "${group}" | jq -r '.id // empty')"
    group_name="$(printf '%s' "${group}" | jq -r '.name // empty')"
    [ -n "${group_id}" ] || continue
    [ -n "${group_name}" ] || continue
    group_json="$(kc_get_group_json "${group_id}")"

    if stats_is_partial_org_group_json "${group_json}"; then
      stats_add_health_issue "${rows_file}" org "${group_name}" error "Keycloak group 组织元数据不完整" "补齐 metrics_account_id、vmauth_password、grafana_org_id 后运行 sync all"
      continue
    fi
    stats_is_org_group_json "${group_json}" || continue

    account_id="$(kc_group_attribute "${group_json}" metrics_account_id)"
    vmauth_password="$(kc_group_attribute "${group_json}" vmauth_password)"
    grafana_org_id="$(kc_group_attribute "${group_json}" grafana_org_id)"
    if [ -n "${seen_org_ids[${grafana_org_id}]+set}" ]; then
      stats_add_health_issue "${rows_file}" org "${group_name}" error "grafana_org_id=${grafana_org_id} 被多个 Keycloak group 绑定" "调整重复绑定后运行 sync oauth-mapping"
    fi
    seen_org_ids[${grafana_org_id}]=${group_name}

    grafana_org_name="$(grafana_get_org_name "${grafana_org_id}" || true)"
    if [ -z "${grafana_org_name}" ]; then
      stats_add_health_issue "${rows_file}" org "${group_name}" error "grafana_org_id=${grafana_org_id} 对应的 Grafana org 不存在" "运行 org update 重新绑定到有效 Grafana org"
      continue
    fi
    if ! stats_vmauth_user_exists "${group_name}"; then
      stats_add_health_issue "${rows_file}" org "${group_name}" warn "vmauth/auth.yaml 缺少 ${group_name} 认证条目" "运行 sync tenant-auth ${group_name}"
    fi
    if ! stats_grafana_datasource_exists "${grafana_org_id}"; then
      stats_add_health_issue "${rows_file}" org "${group_name}" warn "Grafana org ${grafana_org_name} 缺少 vmauth-cluster datasource" "运行 sync tenant-auth ${group_name}"
    else
      datasource_user="$(stats_grafana_datasource_user "${grafana_org_id}")"
      if [ "${datasource_user}" != "${group_name}" ]; then
        stats_add_health_issue "${rows_file}" org "${group_name}" warn "vmauth-cluster datasource Basic Auth user 为 ${datasource_user:-empty}" "运行 sync tenant-auth ${group_name}"
      fi
    fi
  done < <(printf '%s' "${kc_groups}" | jq -c '.[]')

  current_group_names_json="$(printf '%s' "${kc_groups}" | jq '[.[] | select(.attributes.metrics_account_id[0]? and .attributes.vmauth_password[0]? and .attributes.grafana_org_id[0]?) | .name]')"
  vmauth_usernames_json="$(stats_vmauth_usernames_json)"
  while read -r username; do
    if ! jq -e --arg name "${username}" 'index($name)' <<< "${current_group_names_json}" >/dev/null; then
      stats_add_health_issue "${rows_file}" auth "${username}" warn "vmauth/auth.yaml 认证条目没有对应的完整 Keycloak 组织 group" "运行 sync tenant-auth --all"
    fi
  done < <(printf '%s' "${vmauth_usernames_json}" | jq -r '.[]')

  bound_ids_json="$(printf '%s' "${kc_groups}" | jq '[.[] | .attributes.grafana_org_id[0]?]')"
  while read -r org; do
    org_id="$(printf '%s' "${org}" | jq -r '.id // empty')"
    org_name="$(printf '%s' "${org}" | jq -r '.name // empty')"
    if ! jq -e --arg id "${org_id}" 'index($id)' <<< "${bound_ids_json}" >/dev/null; then
      stats_add_health_issue "${rows_file}" grafana "${org_name}" warn "Grafana org id=${org_id} 没有 Keycloak group 绑定" "如需保留请忽略，否则清理 Grafana org 或重新绑定"
    fi
  done < <(printf '%s' "${grafana_orgs}" | jq -c '.[]')

  users="$(stats_user_rows)"
  while read -r user; do
    username="$(printf '%s' "${user}" | jq -r '.username')"
    status="$(printf '%s' "${user}" | jq -r '.status')"
    case "${status}" in
      disabled) stats_add_health_issue "${rows_file}" user "${username}" info "Keycloak 用户已禁用" "如需恢复请在 Keycloak 中启用" ;;
      role_conflict) stats_add_health_issue "${rows_file}" user "${username}" warn "用户同时属于多个 role-* group" "运行 user add ${username} <password> <email> <role> 重置角色" ;;
      no_org) stats_add_health_issue "${rows_file}" user "${username}" warn "用户没有组织 group 成员身份" "运行 org user add <org-name> ${username}" ;;
    esac
  done < <(printf '%s' "${users}" | jq -c '.[]')

  if [ ! -s "${rows_file}" ]; then
    stats_add_health_issue "${rows_file}" system stats ok "未发现配置问题" ""
  fi

  jq -s 'sort_by(.severity, .scope, .object)' "${rows_file}"
  rm -f "${rows_file}"
}

stats_show_org() {
  local rows columns header
  rows="$(stats_org_rows)"
  columns='["group_name","grafana_org_id","grafana_org_name","vm_account_id","has_vmauth_password","vmauth_entry_exists","datasource_exists","member_count","admin_count","editor_count","viewer_count","status"]'
  header='["group_name","grafana_org_id","grafana_org_name","vm_account_id","has_vmauth_password","vmauth_entry_exists","datasource_exists","member_count","admin_count","editor_count","viewer_count","status"]'
  stats_emit_rows "${rows}" "${columns}" "${header}"
}

stats_show_user() {
  local rows columns header
  rows="$(stats_user_rows)"
  columns='["username","email","enabled","role","grafana_admin","org_count","org_groups","role_groups","other_groups","status"]'
  header='["username","email","enabled","role","grafana_admin","org_count","org_groups","role_groups","other_groups","status"]'
  stats_emit_rows "${rows}" "${columns}" "${header}"
}

stats_show_health() {
  local rows columns header
  rows="$(stats_health_rows)"
  columns='["scope","object","severity","issue","suggestion"]'
  header='["scope","object","severity","issue","suggestion"]'
  stats_emit_rows "${rows}" "${columns}" "${header}"
}
