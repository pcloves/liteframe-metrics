#!/usr/bin/env bash

http_request() {
  local method=$1 url=$2 body=${3-}
  shift 3 || true

  local args=(-sS -f --connect-timeout "${HTTP_CONNECT_TIMEOUT:-5}" --max-time "${HTTP_MAX_TIME:-30}" -X "${method}")
  local header
  for header in "$@"; do
    args+=(-H "${header}")
  done
  if [ -n "${body}" ]; then
    args+=(-d "${body}")
  fi

  curl "${args[@]}" "${url}"
}

http_get() {
  local url=$1
  shift
  http_request GET "${url}" "" "$@"
}

http_delete() {
  local url=$1
  shift
  http_request DELETE "${url}" "" "$@"
}

http_post_json() {
  local url=$1 body=$2
  shift 2
  http_request POST "${url}" "${body}" "Content-Type: application/json" "$@"
}

http_put_json() {
  local url=$1 body=$2
  shift 2
  http_request PUT "${url}" "${body}" "Content-Type: application/json" "$@"
}

wait_for_http_200() {
  local name=$1 url=$2 attempts=$3 delay=$4
  shift 4

  local i http_code
  for i in $(seq 1 "${attempts}"); do
    if ! http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 "${url}" "$@" 2>/dev/null); then
      http_code=ERR
    fi
    if [ "${http_code}" = "200" ]; then
      log_ok "${name} 已就绪"
      return 0
    fi
    log_info "等待 ${name}（${i}/${attempts}）HTTP=${http_code}"
    sleep "${delay}"
  done
  return 1
}
