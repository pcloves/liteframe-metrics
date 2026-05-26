#!/usr/bin/env bash

load_env() {
  ensure_project_root
  if [ ! -f .env ]; then
    if [ -f .env.example ]; then
      cp .env.example .env
      die ".env 文件未找到。已从 .env.example 创建，请编辑后重新运行命令。"
    fi
    die ".env 文件未找到"
  fi

  # shellcheck disable=SC1091
  source .env

  : "${GRAFANA_PORT:=3000}"
  : "${KC_REALM:=grafana}"
  : "${KC_BOOTSTRAP_ADMIN_USER:=admin-temporay}"
  : "${KC_BOOTSTRAP_ADMIN_PASS:=change_me}"
  : "${KC_ADMIN_USER:=admin}"
  : "${KC_ADMIN_PASS:=admin_pass}"
  : "${KC_ADMIN_EMAIL:=admin@example.com}"
  : "${GF_SECURITY_ADMIN_USER:=admin}"
  : "${GF_SECURITY_ADMIN_PASSWORD:=admin}"
  : "${GF_OIDC_ADMIN_USER:=admin}"
  : "${GF_OIDC_ADMIN_PASS:=admin}"
  : "${VMADMIN_PASS:=vmadmin_pass}"

  require_env GRAFANA_HOST_NAME_INTERNAL
  require_env GRAFANA_HOST_NAME_EXTERNAL
  require_env GRAFANA_SCHEME_EXTERNAL
  require_env KEYCLOAK_HOST_NAME_INTERNAL
  require_env KEYCLOAK_HOST_NAME_EXTERNAL
  require_env KEYCLOAK_SCHEME_EXTERNAL
  require_env VMAUTH_HOST_NAME_INTERNAL
  require_env VMAUTH_HOST_NAME_EXTERNAL
  require_env VMAUTH_SCHEME_EXTERNAL
  require_env KC_PORT
  require_env GRAFANA_PORT
  require_env GRAFANA_CLIENT_SECRET

  GRAFANA_URL="http://${GRAFANA_HOST_NAME_INTERNAL}:${GRAFANA_PORT}"
  KC_URL="http://${KEYCLOAK_HOST_NAME_INTERNAL}:${KC_PORT}"
  VMAUTH_URL="http://${VMAUTH_HOST_NAME_INTERNAL}:${VMAUTH_PORT:-8427}"
  REALM="${KC_REALM}"
  GF_BASIC_AUTH="$(printf '%s' "${GF_SECURITY_ADMIN_USER}:${GF_SECURITY_ADMIN_PASSWORD}" | base64_one_line)"
  SSO_API="${GRAFANA_URL}/api/v1/sso-settings/generic_oauth"
  ROLE_ATTRIBUTE_PATH="contains(groups[*], 'role-grafanaAdmin') && 'GrafanaAdmin' || contains(groups[*], 'role-admin') && 'Admin' || contains(groups[*], 'role-editor') && 'Editor' || 'Viewer'"
}

require_bootstrap_env() {
  require_env KC_BOOTSTRAP_ADMIN_PASS
  require_env KC_ADMIN_PASS
  require_env GF_SECURITY_ADMIN_PASSWORD
  require_env GF_OIDC_ADMIN_PASS
  require_env VMADMIN_PASS
}
