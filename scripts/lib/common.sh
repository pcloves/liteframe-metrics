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
  command -v "${cmd}" >/dev/null 2>&1 || die "缺少必需的命令：${cmd}"
}

require_file() {
  local file=$1
  [ -f "${file}" ] || die "必需文件未找到：${file}"
}

require_env() {
  local name=$1
  [ -n "${!name:-}" ] || die "必需环境变量未设置：${name}"
}

require_number() {
  local name=$1 value=$2
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} 必须是数字，当前值：${value}"
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
  log_step "检查前置依赖"
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
    die "缺少必需的命令：yq（mikefarah/yq v4.18+）"
  fi
  if ! yq --version 2>/dev/null | grep -qi mikefarah; then
    die "yq 实现错误：$(yq --version 2>&1)。需要：mikefarah/yq v4.18+"
  fi
  log_ok "前置依赖检查通过"
}
