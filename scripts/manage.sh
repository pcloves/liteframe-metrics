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
# shellcheck source=lib/stats.sh
source "${SCRIPT_DIR}/lib/stats.sh"

log_init

is_help_arg() {
  case "${1:-}" in
    help|-h|--help) return 0 ;;
    *) return 1 ;;
  esac
}

usage() {
  help_main
}

help_main() {
  cat <<'EOF'
CardFrame VM Cluster 管理 CLI

用法：
  bash scripts/manage.sh <command> [args] [options]
  bash scripts/manage.sh <command> --help

概览：
  manage.sh 用于初始化和维护 Grafana + Keycloak + VictoriaMetrics 多租户监控集群。
  所有操作会输出到终端，并写入 logs/manage-YYYYMMDD.log。

常用流程：
  初始化完整环境：
    bash scripts/manage.sh init

  创建租户组织：
    bash scripts/manage.sh org add org-ztdev 中台

  创建用户并加入租户：
    bash scripts/manage.sh user add alice passA alice@example.com admin
    bash scripts/manage.sh org user add org-ztdev alice

  轮换租户 vmauth Basic Auth 密码：
    bash scripts/manage.sh org update org-ztdev --rotate-password

  导入全部租户 dashboard：
    bash scripts/manage.sh dashboard import --all-tenants --overwrite

命令分组：
  init                  初始化 docker compose、Keycloak、Main Org、管理员和 OAuth 映射
  kc setup              配置 Keycloak realm、Grafana 客户端、角色组和默认管理员
  org                   管理 Main Org、租户组织、租户元数据和组织成员
  user                  管理 Keycloak 用户身份和 Grafana 角色组
  sync                  从 Keycloak group attributes 同步 OAuth 映射和租户认证配置
  stats                 查看组织、用户和配置健康状态
  dashboard import      导入平台或租户 dashboard
  auth generate         从模板和 Keycloak 元数据生成 vmauth/auth.yaml

关键概念：
  <org-name>            内部组织名，映射为 Keycloak group，通常形如 org-ztdev
  <grafana-org-name>    Grafana 组织显示名，可以使用中文，默认必须唯一
  org-main              固定映射 Grafana 内置 Main Org.（org ID 1）
  vm-account-id         VictoriaMetrics tenant account ID，保存在 Keycloak group attributes
  vmauth Basic Auth     每个租户 datasource 使用的 Basic Auth 凭据

更多帮助：
  bash scripts/manage.sh org --help
  bash scripts/manage.sh org add --help
  bash scripts/manage.sh org update --help
  bash scripts/manage.sh user --help
  bash scripts/manage.sh sync --help
  bash scripts/manage.sh stats --help
  bash scripts/manage.sh dashboard import --help
EOF
}

help_kc() {
  cat <<'EOF'
Keycloak 管理

用法：
  bash scripts/manage.sh kc setup

命令：
  setup                 配置 realm、Grafana 客户端、角色组和正式管理员

说明：
  kc setup 是初始化流程的一部分，通常由 bash scripts/manage.sh init 自动调用。
  如需单独修复 Keycloak 基础配置，可手动执行该命令。
EOF
}

help_org() {
  cat <<'EOF'
组织管理

用法：
  bash scripts/manage.sh org <subcommand> [args] [options]

命令：
  add                   创建或确保 Main Org / 租户组织存在
  update                更新已有租户的 Grafana org、vm-account-id 或 vmauth 密码
  user add              将用户加入 Keycloak 组织 group
  user delete           将用户移出 Keycloak 组织 group

示例：
  bash scripts/manage.sh org add --main
  bash scripts/manage.sh org add org-ztdev 中台
  bash scripts/manage.sh org update org-ztdev --rotate-password
  bash scripts/manage.sh org user add org-ztdev alice

更多帮助：
  bash scripts/manage.sh org add --help
  bash scripts/manage.sh org update --help
  bash scripts/manage.sh org user --help
EOF
}

help_org_add() {
  cat <<'EOF'
创建或确保组织

用法：
  bash scripts/manage.sh org add --main
  bash scripts/manage.sh org add <org-name> <grafana-org-name> [options]

参数：
  <org-name>            内部组织名，映射为 Keycloak group；可传 org-ztdev 或 ztdev
  <grafana-org-name>    Grafana 组织显示名，可以使用中文，默认必须唯一

选项：
  --vm-account-id <id>              指定 VictoriaMetrics tenant account ID
  --vmauth-password <password>      指定租户 vmauth Basic Auth 密码
  --allow-duplicate-account-id      允许复用已被其他 Keycloak group 使用的 vm-account-id
  --use-existing-grafana-org        绑定到未被其他 Keycloak group 使用的已有 Grafana org

行为：
  --main 固定确保 Keycloak group org-main 绑定 Grafana 内置 Main Org.（org ID 1）。
  租户组织会创建或确保 Keycloak group、Grafana org、vmauth auth entry、Grafana datasource 和租户 dashboard。
  未指定 --vm-account-id 时自动分配下一个可用正整数；0 保留给 org-main。
  未指定 --vmauth-password 时自动生成，并存入 Keycloak group attributes。
  已存在的租户只做幂等 ensure；如需修改绑定或密码，请使用 org update。

示例：
  bash scripts/manage.sh org add --main
  bash scripts/manage.sh org add org-ztdev 中台
  bash scripts/manage.sh org add org-test 测试 --vm-account-id 12
  bash scripts/manage.sh org add org-prod 生产 --vmauth-password 'change-me'
EOF
}

help_org_update() {
  cat <<'EOF'
更新租户组织元数据

用法：
  bash scripts/manage.sh org update <org-name> [options]

参数：
  <org-name>            已存在租户的内部组织名；org update 不用于 org-main

选项：
  --grafana-org-name <name>         修改当前 Grafana org 名称，或配合 --use-existing-grafana-org 重新绑定
  --vm-account-id <id>              修改 VictoriaMetrics tenant account ID
  --vmauth-password <password>      设置新的 vmauth Basic Auth 密码
  --rotate-password                 自动生成新的 vmauth Basic Auth 密码
  --allow-duplicate-account-id      允许复用已被其他 Keycloak group 使用的 vm-account-id
  --use-existing-grafana-org        将租户重新绑定到未被其他 Keycloak group 使用的已有 Grafana org

行为：
  --grafana-org-name <新名字> 默认只重命名当前 Grafana org，不重写 Keycloak、vmauth、datasource 或 OAuth。
  --grafana-org-name <已有组织> --use-existing-grafana-org 会更新 grafana_org_id、datasource 和 OAuth mapping。
  --vm-account-id 会更新 Keycloak group attributes、重写 vmauth auth entry，并 reload vmauth。
  --vmauth-password 或 --rotate-password 会更新 Keycloak group attributes、vmauth auth entry、vmauth reload 和 Grafana datasource Basic Auth 密码。
  --vmauth-password 不能与 --rotate-password 同时使用。

示例：
  bash scripts/manage.sh org update org-ztdev --grafana-org-name 中台研发
  bash scripts/manage.sh org update org-ztdev --rotate-password
  bash scripts/manage.sh org update org-ztdev --vm-account-id 21
  bash scripts/manage.sh org update org-ztdev --vmauth-password 'new-password'
  bash scripts/manage.sh org update org-ztdev --grafana-org-name 已有组织 --use-existing-grafana-org
EOF
}

help_org_user() {
  cat <<'EOF'
组织成员管理

用法：
  bash scripts/manage.sh org user add <org-name> <username>
  bash scripts/manage.sh org user delete <org-name> <username>

说明：
  org user add/delete 只管理 Keycloak group 成员身份，不修改用户的 Grafana 角色。
  用户角色由 user add <username> <password> <email> <role> 管理。

示例：
  bash scripts/manage.sh org user add org-ztdev alice
  bash scripts/manage.sh org user delete org-ztdev alice
  bash scripts/manage.sh org user add org-main admin
EOF
}

help_user() {
  cat <<'EOF'
用户管理

用法：
  bash scripts/manage.sh user <subcommand> [args] [options]

命令：
  add                   创建或更新用户身份，并替换 Grafana 角色组
  delete                禁用用户；追加 --force 时永久删除用户
  groups                列出用户当前 Keycloak group

角色：
  grafanaAdmin          Grafana server admin；通常用于平台管理员
  admin                 Grafana org Admin
  editor                Grafana org Editor
  viewer                不加入 role-* group，并清理旧 admin/editor/grafanaAdmin 角色组

示例：
  bash scripts/manage.sh user add alice passA alice@example.com admin
  bash scripts/manage.sh user groups alice
  bash scripts/manage.sh user delete alice

更多帮助：
  bash scripts/manage.sh user add --help
  bash scripts/manage.sh user delete --help
  bash scripts/manage.sh user groups --help
EOF
}

help_user_add() {
  cat <<'EOF'
创建或更新用户

用法：
  bash scripts/manage.sh user add <username> <password> <email> <role>

参数：
  <username>            Keycloak 用户名
  <password>            用户密码
  <email>               用户邮箱
  <role>                grafanaAdmin、admin、editor 或 viewer

行为：
  user add 是幂等 upsert：确保用户存在，同步邮箱和密码。
  每次执行都会替换 Grafana 角色组，避免 admin/editor 等角色叠加。
  viewer 表示不加入任何 role-* group，并移除旧角色组。
  组织成员身份请使用 org user add/delete 单独管理。

示例：
  bash scripts/manage.sh user add alice passA alice@example.com admin
  bash scripts/manage.sh user add bob passB bob@example.com viewer
EOF
}

help_user_delete() {
  cat <<'EOF'
删除或禁用用户

用法：
  bash scripts/manage.sh user delete <username> [--force]

选项：
  --force               永久删除 Keycloak 用户；不加该参数时只禁用用户

示例：
  bash scripts/manage.sh user delete alice
  bash scripts/manage.sh user delete alice --force
EOF
}

help_user_groups() {
  cat <<'EOF'
查看用户 group

用法：
  bash scripts/manage.sh user groups <username>

说明：
  输出用户当前所属 Keycloak group，可用于排查组织成员和 Grafana 角色映射。

示例：
  bash scripts/manage.sh user groups alice
EOF
}

help_stats() {
  cat <<'EOF'
统计与健康检查

用法：
  bash scripts/manage.sh stats org [--format table|csv] [--output <file>]
  bash scripts/manage.sh stats user [--format table|csv] [--output <file>]
  bash scripts/manage.sh stats health [--format table|csv] [--output <file>]

命令：
  org                   按组织维度展示 Keycloak group、Grafana org、vmauth entry 和 datasource 状态
  user                  按用户维度展示角色、组织成员身份和账号状态
  health                只展示发现的问题；无问题时输出 ok

选项：
  --format table|csv    输出格式，默认 table
  --output <file>       将输出写入文件；文件名以 .csv 结尾且未指定 --format 时自动使用 csv

示例：
  bash scripts/manage.sh stats org
  bash scripts/manage.sh stats org --format csv --output orgs.csv
  bash scripts/manage.sh stats user --format csv --output users.csv
  bash scripts/manage.sh stats health
EOF
}

help_stats_org() {
  cat <<'EOF'
组织统计

用法：
  bash scripts/manage.sh stats org [--format table|csv] [--output <file>]

字段：
  group_name、grafana_org_id、grafana_org_name、vm_account_id、has_vmauth_password
  vmauth_entry_exists、datasource_exists、member_count、admin_count、editor_count、viewer_count、status

说明：
  以 Keycloak 组织 group 为主视角，包含 org-main。
  status 为 ok、incomplete_attributes、missing_grafana_org、missing_vmauth_entry 或 missing_datasource。
EOF
}

help_stats_user() {
  cat <<'EOF'
用户统计

用法：
  bash scripts/manage.sh stats user [--format table|csv] [--output <file>]

字段：
  username、email、enabled、role、grafana_admin、org_count、org_groups、role_groups、other_groups、status

说明：
  CSV 中多个 group 会放在同一个单元格内，并使用 ; 分隔。
  role 根据 role-* group 归一化为 grafanaAdmin、admin、editor、viewer 或 conflict。
EOF
}

help_stats_health() {
  cat <<'EOF'
配置健康检查

用法：
  bash scripts/manage.sh stats health [--format table|csv] [--output <file>]

字段：
  scope、object、severity、issue、suggestion

说明：
  只输出发现的问题；没有问题时输出一行 ok。
  检查 Keycloak group 元数据、Grafana org 绑定、vmauth entry、datasource、stale auth entry 和用户角色/组织成员异常。
EOF
}

help_dashboard_import() {
  cat <<'EOF'
导入 dashboard

用法：
  bash scripts/manage.sh dashboard import <org-name> [--overwrite]
  bash scripts/manage.sh dashboard import --main [--overwrite]
  bash scripts/manage.sh dashboard import --all-tenants [--overwrite]

选项：
  --overwrite                       覆盖已存在的同 UID dashboard

行为：
  --main 导入 grafana/dashboards/platform/ 到 Grafana Main Org.。
  <org-name> 导入 grafana/dashboards/tenants/ 到单个租户组织。
  --all-tenants 根据 Keycloak group attributes 遍历全部租户并导入租户 dashboard。
  导入前会删除 dashboard __inputs，并将 datasource 统一为 vmauth-cluster。
  <org-name> 通过 Keycloak group attributes 中的 grafana_org_id 定位 Grafana 组织。

示例：
  bash scripts/manage.sh dashboard import --main --overwrite
  bash scripts/manage.sh dashboard import org-ztdev --overwrite
  bash scripts/manage.sh dashboard import --all-tenants --overwrite
EOF
}

help_sync() {
  cat <<'EOF'
同步派生配置

用法：
  bash scripts/manage.sh sync oauth-mapping
  bash scripts/manage.sh sync tenant-auth <org-name>
  bash scripts/manage.sh sync tenant-auth --all [--prune-stale]
  bash scripts/manage.sh sync all [--prune-stale]

命令：
  oauth-mapping         从 Keycloak group grafana_org_id 重建 Grafana OAuth org_mapping
  tenant-auth           从 Keycloak group 元数据同步 vmauth entry 和 Grafana datasource Basic Auth
  all                   先同步 tenant-auth --all，再同步 oauth-mapping

说明：
  组织 group 不按名称前缀识别，而是按 Keycloak group attributes 判定。
  同时具备 metrics_account_id、vmauth_password、grafana_org_id 的 group 会被视为组织 group。
  只具备其中一部分组织元数据的 group 会被视为异常并中止同步。

示例：
  bash scripts/manage.sh sync oauth-mapping
  bash scripts/manage.sh sync tenant-auth org-ztdev
  bash scripts/manage.sh sync tenant-auth --all
  bash scripts/manage.sh sync tenant-auth --all --prune-stale
  bash scripts/manage.sh sync all --prune-stale

更多帮助：
  bash scripts/manage.sh sync tenant-auth --help
  bash scripts/manage.sh sync oauth-mapping --help
EOF
}

help_sync_oauth_mapping() {
  cat <<'EOF'
同步 OAuth 组织映射

用法：
  bash scripts/manage.sh sync oauth-mapping

行为：
  根据当前 Keycloak group attributes 中的 grafana_org_id 重建 Grafana OAuth org_mapping。
  已从 Keycloak 删除或不再绑定 grafana_org_id 的 group，其旧 OAuth mapping 会被移除。
  该命令不更新 vmauth/auth.yaml，也不更新 Grafana datasource Basic Auth。
EOF
}

help_sync_tenant_auth() {
  cat <<'EOF'
同步租户认证配置

用法：
  bash scripts/manage.sh sync tenant-auth <org-name>
  bash scripts/manage.sh sync tenant-auth --all [--prune-stale]

选项：
  --all                 同步所有具备完整组织元数据的 Keycloak group，包含 org-main
  --prune-stale         已废弃；vmauth/auth.yaml 现在直接由模板和 Keycloak 元数据生成

  行为：
  从 Keycloak group attributes 读取 metrics_account_id、vmauth_password、grafana_org_id。
  重新生成 vmauth/auth.yaml，并 reload vmauth。
  更新对应 Grafana org 的 datasource vmauth-cluster（Basic Auth 用户名/密码）。
  --all 不按 group 名称前缀筛选；只按完整组织元数据判定。
  vmauth/auth.yaml 是生成产物；租户 entry 不再单独落盘。

示例：
  bash scripts/manage.sh sync tenant-auth org-ztdev
  bash scripts/manage.sh sync tenant-auth main
  bash scripts/manage.sh sync tenant-auth --all
  bash scripts/manage.sh sync tenant-auth --all --prune-stale
EOF
}

help_auth() {
  cat <<'EOF'
生成 vmauth 配置

用法：
  bash scripts/manage.sh auth generate

说明：
  从 vmauth/templates/*.yaml 和 Keycloak group metadata 生成 vmauth/auth.yaml。
  该命令需要 Keycloak 正式管理员可用。
  vmauth/auth.yaml 是生成产物，不应手动编辑或提交。
EOF
}

load_runtime() {
  load_env
}

cmd_auth_generate() {
  if is_help_arg "${1:-}"; then help_auth; exit 0; fi
  [ $# -eq 0 ] || { help_auth; exit 1; }
  load_runtime
  kc_get_admin_token
  vmauth_generate_auth
}

cmd_kc_setup() {
  if is_help_arg "${1:-}"; then help_kc; exit 0; fi
  [ $# -eq 0 ] || { help_kc; exit 1; }
  load_runtime
  require_bootstrap_env
  kc_setup_base
}

cmd_user_add() {
  if is_help_arg "${1:-}"; then help_user_add; exit 0; fi
  [ $# -eq 4 ] || { help_user_add; exit 1; }
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
  if is_help_arg "${1:-}"; then help_org_user; exit 0; fi
  [ $# -eq 2 ] || { help_org_user; exit 1; }
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
  if is_help_arg "${1:-}"; then help_org_user; exit 0; fi
  [ $# -eq 2 ] || { help_org_user; exit 1; }
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
  if is_help_arg "${1:-}"; then help_user_groups; exit 0; fi
  [ $# -eq 1 ] || { help_user_groups; exit 1; }
  local username=$1 user_id

  load_runtime
  kc_get_admin_token
  user_id="$(kc_get_user_id "${username}")"
  [ -n "${user_id}" ] || die "用户 ${username} 未找到"

  kc_list_user_groups "${user_id}" | jq -r '.[].name' | sort
}

cmd_user_delete() {
  if is_help_arg "${1:-}"; then help_user_delete; exit 0; fi
  [ $# -ge 1 ] || { help_user_delete; exit 1; }
  local username=$1 force=false user_id
  if [ "${2:-}" = "--force" ]; then
    force=true
  elif [ $# -gt 1 ]; then
    help_user_delete
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

cmd_stats() {
  if [ $# -eq 0 ] || is_help_arg "${1:-}"; then help_stats; exit 0; fi
  local subcommand=$1
  shift

  case "${subcommand}" in
    org)
      if is_help_arg "${1:-}"; then help_stats_org; exit 0; fi
      stats_parse_output_args "$@" || { help_stats_org; exit 1; }
      load_runtime
      kc_get_admin_token
      stats_show_org
      ;;
    user)
      if is_help_arg "${1:-}"; then help_stats_user; exit 0; fi
      stats_parse_output_args "$@" || { help_stats_user; exit 1; }
      load_runtime
      kc_get_admin_token
      stats_show_user
      ;;
    health)
      if is_help_arg "${1:-}"; then help_stats_health; exit 0; fi
      stats_parse_output_args "$@" || { help_stats_health; exit 1; }
      load_runtime
      kc_get_admin_token
      stats_show_health
      ;;
    *) help_stats; exit 1 ;;
  esac
}

sync_tenant_auth_group() {
  local group_name=$1 group_json=$2
  local account_id vmauth_password grafana_org_id grafana_org_name

  account_id="$(printf '%s' "${group_json}" | jq -r '.attributes.metrics_account_id[0] // empty')"
  vmauth_password="$(printf '%s' "${group_json}" | jq -r '.attributes.vmauth_password[0] // empty')"
  grafana_org_id="$(printf '%s' "${group_json}" | jq -r '.attributes.grafana_org_id[0] // empty')"

  [ -n "${account_id}" ] || die "Keycloak group ${group_name} 的组织元数据不完整：缺少 metrics_account_id"
  [ -n "${vmauth_password}" ] || die "Keycloak group ${group_name} 的组织元数据不完整：缺少 vmauth_password"
  [ -n "${grafana_org_id}" ] || die "Keycloak group ${group_name} 的组织元数据不完整：缺少 grafana_org_id"

  grafana_org_name="$(grafana_get_org_name "${grafana_org_id}")"
  [ -n "${grafana_org_name}" ] || die "Keycloak group ${group_name} 绑定的 Grafana 组织 id=${grafana_org_id} 未找到"

  log_info "同步租户认证：${group_name}（Grafana org ${grafana_org_name}，id=${grafana_org_id}，vm-account-id=${account_id}）"
  grafana_ensure_basic_datasource "${grafana_org_id}" "${grafana_org_name}" "${group_name}" "${vmauth_password}"
}

sync_tenant_auth_single() {
  local org_name=$1 group_name group_id group_json

  group_name="$(kc_group_name_for_org "${org_name}")"
  group_id="$(kc_get_group_id "${group_name}")"
  [ -n "${group_id}" ] || die "Keycloak group ${group_name} 未找到。请先运行 org add。"

  group_json="$(kc_get_group_json "${group_id}")"
  sync_tenant_auth_group "${group_name}" "${group_json}"
  vmauth_generate_auth
  vmauth_reload
  log_ok "租户认证已同步：${group_name}"
}

sync_tenant_auth_all() {
  local prune_stale=$1 kc_groups group group_id group_name group_json synced_count=0 skipped_count=0

  kc_groups="$(kc_list_groups_full)"

  while read -r group; do
    group_id="$(printf '%s' "${group}" | jq -r '.id // empty')"
    group_name="$(printf '%s' "${group}" | jq -r '.name // empty')"
    [ -n "${group_id}" ] || continue
    [ -n "${group_name}" ] || continue

    group_json="$(kc_get_group_json "${group_id}")"
    if printf '%s' "${group_json}" | jq -e '.attributes.metrics_account_id[0]? and .attributes.vmauth_password[0]? and .attributes.grafana_org_id[0]?' >/dev/null 2>&1; then
      sync_tenant_auth_group "${group_name}" "${group_json}"
      synced_count=$((synced_count + 1))
    else
      if printf '%s' "${group_json}" | jq -e '.attributes.metrics_account_id[0]? or .attributes.vmauth_password[0]? or .attributes.grafana_org_id[0]?' >/dev/null 2>&1; then
        local missing_attrs=()
        printf '%s' "${group_json}" | jq -e '.attributes.metrics_account_id[0]?' >/dev/null 2>&1 || missing_attrs+=(metrics_account_id)
        printf '%s' "${group_json}" | jq -e '.attributes.vmauth_password[0]?' >/dev/null 2>&1 || missing_attrs+=(vmauth_password)
        printf '%s' "${group_json}" | jq -e '.attributes.grafana_org_id[0]?' >/dev/null 2>&1 || missing_attrs+=(grafana_org_id)
        die "Keycloak group ${group_name} 的组织元数据不完整：缺少 ${missing_attrs[*]}"
      fi
      skipped_count=$((skipped_count + 1))
    fi
  done < <(printf '%s' "${kc_groups}" | jq -c '.[]')

  if [ "${prune_stale}" = true ]; then
    log_warn "--prune-stale 已废弃：vmauth/auth.yaml 直接由 Keycloak 当前元数据生成，不再保留过期租户 entry"
  fi

  vmauth_generate_auth
  vmauth_reload
  local summary="租户认证已同步：${synced_count} 个已更新"
  log_ok "${summary}"
}

sync_oauth_mapping() {
  load_runtime
  kc_get_admin_token
  grafana_sync_oauth_from_keycloak
}

cmd_sync() {
  if is_help_arg "${1:-}"; then help_sync; exit 0; fi
  [ $# -ge 1 ] || { help_sync; exit 1; }

  case "$1" in
    oauth-mapping)
      shift
      if is_help_arg "${1:-}"; then help_sync_oauth_mapping; exit 0; fi
      [ $# -eq 0 ] || { help_sync_oauth_mapping; exit 1; }
      sync_oauth_mapping
      ;;
    tenant-auth)
      shift
      if [ $# -eq 0 ] || is_help_arg "${1:-}"; then help_sync_tenant_auth; exit 0; fi
      local all=false prune_stale=false org_name=""
      if [ "${1:-}" = "--all" ]; then
        all=true
        shift
      else
        org_name=$1
        shift
      fi
      while [ $# -gt 0 ]; do
        case "$1" in
          --prune-stale) prune_stale=true ;;
          *) help_sync_tenant_auth; exit 1 ;;
        esac
        shift
      done

      load_runtime
      kc_get_admin_token
      if [ "${all}" = true ]; then
        sync_tenant_auth_all "${prune_stale}"
      else
        sync_tenant_auth_single "${org_name}"
      fi
      ;;
    all)
      shift
      if is_help_arg "${1:-}"; then help_sync; exit 0; fi
      local prune_stale=false
      while [ $# -gt 0 ]; do
        case "$1" in
          --prune-stale) prune_stale=true ;;
          *) help_sync; exit 1 ;;
        esac
        shift
      done
      load_runtime
      kc_get_admin_token
      sync_tenant_auth_all "${prune_stale}"
      sync_oauth_mapping
      ;;
    *) help_sync; exit 1 ;;
  esac
}

cmd_dashboard_import() {
  if is_help_arg "${1:-}"; then help_dashboard_import; exit 0; fi
  [ $# -ge 1 ] || { help_dashboard_import; exit 1; }
  local is_main=false all_tenants=false org_name grafana_org_id overwrite=false group_name

  if [ "$1" = "--main" ]; then
    [ $# -le 2 ] || { help_dashboard_import; exit 1; }
    is_main=true
    org_name="main"
    shift
  elif [ "$1" = "--all-tenants" ]; then
    [ $# -le 2 ] || { help_dashboard_import; exit 1; }
    all_tenants=true
    shift
  else
    org_name=$1
    shift
  fi

  load_runtime
  kc_get_admin_token

  if [ "${is_main}" = true ]; then
    grafana_org_id=1
  else
    group_name="$(kc_group_name_for_org "${org_name}")"
    local group_id group_json
    group_id="$(kc_get_group_id "${group_name}")"
    [ -n "${group_id}" ] || die "Keycloak group ${group_name} 未找到。请先运行 org add。"
    group_json="$(kc_get_group_json "${group_id}")"
    grafana_org_id="$(printf '%s' "${group_json}" | jq -r '.attributes.grafana_org_id[0] // empty')"
    [ -n "${grafana_org_id}" ] || die "Keycloak group ${group_name} 缺少 grafana_org_id 属性"
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --overwrite)
        overwrite=true
        shift
        ;;
      *) help_dashboard_import; exit 1 ;;
    esac
  done

  if [ "${all_tenants}" = true ]; then
    dashboard_import_all_tenants "${overwrite}"
    return
  fi

  if [ "${is_main}" = true ]; then
    dashboards_import platform "${group_name}" "${grafana_org_id}" "${overwrite}"
  else
    dashboards_import tenants "${group_name}" "${grafana_org_id}" "${overwrite}"
  fi
}

dashboard_import_all_tenants() {
  local overwrite=$1 kc_groups group group_id group_name group_json grafana_org_id count=0
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

    dashboards_import tenants "${group_name}" "${grafana_org_id}" "${overwrite}"
    count=$((count + 1))
  done < <(printf '%s' "${kc_groups}" | jq -c '.[]')

  [ "${count}" -gt 0 ] || log_warn "未找到租户组织用于导入仪表盘"
}

cmd_org_add() {
  if is_help_arg "${1:-}"; then help_org_add; exit 0; fi
  [ $# -ge 1 ] || { help_org_add; exit 1; }
  local is_main=false allow_duplicate_account_id=false use_existing_grafana_org=false
  local org_name account_id="" account_id_arg="" grafana_org_name group_name group_id group_json="" org_id="" org_password="" vmauth_password_arg=""
  local account_id_owner="" grafana_org_owner="" existing_account_id="" existing_password="" existing_grafana_org_id="" existing_grafana_org_name="" existing_org_id=""

  if [ "$1" = "--main" ]; then
    [ $# -eq 1 ] || { help_org_add; exit 1; }
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
        *) help_org_add; exit 1 ;;
      esac
    done
  else
    help_org_add
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

  vmauth_generate_auth
  vmauth_reload

  grafana_ensure_basic_datasource "${org_id}" "${grafana_org_name}" "${group_name}" "${org_password}"
  if [ "${is_main}" = true ]; then
    dashboards_import platform "${group_name}" "${org_id}" false
  else
    dashboards_import tenants "${group_name}" "${org_id}" false
  fi
  grafana_sync_oauth_from_keycloak
  log_ok "组织 ${grafana_org_name}（${group_name}）已就绪"
  log_info "vmauth Basic Auth 用户名：${group_name}"
  log_info "vmauth Basic Auth 密码：${org_password}"
}

cmd_org_update() {
  if is_help_arg "${1:-}"; then help_org_update; exit 0; fi
  [ $# -ge 1 ] || { help_org_update; exit 1; }
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
      *) help_org_update; exit 1 ;;
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
    -d "username=${GF_OIDC_ADMIN_USER}" \
    -d "password=${GF_OIDC_ADMIN_PASS}" | jq -r '.access_token // empty')"
  if [ -n "${token}" ]; then
    printf '%s' "${token}" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{username: .preferred_username, groups: .groups}' || true
  else
    log_warn "跳过 JWT 验证，令牌请求失败"
  fi
}

print_summary() {
  : "${VMAUTH_PORT:=8427}"
  cat <<EOF

部署完成。

Grafana（内网）：  http://${GRAFANA_HOST_NAME_INTERNAL}:${GRAFANA_PORT}
Grafana（外网）：  ${GRAFANA_SCHEME_EXTERNAL}://${GRAFANA_HOST_NAME_EXTERNAL}:${GRAFANA_PORT}
Keycloak（内网）： http://${KEYCLOAK_HOST_NAME_INTERNAL}:${KC_PORT}
Keycloak（外网）： ${KEYCLOAK_SCHEME_EXTERNAL}://${KEYCLOAK_HOST_NAME_EXTERNAL}:${KC_PORT}
vmauth（内网）：   http://${VMAUTH_HOST_NAME_INTERNAL}:${VMAUTH_PORT}
vmauth（外网）：   ${VMAUTH_SCHEME_EXTERNAL}://${VMAUTH_HOST_NAME_EXTERNAL}:${VMAUTH_PORT}

Grafana 内置 admin：${GF_SECURITY_ADMIN_USER} / ${GF_SECURITY_ADMIN_PASSWORD}
Grafana OIDC 用户：${GF_OIDC_ADMIN_USER} / ${GF_OIDC_ADMIN_PASS}
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

  vmauth_generate_internal_auth
  prepare_keycloak_data_dir
  compose_up
  kc_setup_base
  cmd_org_add --main
  cmd_user_add "${GF_OIDC_ADMIN_USER}" "${GF_OIDC_ADMIN_PASS}" "${KC_ADMIN_EMAIL}" grafanaAdmin
  cmd_org_user_add org-main "${GF_OIDC_ADMIN_USER}"
  sync_oauth_mapping
  verify_jwt
  print_summary
}

main() {
  [ $# -gt 0 ] || { usage; exit 1; }
  local scope=$1
  shift

  case "${scope}" in
    init)
      if is_help_arg "${1:-}"; then help_main; exit 0; fi
      [ $# -eq 0 ] || { help_main; exit 1; }
      cmd_init
      ;;
    kc)
      if [ $# -eq 0 ] || is_help_arg "${1:-}"; then help_kc; exit 0; fi
      case "${1:-}" in
        setup) shift; cmd_kc_setup "$@" ;;
        *) help_kc; exit 1 ;;
      esac
      ;;
    org)
      case "${1:-}" in
        add) shift; cmd_org_add "$@" ;;
        update) shift; cmd_org_update "$@" ;;
        help|-h|--help|"") help_org ;;
        user)
          shift
          case "${1:-}" in
            add) shift; cmd_org_user_add "$@" ;;
            delete) shift; cmd_org_user_delete "$@" ;;
            help|-h|--help|"") help_org_user ;;
            *) help_org_user; exit 1 ;;
          esac
          ;;
        *) help_org; exit 1 ;;
      esac
      ;;
    user)
      case "${1:-}" in
        add) shift; cmd_user_add "$@" ;;
        delete) shift; cmd_user_delete "$@" ;;
        groups) shift; cmd_user_groups "$@" ;;
        help|-h|--help|"") help_user ;;
        *) help_user; exit 1 ;;
      esac
      ;;
    sync)
      cmd_sync "$@"
      ;;
    stats)
      cmd_stats "$@"
      ;;
    dashboard)
      if [ $# -eq 0 ] || is_help_arg "${1:-}"; then help_dashboard_import; exit 0; fi
      case "${1:-}" in
        import) shift; cmd_dashboard_import "$@" ;;
        *) help_dashboard_import; exit 1 ;;
      esac
      ;;
    auth)
      if [ $# -eq 0 ] || is_help_arg "${1:-}"; then help_auth; exit 0; fi
      case "${1:-}" in
        generate) shift; cmd_auth_generate "$@" ;;
        *) help_auth; exit 1 ;;
      esac
      ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
