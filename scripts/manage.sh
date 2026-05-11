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
Usage:
  bash scripts/manage.sh init
  bash scripts/manage.sh kc setup
  bash scripts/manage.sh org add --main
  bash scripts/manage.sh org add <org-name> <account-id> <display-name>
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

Roles:
  grafanaAdmin | admin | editor | viewer

Notes:
  user add is idempotent: it creates/updates the user and replaces any existing Grafana role group.
  org user add/delete manages Keycloak org group membership separately from user role.
  <org-name> is the internal org key, not the Grafana display name.
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
    *) die "role must be grafanaAdmin, admin, editor, or viewer" ;;
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
    [ -n "${role_group_id}" ] || log_warn "Role group ${role_group_name} not found; role assignment skipped"
  fi

  log_step "Add/update user ${username}"
  user_id="$(kc_ensure_user "${username}" "${password}" "${email}")"
  log_step "Set Grafana role for ${username} to ${role}"
  for existing_role_group in role-grafanaAdmin role-admin role-editor; do
    existing_role_group_id="$(kc_get_group_id "${existing_role_group}")"
    [ -n "${existing_role_group_id}" ] || continue
    kc_remove_user_group "${user_id}" "${existing_role_group_id}" "${existing_role_group}" || true
  done
  if [ -n "${role_group_id}" ]; then
    kc_assign_user_group "${user_id}" "${role_group_id}" "${role_group_name}"
  else
    log_info "User role is viewer; no role-* group assigned"
  fi
  log_ok "User ${username} ready"
}

cmd_org_user_add() {
  [ $# -eq 2 ] || { usage; exit 1; }
  local org_name=$1 username=$2 group_name group_id user_id

  load_runtime
  kc_get_admin_token

  group_name="$(kc_group_name_for_org "${org_name}")"
  group_id="$(kc_get_group_id "${group_name}")"
  [ -n "${group_id}" ] || die "Group ${group_name} not found. Run: bash scripts/manage.sh org add ${org_name} <account-id> <display-name>"
  user_id="$(kc_get_user_id "${username}")"
  [ -n "${user_id}" ] || die "User ${username} not found. Run: bash scripts/manage.sh user add ${username} <password> <email> <role>"

  log_step "Add user ${username} to org group ${group_name}"
  kc_assign_user_group "${user_id}" "${group_id}" "${group_name}"
  log_ok "User ${username} is in org group ${group_name}"
}

cmd_org_user_delete() {
  [ $# -eq 2 ] || { usage; exit 1; }
  local org_name=$1 username=$2 group_name group_id user_id

  load_runtime
  kc_get_admin_token

  group_name="$(kc_group_name_for_org "${org_name}")"
  group_id="$(kc_get_group_id "${group_name}")"
  [ -n "${group_id}" ] || die "Group ${group_name} not found"
  user_id="$(kc_get_user_id "${username}")"
  [ -n "${user_id}" ] || die "User ${username} not found"

  log_step "Remove user ${username} from org group ${group_name}"
  kc_remove_user_group "${user_id}" "${group_id}" "${group_name}" || true
  log_ok "User ${username} removed from org group ${group_name}"
}

cmd_user_groups() {
  [ $# -eq 1 ] || { usage; exit 1; }
  local username=$1 user_id

  load_runtime
  kc_get_admin_token
  user_id="$(kc_get_user_id "${username}")"
  [ -n "${user_id}" ] || die "User ${username} not found"

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
  [ -n "${user_id}" ] || die "User ${username} not found"

  if [ "${force}" = true ]; then
    log_step "Delete user ${username}"
    kc_delete_user "${user_id}" "${username}"
  else
    log_step "Disable user ${username}"
    kc_disable_user "${user_id}" "${username}"
    log_info "Use --force to permanently delete"
  fi
  log_ok "User ${username} processed"
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
        [ $# -ge 2 ] || die "--grafana-name requires a value"
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
    die "--grafana-name cannot be used with --all-tenants"
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
    [ -n "${grafana_org_name}" ] || { log_warn "Grafana org id ${grafana_org_id} not found; skipping ${group_name}"; continue; }

    dashboards_import tenants "${group_name}" "${grafana_org_name}" "${overwrite}"
    count=$((count + 1))
  done < <(printf '%s' "${kc_groups}" | jq -c '.[]')

  [ "${count}" -gt 0 ] || log_warn "No tenant orgs found for dashboard import"
}

cmd_org_add() {
  [ $# -ge 1 ] || { usage; exit 1; }
  local is_main=false org_name account_id display_name group_name group_id org_id grafana_org_name org_password

  if [ "$1" = "--main" ]; then
    is_main=true
    org_name="main"
    account_id="${2:-0}"
    require_number account_id "${account_id}"
  elif [ $# -eq 3 ]; then
    org_name=$1
    account_id=$2
    display_name=$3
    require_number account_id "${account_id}"
  else
    usage
    exit 1
  fi

  load_runtime
  kc_get_admin_token
  group_name="$(kc_group_name_for_org "${org_name}")"

  log_step "Ensure org ${org_name}"
  group_id="$(kc_ensure_group "${group_name}" "${account_id}")"

  if [ "${is_main}" = true ]; then
    org_id=1
    grafana_org_name="$(grafana_get_org_name "${org_id}")"
    [ -n "${grafana_org_name}" ] || grafana_org_name="Main Org."
    log_info "Using built-in Grafana org ${grafana_org_name} (id=${org_id})"
  else
    grafana_org_name="${display_name}"
    org_id="$(grafana_ensure_org "${grafana_org_name}")"
  fi

  kc_set_group_attribute "${group_id}" grafana_org_id "${org_id}"
  log_info "Set grafana_org_id=${org_id} on group ${group_name}"

  local admin_user_id
  admin_user_id="$(kc_get_user_id "${KC_ADMIN_USER}")"
  if [ -n "${admin_user_id}" ]; then
    kc_assign_user_group "${admin_user_id}" "${group_id}" "${group_name}"
  fi

  grafana_ensure_admins_in_org "${org_id}" "${grafana_org_name}"

  org_password="$(vmauth_org_password "${org_name}")"
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
  log_ok "Org ${org_name} ready"
}

verify_jwt() {
  local token
  log_step "Verify Grafana OIDC JWT"
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
    log_warn "JWT verification skipped; token request failed"
  fi
}

print_summary() {
  cat <<EOF

Deployment complete.

Grafana:  ${GRAFANA_URL}
Keycloak: ${KC_URL}
vmauth:   http://${HOST_IP}:${VMAUTH_PORT:-8427}

Grafana OIDC user: ${GF_ADMIN_USER} / ${GF_ADMIN_PASS}
Keycloak admin:    ${KC_ADMIN_USER} / ${KC_ADMIN_PASS}

Add a tenant:
  bash scripts/manage.sh org add org-test 10 测试组织
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
