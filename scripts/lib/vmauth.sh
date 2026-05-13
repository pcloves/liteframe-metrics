#!/usr/bin/env bash

vmauth_org_password() {
  local org_name=$1
  printf '%s' "${org_name}:${GRAFANA_CLIENT_SECRET}" | sha256sum | cut -c1-20
}

vmauth_generate_password() {
  dd if=/dev/urandom bs=32 count=1 2>/dev/null | sha256sum | cut -c1-24
}

vmauth_render_template() {
  local template_file=$1 output_file=$2 username=$3 password=$4 account_id=${5:-}
  VMAUTH_USERNAME="${username}" \
  VMAUTH_PASSWORD="${password}" \
  VM_ACCOUNT_ID="${account_id}" \
    yq eval \
      '.username = strenv(VMAUTH_USERNAME) | .password = strenv(VMAUTH_PASSWORD) | (.url_map[].url_prefix[]) |= sub("\\$\\{VM_ACCOUNT_ID\\}", strenv(VM_ACCOUNT_ID))' \
      "${template_file}" > "${output_file}"
}

vmauth_render_entry_json() {
  local template_file=$1 username=$2 password=$3 account_id=${4:-}
  local entry_file
  entry_file="$(mktemp)"
  vmauth_render_template "${template_file}" "${entry_file}" "${username}" "${password}" "${account_id}"
  yq eval -o=json "${entry_file}"
  rm -f "${entry_file}"
}

vmauth_internal_entry_json() {
  local template_file="vmauth/templates/internal-services.yaml"
  [ -f "${template_file}" ] || die "缺少 vmauth 模板：${template_file}"
  vmauth_render_entry_json "${template_file}" "vmadmin" "${VMADMIN_PASS}" ""
}

vmauth_tenant_entry_json() {
  local group_name=$1 account_id=$2 org_password=$3
  local template_file="vmauth/templates/tenant.yaml"
  [ -f "${template_file}" ] || die "缺少 vmauth 模板：${template_file}"
  vmauth_render_entry_json "${template_file}" "${group_name}" "${org_password}" "${account_id}"
}

vmauth_generate_internal_auth() {
  log_step "生成 vmauth 认证配置 auth.yaml"
  local auth_yaml="vmauth/auth.yaml" tmp_dir
  mkdir -p vmauth
  tmp_dir="$(mktemp -d)"
  vmauth_internal_entry_json > "${tmp_dir}/internal.json"
  jq '{users: [.]}' "${tmp_dir}/internal.json" | yq eval -P > "${auth_yaml}"
  rm -rf "${tmp_dir}"
  log_ok "已生成 ${auth_yaml}（合并 1 个认证条目）"
}

vmauth_generate_auth() {
  log_step "生成 vmauth 认证配置 auth.yaml"
  local auth_yaml="vmauth/auth.yaml" tmp_dir kc_groups group group_id group_name group_json account_id org_password count
  mkdir -p vmauth
  tmp_dir="$(mktemp -d)"
  vmauth_internal_entry_json > "${tmp_dir}/entries.jsonl"

  kc_groups="$(kc_list_groups_full)"
  while read -r group; do
    group_id="$(printf '%s' "${group}" | jq -r '.id // empty')"
    group_name="$(printf '%s' "${group}" | jq -r '.name // empty')"
    [ -n "${group_id}" ] || continue
    [ -n "${group_name}" ] || continue

    group_json="$(kc_get_group_json "${group_id}")"
    if printf '%s' "${group_json}" | jq -e '.attributes.metrics_account_id[0]? and .attributes.vmauth_password[0]? and .attributes.grafana_org_id[0]?' >/dev/null 2>&1; then
      account_id="$(kc_group_attribute "${group_json}" metrics_account_id)"
      org_password="$(kc_group_attribute "${group_json}" vmauth_password)"
      vmauth_tenant_entry_json "${group_name}" "${account_id}" "${org_password}" >> "${tmp_dir}/entries.jsonl"
    elif printf '%s' "${group_json}" | jq -e '.attributes.metrics_account_id[0]? or .attributes.vmauth_password[0]? or .attributes.grafana_org_id[0]?' >/dev/null 2>&1; then
      die "Keycloak group ${group_name} 的组织元数据不完整，无法生成 vmauth auth.yaml"
    fi
  done < <(printf '%s' "${kc_groups}" | jq -c '.[]')

  jq -s '{users: .}' "${tmp_dir}/entries.jsonl" | yq eval -P > "${auth_yaml}"
  count="$(jq -s 'length' "${tmp_dir}/entries.jsonl")"
  rm -rf "${tmp_dir}"
  log_ok "已生成 ${auth_yaml}（合并 ${count} 个认证条目）"
}

vmauth_reload() {
  if docker compose exec vmauth kill -HUP 1 >/dev/null 2>&1; then
    log_info "已重新加载 vmauth 配置"
  else
    log_warn "跳过 vmauth 重载，容器可能未运行"
  fi
}
