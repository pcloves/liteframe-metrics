#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/env.sh
source "${SCRIPT_DIR}/lib/env.sh"
# shellcheck source=lib/http.sh
source "${SCRIPT_DIR}/lib/http.sh"
# shellcheck source=lib/keycloak.sh
source "${SCRIPT_DIR}/lib/keycloak.sh"
# shellcheck source=lib/grafana.sh
source "${SCRIPT_DIR}/lib/grafana.sh"
# shellcheck source=lib/vmauth.sh
source "${SCRIPT_DIR}/lib/vmauth.sh"
# shellcheck source=lib/dashboards.sh
source "${SCRIPT_DIR}/lib/dashboards.sh"
# shellcheck source=lib/docker.sh
source "${SCRIPT_DIR}/lib/docker.sh"

log_init

usage() {
  cat <<'EOF'
用法：
  bash scripts/manage.sh init
  bash scripts/manage.sh kc setup
  bash scripts/manage.sh org add --main
  bash scripts/manage.sh org add <org-name> <grafana-org-name> [--vm-account-id <id>] [--vmauth-password <password>] [--allow-duplicate-account-id] [--use-existing-grafana-org]
  bash scripts/manage.sh org update <org-name> [--grafana-org-name <name>] [--vm-account-id <id>] [--vmauth-password <password>] [--rotate-password] [--allow-duplicate-account-id] [--use-existing-grafana-org]
  bash scripts/manage.sh org user add <org-name> <username>
  bash scripts/manage.sh org user delete <org-name> <username>
  bash scripts/manage.sh user add <username> <password> <email> <role>
  bash scripts/manage.sh user delete <username> [--force]
  bash scripts/manage.sh user groups <username>
  bash scripts/manage.sh oauth sync
  bash scripts/manage.sh dashboard import <org-name> [--grafana-name <name>] [--overwrite]
  bash scripts/manage.sh dashboard import --main [--overwrite]
  bash scripts/manage.sh dashboard import --all-tenants [--overwrite]
  bash scripts/manage.sh auth generate

角色：
  grafanaAdmin | admin | editor | viewer

说明：
  user add 为幂等操作：创建/更新用户，并替换已有的 Grafana 角色组。
  org user add/delete 管理 Keycloak group 成员身份，与用户角色分开管理。
  <org-name> 指 Keycloak group 名称，不是 Grafana 组织名称。
  <grafana-org-name> 默认不可复用；如确认绑定到未被 Keycloak group 使用的已有 Grafana 组织，请追加 --use-existing-grafana-org。
  --vm-account-id 未指定时自动分配，默认不可重复；如确认复用，请追加 --allow-duplicate-account-id。
  --vmauth-password 未指定时自动生成，并存入 Keycloak group attributes。
  org update 可修改租户的 Grafana 组织、vm-account-id 或 vmauth 密码；--rotate-password 会自动生成新密码。
EOF
}

load_runtime() {
  load_env
}

cmd_auth_generate() {
  load_runtime
  vmauth_generate_auth
}

cmd_kc_setup() {
  load_runtime
  require_bootstrap_env
  kc_setup_base
}

cmd_user_add() {
  [ $# -eq 4 ] || { usage; exit 1; }
  local username=$1 password=$2 email=$3 role=$4
  local role_group_name role_group_id user_id existing_role_group existing_role_group_id

  case "${role}" in
    grafanaAdmin|admin|editor|viewer) ;;
    *) die "角色必须是 grafanaAdmin、admin、editor 或 viewer" ;;
  esac

  load_runtime
  kc_get_admin_token

  role_group_name=""
  case "${role}" in
    grafanaAdmin) role_group_name="role-grafanaAdmin" ;;
    admin) role_group_name="role-admin" ;;
    editor) role_group_name="role-editor" ;;
  esac

  role_group_id=""
  if [ -n "${role_group_name}" ]; then
    role_group_id="$(kc_get_group_id "${role_group_name}")"
    [ -n "${role_group_id}" ] || log_warn "角色组 ${role_group_name} 未找到，跳过角色分配"
  fi

  log_step "添加/更新用户 ${username}"
  user_id="$(kc_ensure_user "${username}" "${password}" "${email}")"
  log_step "设置 ${username} 的 Grafana 角色为 ${role}"
  for existing_role_group in role-grafanaAdmin role-admin role-editor; do
    existing_role_group_id="$(kc_get_group_id "${existing_role_group}")"
    [ -n "${existing_role_group_id}" ] || continue
    kc_remove_user_group "${user_id}" "${existing_role_group_id}" "${existing_role_group}" || true
  done
  if [ -n "${role_group_id}" ]; then
    kc_assign_user_group "${user_id}" "${role_group_id}" "${role_group_name}"
  else
    log_info "用户角色为 viewer，未分配 role-* 组"
  fi
  log_ok "用户 ${username} 已就绪"
}

cmd_org_user_add() {
  [ $# -eq 2 ] || { usage; exit 1; }
  local org_name=$1 username=$2 group_name group_id user_id

  load_runtime
  kc_get_admin_token

  group_name="$(kc_group_name_for_org "${org_name}")"
  group_id="$(kc_get_group_id "${group_name}")"
  [ -n "${group_id}" ] || die "组 ${group_name} 未找到。请运行：bash scripts/manage.sh org add ${org_name} <grafana-org-name>"
  user_id="$(kc_get_user_id "${username}")"
  [ -n "${user_id}" ] || die "用户 ${username} 未找到。请运行：bash scripts/manage.sh user add ${username} <password> <email> <role>"

  log_step "将用户 ${username} 添加到 Keycloak group ${group_name}"
  kc_assign_user_group "${user_id}" "${group_id}" "${group_name}"
  log_ok "用户 ${username} 已在 Keycloak group ${group_name} 中"
}

cmd_org_user_delete() {
  [ $# -eq 2 ] || { usage; exit 1; }
  local org_name=$1 username=$2 group_name group_id user_id

  load_runtime
  kc_get_admin_token

  group_name="$(kc_group_name_for_org "${org_name}")"
  group_id="$(kc_get_group_id "${group_name}")"
  [ -n "${group_id}" ] || die "组 ${group_name} 未找到"
  user_id="$(kc_get_user_id "${username}")"
  [ -n "${user_id}" ] || die "用户 ${username} 未找到"

  log_step "将用户 ${username} 从 Keycloak group ${group_name} 移除"
  kc_remove_user_group "${user_id}" "${group_id}" "${group_name}" || true
  log_ok "用户 ${username} 已从 Keycloak group ${group_name} 移除"
}

cmd_user_groups() {
  [ $# -eq 1 ] || { usage; exit 1; }
  local username=$1 user_id

  load_runtime
  kc_get_admin_token
  user_id="$(kc_get_user_id "${username}")"
  [ -n "${user_id}" ] || die "用户 ${username} 未找到"

  kc_list_user_groups "${user_id}" | jq -r '.[].name' | sort
}

cmd_user_delete() {
  [ $# -ge 1 ] || { usage; exit 1; }
  local username=$1 force=false user_id
  if [ "${2:-}" = "--force" ]; then
    force=true
  elif [ $# -gt 1 ]; then
    usage
    exit 1
  fi

  load_runtime
  kc_get_admin_token
  user_id="$(kc_get_user_id "${username}")"
  [ -n "${user_id}" ] || die "用户 ${username} 未找到"

  if [ "${force}" = true ]; then
    log_step "删除用户 ${username}"
    kc_delete_user "${user_id}" "${username}"
  else
    log_step "禁用用户 ${username}"
    kc_disable_user "${user_id}" "${username}"
    log_info "使用 --force 参数可永久删除"
  fi
  log_ok "用户 ${username} 操作完成"
}

cmd_oauth_sync() {
  load_runtime
  kc_get_admin_token
  grafana_sync_oauth_from_keycloak
}

cmd_dashboard_import() {
  [ $# -ge 1 ] || { usage; exit 1; }
  local is_main=false all_tenants=false org_name grafana_org_name overwrite=false group_name

  if [ "$1" = "--main" ]; then
    [ $# -le 2 ] || { usage; exit 1; }
    is_main=true
    org_name="main"
    shift
  elif [ "$1" = "--all-tenants" ]; then
    [ $# -le 2 ] || { usage; exit 1; }
    all_tenants=true
    shift
  else
    org_name=$1
    shift
  fi

  load_runtime
  if [ "${is_main}" = true ]; then
    grafana_org_name="$(grafana_get_org_name 1)"
  else
    grafana_org_name="${org_name}"
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --grafana-name)
        [ $# -ge 2 ] || die "--grafana-name 参数需要提供值"
        grafana_org_name=$2
        shift 2
        ;;
      --overwrite)
        overwrite=true
        shift
        ;;
      *) usage; exit 1 ;;
    esac
  done

  if [ "${all_tenants}" = true ] && [ -n "${grafana_org_name}" ]; then
    die "--grafana-name 不能与 --all-tenants 同时使用"
  fi

  if [ "${all_tenants}" = true ]; then
    kc_get_admin_token
    dashboard_import_all_tenants "${overwrite}"
    return
  fi

  group_name="$(kc_group_name_for_org "${org_name}")"
  if [ "${is_main}" = true ]; then
    dashboards_import platform "${group_name}" "${grafana_org_name}" "${overwrite}"
  else
    dashboards_import tenants "${group_name}" "${grafana_org_name}" "${overwrite}"
  fi
}

dashboard_import_all_tenants() {
  local overwrite=$1 kc_groups group group_id group_name group_json grafana_org_id grafana_org_name count=0
  kc_groups="$(http_get "${KC_URL}/admin/realms/${REALM}/groups" "$(kc_admin_header)")"

  while read -r group; do
    group_id="$(printf '%s' "${group}" | jq -r '.id // empty')"
    group_name="$(printf '%s' "${group}" | jq -r '.name // empty')"
    [ -n "${group_id}" ] || continue
    [ -n "${group_name}" ] || continue
    [ "${group_name}" != "org-main" ] || continue

    group_json="$(http_get "${KC_URL}/admin/realms/${REALM}/groups/${group_id}" "$(kc_admin_header)")"
    grafana_org_id="$(printf '%s' "${group_json}" | jq -r '.attributes.grafana_org_id[0] // empty')"
    [ -n "${grafana_org_id}" ] || continue
    grafana_org_name="$(grafana_get_org_name "${grafana_org_id}")"
    [ -n "${grafana_org_name}" ] || { log_warn "Grafana 组织 ID ${grafana_org_id} 未找到，跳过 ${group_name}"; continue; }

    dashboards_import tenants "${group_name}" "${grafana_org_name}" "${overwrite}"
    count=$((count + 1))
  done < <(printf '%s' "${kc_groups}" | jq -c '.[]')

  [ "${count}" -gt 0 ] || log_warn "未找到租户组织用于导入仪表盘"
}

cmd_org_add() {
  [ $# -ge 1 ] || { usage; exit 1; }
  local is_main=false allow_duplicate_account_id=false use_existing_grafana_org=false
  local org_name account_id="" account_id_arg="" grafana_org_name group_name group_id group_json="" org_id="" org_password="" vmauth_password_arg=""
  local account_id_owner="" grafana_org_owner="" existing_account_id="" existing_password="" existing_grafana_org_id="" existing_grafana_org_name="" existing_org_id=""

  if [ "$1" = "--main" ]; then
    [ $# -eq 1 ] || { usage; exit 1; }
    is_main=true
    org_name="main"
    account_id_arg="0"
  elif [ $# -ge 2 ]; then
    org_name=$1
    grafana_org_name=$2
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --vm-account-id)
          [ $# -ge 2 ] || die "--vm-account-id 参数需要提供值"
          account_id_arg=$2
          require_number vm-account-id "${account_id_arg}"
          shift 2
          ;;
        --vmauth-password)
          [ $# -ge 2 ] || die "--vmauth-password 参数需要提供值"
          vmauth_password_arg=$2
          shift 2
          ;;
        --allow-duplicate-account-id)
          allow_duplicate_account_id=true
          shift
          ;;
        --use-existing-grafana-org)
          use_existing_grafana_org=true
          shift
          ;;
        *) usage; exit 1 ;;
      esac
    done
  else
    usage
    exit 1
  fi

  load_runtime
  kc_get_admin_token
  group_name="$(kc_group_name_for_org "${org_name}")"
  group_id="$(kc_get_group_id "${group_name}")"
  if [ -n "${group_id}" ]; then
    group_json="$(kc_get_group_json "${group_id}")"
    existing_account_id="$(kc_group_attribute "${group_json}" metrics_account_id)"
    existing_password="$(kc_group_attribute "${group_json}" vmauth_password)"
    existing_grafana_org_id="$(kc_group_attribute "${group_json}" grafana_org_id)"
  fi

  if [ -n "${existing_account_id}" ]; then
    if [ -n "${account_id_arg}" ] && [ "${account_id_arg}" != "${existing_account_id}" ]; then
      die "Keycloak group ${group_name} 已绑定 vm-account-id ${existing_account_id}，如需修改请使用 org update。"
    fi
    account_id="${existing_account_id}"
  elif [ -n "${account_id_arg}" ]; then
    account_id="${account_id_arg}"
  elif [ "${is_main}" = true ]; then
    account_id="0"
  else
    account_id="$(kc_next_account_id)"
    log_info "自动分配 vm-account-id=${account_id}"
  fi

  if [ "${is_main}" != true ]; then
    account_id_owner="$(kc_find_group_by_account_id "${account_id}" "${group_name}")"
    if [ -n "${account_id_owner}" ]; then
      if [ "${allow_duplicate_account_id}" = true ]; then
        log_warn "account-id ${account_id} 已被 Keycloak group ${account_id_owner} 使用，本次按参数要求继续复用"
      else
        die "account-id ${account_id} 已被 Keycloak group ${account_id_owner} 使用。如确认复用，请追加 --allow-duplicate-account-id。"
      fi
    fi
  fi

  if [ "${is_main}" = true ]; then
    org_id=1
    grafana_org_name="$(grafana_get_org_name "${org_id}")"
    [ -n "${grafana_org_name}" ] || grafana_org_name="Main Org."
    log_info "使用内置 Grafana 组织 ${grafana_org_name}（id=${org_id}）"
  elif [ -n "${existing_grafana_org_id}" ]; then
    existing_grafana_org_name="$(grafana_get_org_name "${existing_grafana_org_id}")"
    [ -n "${existing_grafana_org_name}" ] || die "Keycloak group ${group_name} 绑定的 Grafana 组织 id=${existing_grafana_org_id} 未找到"
    [ "${existing_grafana_org_name}" = "${grafana_org_name}" ] || die "Keycloak group ${group_name} 已绑定 Grafana 组织 ${existing_grafana_org_name}，如需修改请使用 org update。"
    grafana_org_owner="$(kc_find_group_by_grafana_org_id "${existing_grafana_org_id}" "${group_name}")"
    [ -z "${grafana_org_owner}" ] || die "Grafana 组织 ${grafana_org_name}（id=${existing_grafana_org_id}）已被 Keycloak group ${grafana_org_owner} 绑定。"
    org_id="${existing_grafana_org_id}"
    log_info "沿用已绑定 Grafana 组织 ${grafana_org_name}（id=${org_id}）"
  else
    existing_org_id="$(grafana_get_org_id_by_name "${grafana_org_name}")"
    if [ -n "${existing_org_id}" ]; then
      grafana_org_owner="$(kc_find_group_by_grafana_org_id "${existing_org_id}" "${group_name}")"
      [ -z "${grafana_org_owner}" ] || die "Grafana 组织 ${grafana_org_name}（id=${existing_org_id}）已被 Keycloak group ${grafana_org_owner} 绑定。"
      [ "${use_existing_grafana_org}" = true ] || die "Grafana 组织 ${grafana_org_name} 已存在。如确认绑定到该组织，请追加 --use-existing-grafana-org。"
      org_id="${existing_org_id}"
      log_warn "绑定到已有 Grafana 组织 ${grafana_org_name}（id=${org_id}）"
    else
      org_id="$(grafana_ensure_org "${grafana_org_name}")"
    fi
  fi

  if [ -n "${existing_password}" ]; then
    if [ -n "${vmauth_password_arg}" ] && [ "${vmauth_password_arg}" != "${existing_password}" ]; then
      die "Keycloak group ${group_name} 已设置 vmauth password，如需修改请使用 org update。"
    fi
    org_password="${existing_password}"
  elif [ -n "${vmauth_password_arg}" ]; then
    org_password="${vmauth_password_arg}"
  elif [ -n "${group_id}" ]; then
    org_password="$(vmauth_org_password "${org_name}")"
    log_info "沿用 ${group_name} 的旧版 vmauth password，并写入 Keycloak group attributes"
  else
    org_password="$(vmauth_generate_password)"
    log_info "已自动生成 ${group_name} 的 vmauth password"
  fi

  log_step "确保 Keycloak group ${group_name} 存在"
  group_id="$(kc_ensure_group "${group_name}")"

  kc_set_group_attribute "${group_id}" metrics_account_id "${account_id}"
  log_info "已设置组 ${group_name} 的 metrics_account_id=${account_id}"
  kc_set_group_attribute "${group_id}" vmauth_password "${org_password}"
  log_info "已设置组 ${group_name} 的 vmauth_password"
  kc_set_group_attribute "${group_id}" grafana_org_id "${org_id}"
  log_info "已设置组 ${group_name} 的 grafana_org_id=${org_id}"

  local admin_user_id
  admin_user_id="$(kc_get_user_id "${KC_ADMIN_USER}")"
  if [ -n "${admin_user_id}" ]; then
    kc_assign_user_group "${admin_user_id}" "${group_id}" "${group_name}"
  fi

  grafana_ensure_admins_in_org "${org_id}" "${grafana_org_name}"

  vmauth_write_org_entry "${group_name}" "${account_id}" "${org_password}"
  vmauth_generate_auth
  vmauth_reload

  grafana_ensure_basic_datasource "${org_id}" "${grafana_org_name}" "${group_name}" "${org_password}"
  if [ "${is_main}" = true ]; then
    dashboards_import platform "${group_name}" "${grafana_org_name}" false
  else
    dashboards_import tenants "${group_name}" "${grafana_org_name}" false
  fi
  grafana_sync_oauth_from_keycloak
  log_ok "组织 ${grafana_org_name}（${group_name}）已就绪"
  log_info "vmauth Basic Auth 用户名：${group_name}"
  log_info "vmauth Basic Auth 密码：${org_password}"
}

cmd_org_update() {
  [ $# -ge 1 ] || { usage; exit 1; }
  local org_name=$1
  shift

  local grafana_org_name_arg="" account_id_arg="" vmauth_password_arg=""
  local rotate_password=false allow_duplicate_account_id=false use_existing_grafana_org=false changed=false
  local account_changed=false password_changed=false org_binding_changed=false org_renamed=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --grafana-org-name)
        [ $# -ge 2 ] || die "--grafana-org-name 参数需要提供值"
        grafana_org_name_arg=$2
        changed=true
        shift 2
        ;;
      --vm-account-id)
        [ $# -ge 2 ] || die "--vm-account-id 参数需要提供值"
        account_id_arg=$2
        require_number vm-account-id "${account_id_arg}"
        changed=true
        shift 2
        ;;
      --vmauth-password)
        [ $# -ge 2 ] || die "--vmauth-password 参数需要提供值"
        vmauth_password_arg=$2
        changed=true
        shift 2
        ;;
      --rotate-password)
        rotate_password=true
        changed=true
        shift
        ;;
      --allow-duplicate-account-id)
        allow_duplicate_account_id=true
        shift
        ;;
      --use-existing-grafana-org)
        use_existing_grafana_org=true
        shift
        ;;
      *) usage; exit 1 ;;
    esac
  done

  [ "${changed}" = true ] || die "org update 至少需要一个更新参数"
  [ -z "${vmauth_password_arg}" ] || [ "${rotate_password}" != true ] || die "--vmauth-password 与 --rotate-password 不能同时使用"

  load_runtime
  kc_get_admin_token

  local group_name group_id group_json existing_account_id existing_password existing_grafana_org_id
  local account_id org_password org_id grafana_org_name account_id_owner existing_org_id grafana_org_owner
  group_name="$(kc_group_name_for_org "${org_name}")"
  [ "${group_name}" != "org-main" ] || die "org update 仅用于租户组织；Main Org 请使用 org add --main 重新确保配置。"
  group_id="$(kc_get_group_id "${group_name}")"
  [ -n "${group_id}" ] || die "Keycloak group ${group_name} 未找到。请先运行 org add。"

  group_json="$(kc_get_group_json "${group_id}")"
  existing_account_id="$(kc_group_attribute "${group_json}" metrics_account_id)"
  existing_password="$(kc_group_attribute "${group_json}" vmauth_password)"
  existing_grafana_org_id="$(kc_group_attribute "${group_json}" grafana_org_id)"
  [ -n "${existing_account_id}" ] || die "Keycloak group ${group_name} 缺少 metrics_account_id。请先运行 org add 修复元数据。"
  [ -n "${existing_grafana_org_id}" ] || die "Keycloak group ${group_name} 缺少 grafana_org_id。请先运行 org add 修复元数据。"

  account_id="${existing_account_id}"
  if [ -n "${account_id_arg}" ]; then
    account_id="${account_id_arg}"
    if [ "${account_id}" != "${existing_account_id}" ]; then
      account_id_owner="$(kc_find_group_by_account_id "${account_id}" "${group_name}")"
      if [ -n "${account_id_owner}" ]; then
        if [ "${allow_duplicate_account_id}" = true ]; then
          log_warn "account-id ${account_id} 已被 Keycloak group ${account_id_owner} 使用，本次按参数要求继续复用"
        else
          die "account-id ${account_id} 已被 Keycloak group ${account_id_owner} 使用。如确认复用，请追加 --allow-duplicate-account-id。"
        fi
      fi
      account_changed=true
    fi
  fi

  org_password="${existing_password}"
  if [ "${rotate_password}" = true ]; then
    org_password="$(vmauth_generate_password)"
    password_changed=true
    log_info "已为 ${group_name} 生成新的 vmauth password"
  elif [ -n "${vmauth_password_arg}" ]; then
    org_password="${vmauth_password_arg}"
    [ "${org_password}" = "${existing_password}" ] || password_changed=true
  elif [ -z "${org_password}" ]; then
    org_password="$(vmauth_org_password "${org_name}")"
    password_changed=true
    log_info "沿用 ${group_name} 的旧版 vmauth password，并写入 Keycloak group attributes"
  fi

  org_id="${existing_grafana_org_id}"
  grafana_org_name="$(grafana_get_org_name "${org_id}")"
  [ -n "${grafana_org_name}" ] || die "Keycloak group ${group_name} 绑定的 Grafana 组织 id=${org_id} 未找到"
  grafana_org_owner="$(kc_find_group_by_grafana_org_id "${org_id}" "${group_name}")"
  [ -z "${grafana_org_owner}" ] || die "Grafana 组织 ${grafana_org_name}（id=${org_id}）已被 Keycloak group ${grafana_org_owner} 绑定。"

  if [ -n "${grafana_org_name_arg}" ] && [ "${grafana_org_name_arg}" != "${grafana_org_name}" ]; then
    existing_org_id="$(grafana_get_org_id_by_name "${grafana_org_name_arg}")"
    if [ -n "${existing_org_id}" ]; then
      grafana_org_owner="$(kc_find_group_by_grafana_org_id "${existing_org_id}" "${group_name}")"
      [ -z "${grafana_org_owner}" ] || die "Grafana 组织 ${grafana_org_name_arg}（id=${existing_org_id}）已被 Keycloak group ${grafana_org_owner} 绑定。"
      [ "${use_existing_grafana_org}" = true ] || die "Grafana 组织 ${grafana_org_name_arg} 已存在。如确认绑定到该组织，请追加 --use-existing-grafana-org。"
      org_id="${existing_org_id}"
      grafana_org_name="${grafana_org_name_arg}"
      [ "${org_id}" = "${existing_grafana_org_id}" ] || org_binding_changed=true
      log_warn "绑定到已有 Grafana 组织 ${grafana_org_name}（id=${org_id}）"
    else
      grafana_rename_org "${org_id}" "${grafana_org_name_arg}"
      grafana_org_name="${grafana_org_name_arg}"
      org_renamed=true
    fi
  fi

  if [ "${account_changed}" = true ]; then
    kc_set_group_attribute "${group_id}" metrics_account_id "${account_id}"
    log_info "已设置组 ${group_name} 的 metrics_account_id=${account_id}"
  fi
  if [ "${password_changed}" = true ]; then
    kc_set_group_attribute "${group_id}" vmauth_password "${org_password}"
    log_info "已设置组 ${group_name} 的 vmauth_password"
  fi
  if [ "${org_binding_changed}" = true ]; then
    kc_set_group_attribute "${group_id}" grafana_org_id "${org_id}"
    log_info "已设置组 ${group_name} 的 grafana_org_id=${org_id}"
    grafana_ensure_admins_in_org "${org_id}" "${grafana_org_name}"
  fi

  if [ "${account_changed}" = true ] || [ "${password_changed}" = true ]; then
    vmauth_write_org_entry "${group_name}" "${account_id}" "${org_password}"
    vmauth_generate_auth
    vmauth_reload
  fi
  if [ "${password_changed}" = true ] || [ "${org_binding_changed}" = true ]; then
    grafana_ensure_basic_datasource "${org_id}" "${grafana_org_name}" "${group_name}" "${org_password}"
  fi
  if [ "${org_binding_changed}" = true ]; then
    grafana_sync_oauth_from_keycloak
  fi

  if [ "${account_changed}" != true ] && [ "${password_changed}" != true ] && [ "${org_binding_changed}" != true ] && [ "${org_renamed}" != true ]; then
    log_info "组织 ${grafana_org_name}（${group_name}）没有需要更新的内容"
  fi

  log_ok "组织 ${grafana_org_name}（${group_name}）已更新"
  log_info "vmauth Basic Auth 用户名：${group_name}"
  log_info "vmauth Basic Auth 密码：${org_password}"
}

verify_jwt() {
  local token
  log_step "验证 Grafana OIDC JWT"
  token="$(curl -sS \
    -X POST "${KC_URL}/realms/${REALM}/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=grafana" \
    -d "client_secret=${GRAFANA_CLIENT_SECRET}" \
    -d "grant_type=password" \
    -d "username=${GF_ADMIN_USER}" \
    -d "password=${GF_ADMIN_PASS}" | jq -r '.access_token // empty')"
  if [ -n "${token}" ]; then
    printf '%s' "${token}" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{username: .preferred_username, groups: .groups}' || true
  else
    log_warn "跳过 JWT 验证，令牌请求失败"
  fi
}

print_summary() {
  cat <<EOF

部署完成。

Grafana：  ${GRAFANA_URL}
Keycloak： ${KC_URL}
vmauth：   http://${HOST_IP}:${VMAUTH_PORT:-8427}

Grafana OIDC 用户：${GF_ADMIN_USER} / ${GF_ADMIN_PASS}
Keycloak 管理员：   ${KC_ADMIN_USER} / ${KC_ADMIN_PASS}

添加租户：
  bash scripts/manage.sh org add org-test 测试组织
  bash scripts/manage.sh user add alice passA alice@example.com admin
  bash scripts/manage.sh org user add org-test alice
EOF
}

cmd_init() {
  check_prerequisites
  load_runtime
  require_bootstrap_env

  vmauth_clean_tenant_entries
  vmauth_generate_auth
  compose_up
  wait_for_keycloak
  kc_setup_base
  wait_for_grafana
  cmd_org_add --main
  cmd_user_add "${GF_ADMIN_USER}" "${GF_ADMIN_PASS}" "${KC_ADMIN_EMAIL}" grafanaAdmin
  cmd_org_user_add org-main "${GF_ADMIN_USER}"
  cmd_oauth_sync
  verify_jwt
  print_summary
}

main() {
  [ $# -gt 0 ] || { usage; exit 1; }
  local scope=$1
  shift

  case "${scope}" in
    init) cmd_init "$@" ;;
    kc)
      [ "${1:-}" = "setup" ] || { usage; exit 1; }
      shift
      cmd_kc_setup "$@"
      ;;
    org)
      case "${1:-}" in
        add) shift; cmd_org_add "$@" ;;
        update) shift; cmd_org_update "$@" ;;
        user)
          shift
          case "${1:-}" in
            add) shift; cmd_org_user_add "$@" ;;
            delete) shift; cmd_org_user_delete "$@" ;;
            *) usage; exit 1 ;;
          esac
          ;;
        *) usage; exit 1 ;;
      esac
      ;;
    user)
      case "${1:-}" in
        add) shift; cmd_user_add "$@" ;;
        delete) shift; cmd_user_delete "$@" ;;
        groups) shift; cmd_user_groups "$@" ;;
        *) usage; exit 1 ;;
      esac
      ;;
    oauth)
      [ "${1:-}" = "sync" ] || { usage; exit 1; }
      shift
      cmd_oauth_sync "$@"
      ;;
    dashboard)
      [ "${1:-}" = "import" ] || { usage; exit 1; }
      shift
      cmd_dashboard_import "$@"
      ;;
    auth)
      [ "${1:-}" = "generate" ] || { usage; exit 1; }
      shift
      cmd_auth_generate "$@"
      ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
