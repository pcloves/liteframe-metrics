#!/usr/bin/env bash

vmauth_org_password() {
  local org_name=$1
  printf '%s' "${org_name}:${GRAFANA_CLIENT_SECRET}" | sha256sum | cut -c1-20
}

vmauth_generate_password() {
  dd if=/dev/urandom bs=32 count=1 2>/dev/null | sha256sum | cut -c1-24
}

vmauth_write_org_entry() {
  local group_name=$1 account_id=$2 org_password=$3
  local auth_file="vmauth/auth.d/${group_name}.yaml"
  mkdir -p vmauth/auth.d
  jq -n \
    --arg username "${group_name}" \
    --arg password "${org_password}" \
    --argjson account_id "${account_id}" \
    '{username: $username, password: $password, url_map: [{src_paths: ["/select/.*"], drop_src_path_prefix_parts: 1, url_prefix: ["http://vmselect-1:8481/select/\($account_id)/prometheus/", "http://vmselect-2:8481/select/\($account_id)/prometheus/"]}, {src_paths: ["/api/v1/import/prometheus"], url_prefix: ["http://vminsert-1:8480/insert/\($account_id)/prometheus/", "http://vminsert-2:8480/insert/\($account_id)/prometheus/"]}]}' | yq -P > "${auth_file}"
  log_info "已写入 ${auth_file}"
}

vmauth_generate_auth() {
  log_step "生成 vmauth 认证配置 auth.yaml"
  local auth_d="vmauth/auth.d" auth_yaml="vmauth/auth.yaml" tmp_dir first count file
  mkdir -p "${auth_d}" vmauth
  tmp_dir="$(mktemp -d)"

  first=true
  while IFS= read -r file; do
    sed -e "s/\${HOST_IP}/${HOST_IP}/g" \
        -e "s/\${KC_PORT}/${KC_PORT}/g" \
        -e "s/\${KC_REALM}/${KC_REALM}/g" \
        -e "s/\${VMADMIN_PASS}/${VMADMIN_PASS}/g" \
        "${file}" > "${tmp_dir}/entry.yaml"
    yq eval -o=json "${tmp_dir}/entry.yaml" > "${tmp_dir}/entry.json"
    if [ "${first}" = true ]; then
      jq '{"users": [.]}' "${tmp_dir}/entry.json" > "${tmp_dir}/result.json"
      first=false
    else
      jq -s '.[0].users += [.[1]] | .[0]' "${tmp_dir}/result.json" "${tmp_dir}/entry.json" > "${tmp_dir}/result2.json"
      mv "${tmp_dir}/result2.json" "${tmp_dir}/result.json"
    fi
  done < <(find "${auth_d}" -maxdepth 1 -name '*.yaml' -print | sort)

  if [ "${first}" = false ]; then
    yq eval -P "${tmp_dir}/result.json" > "${auth_yaml}"
    count="$(jq '.users | length' "${tmp_dir}/result.json")"
  else
    echo 'users: []' > "${auth_yaml}"
    count=0
  fi
  rm -rf "${tmp_dir}"
  log_ok "已生成 ${auth_yaml}（合并 ${count} 个认证条目）"
}

vmauth_clean_tenant_entries() {
  mkdir -p vmauth/auth.d
  find vmauth/auth.d -maxdepth 1 -name '[!_]*.yaml' -delete
  log_info "已清理生成的租户认证条目"
}

vmauth_reload() {
  if docker compose exec vmauth kill -HUP 1 >/dev/null 2>&1; then
    log_info "已重新加载 vmauth 配置"
  else
    log_warn "跳过 vmauth 重载，容器可能未运行"
  fi
}
