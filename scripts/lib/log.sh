#!/usr/bin/env bash

log_init() {
  local log_dir="${PROJECT_DIR:-$(pwd)}/logs"
  mkdir -p "${log_dir}"
  LOG_FILE="${LOG_FILE:-${log_dir}/manage-$(date +%Y%m%d).log}"
}

log_timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_write() {
  local level=$1
  shift
  local message="$*"
  local line
  line="$(log_timestamp) [${level}] ${message}"
  echo "${line}" >&2
  if [ -n "${LOG_FILE:-}" ]; then
    echo "${line}" >> "${LOG_FILE}"
  fi
}

log_info() { log_write INFO "$@"; }
log_warn() { log_write WARN "$@"; }
log_error() { log_write ERROR "$@"; }
log_ok() { log_write OK "$@"; }
log_step() { log_write STEP "$@"; }
