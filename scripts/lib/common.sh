#!/usr/bin/env bash

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${LIB_DIR}/../.." && pwd)"

# shellcheck source=log.sh
source "${LIB_DIR}/log.sh"

die() {
  log_error "$*"
  exit 1
}

require_cmd() {
  local cmd=$1
  command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
}

require_file() {
  local file=$1
  [ -f "${file}" ] || die "Required file not found: ${file}"
}

require_env() {
  local name=$1
  [ -n "${!name:-}" ] || die "Required environment variable is not set: ${name}"
}

require_number() {
  local name=$1 value=$2
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be a number, got: ${value}"
}

base64_one_line() {
  base64 | tr -d '\n'
}

jq_raw() {
  local input=$1 filter=${2:-.}
  printf '%s' "${input}" | jq -r "${filter} // empty" 2>/dev/null || true
}

json_any() {
  local input=$1 filter=$2
  printf '%s' "${input}" | jq -e "${filter}" >/dev/null 2>&1
}

ensure_project_root() {
  cd "${PROJECT_DIR}"
}

check_prerequisites() {
  log_step "Check prerequisites"
  require_cmd curl
  require_cmd jq
  require_cmd docker
  require_cmd base64
  require_cmd sed
  require_cmd sort
  require_cmd mktemp
  require_cmd find
  require_cmd sha256sum

  if ! command -v yq >/dev/null 2>&1; then
    die "Missing required command: yq (mikefarah/yq v4.18+)"
  fi
  if ! yq --version 2>/dev/null | grep -qi mikefarah; then
    die "Wrong yq implementation: $(yq --version 2>&1). Required: mikefarah/yq v4.18+"
  fi
  log_ok "All prerequisites found"
}
